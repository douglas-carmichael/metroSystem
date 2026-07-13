import Foundation

/// Owns one node's fleet of rames and steps them through the same
/// FIXED-BLOCK VAL scan the app's VAL backend runs (Backends/VAL*.swift):
/// wayside block occupancy -> SF/PP speed-program selection -> on-board
/// AVP trips + jerk-limited AVO regulation (or console-A22 manual
/// driving) -> image-série traction envelope. Faithfulness matters: the
/// app dead-reckons our rames between `.state` broadcasts, so if our
/// physics diverged from the app's the rame would visibly stutter
/// between corrections.
///
/// SHARED LOOP: every node's trains run on the same circular track. The
/// simulator keeps a map of FOREIGN trains (the app's, or another daemon
/// node's), fed from inbound `.state` broadcasts, and its detection pass
/// registers them as block occupancy when protecting its OWN trains --
/// each node protects its own trains against the whole picture, exactly
/// one authority per train.
///
/// Deliberately omitted vs. the app: SCADA alarm sampling, service
/// provisoire, the line-service switch (a daemon node is always in
/// service) and the per-bogie wheel-slip integration (fault injection is
/// owner-only, so a daemon rame never sees a degraded-adhesion patch;
/// the tire-state grip envelope is kept).
final class RameSimulator {
    private(set) var trains: [Train] = []
    private let ownerPeerId: String

    /// Latest state of every train some other node owns, keyed by id.
    /// Occupancy inputs for the detection pass; never advanced here.
    private var foreign: [UUID: Train] = [:]

    /// Per-rame OBCU state (consigne shaping, AVP accumulators, KACOP).
    private struct ObcuState {
        var consigne: Double = 0
        var consigneAccel: Double = 0
        var rollbackDistance: Double = 0
        var tripHoldoff: Double = 0
    }
    private var obcu: [UUID: ObcuState] = [:]

    // MARK: -- guideway database (mirror of VALTrackDatabase)

    private struct Block {
        let id: Int
        let start: Double
        let length: Double
        let normalCode: Double
        let stationId: Int?
        let stopPoint: Double?
        var end: Double { start + length }
    }
    private let blocks: [Block]
    private let rameLength = 26.0

    init(ownerPeerId: String, trainCount: Int, nodeIndex: Int) {
        self.ownerPeerId = ownerPeerId
        blocks = (0..<Sim.cantonCount).map { i in
            let start = Double(i) * Sim.cantonLength
            let station = Station.all.first { $0.position >= start && $0.position < start + Sim.cantonLength }
            return Block(id: i + 1, start: start, length: Sim.cantonLength,
                         normalCode: station != nil ? Sim.stationBlockSpeed : Sim.lineSpeed,
                         stationId: station?.id, stopPoint: station?.position)
        }
        spawn(count: max(1, trainCount), nodeIndex: nodeIndex)
    }

    /// Spawn trains evenly around the loop with a per-node phase offset so
    /// two daemon nodes started together don't materialise on top of each
    /// other (the block protection keeps them apart once running).
    private func spawn(count: Int, nodeIndex: Int) {
        let firstNumber = (nodeIndex + 2) * 100 + 1     // node 0 -> 201..., node 1 -> 301...
        let spacing = Sim.trackLength / Double(count)
        let nodeOffset = Double(nodeIndex) * 37.0
        for i in 0..<count {
            var position = (spacing * Double(i) + nodeOffset)
                .truncatingRemainder(dividingBy: Sim.trackLength)
            if position < 0 { position += Sim.trackLength }
            var t = Train(id: UUID(),
                          label: String(firstNumber + i),
                          ownerPeerId: ownerPeerId,
                          position: position)
            t.status = .stopped
            t.movementAuthority = position
            t.passengerCount = Int.random(in: 10...40)
            trains.append(t)
        }
    }

    // MARK: -- foreign-train bookkeeping (called from PeerSession)

    func upsertForeign(_ train: Train) {
        guard train.ownerPeerId != ownerPeerId else { return }
        foreign[train.id] = train
    }

    func removeForeign(id: UUID) {
        foreign.removeValue(forKey: id)
    }

    func removeForeign(ownedBy peerId: String) {
        foreign = foreign.filter { $0.value.ownerPeerId != peerId }
    }

    /// Apply a remote-control request forwarded by a peer (the app) to one
    /// of this node's rames. Mirrors the app's `MetroWorld.applyControl`.
    /// Requests for a rame this node doesn't own are ignored. Must be
    /// called on the node's serial queue.
    func apply(_ cmd: TrainCommand) {
        guard let index = trains.firstIndex(where: { $0.id == cmd.trainId && $0.ownerPeerId == ownerPeerId }) else { return }
        switch cmd.kind {
        case .openDoors:
            guard trains[index].speed < 0.1 else { return }
            trains[index].doorsOpen = true
            trains[index].isDwelling = true
            trains[index].dwellRemaining = max(trains[index].dwellRemaining, 5.0)
            trains[index].status = .docked
        case .closeDoors:
            trains[index].doorsOpen = false
            trains[index].isDwelling = false
            trains[index].dwellRemaining = 0
            trains[index].paxRemaining = 0
        case .fuSet:
            trains[index].isEmergencyBrakeApplied = true
            trains[index].ebCause = VALTripCause.operatorFU.rawValue
        case .fuRelease:
            guard trains[index].speed < 0.5 else { return }
            trains[index].isEmergencyBrakeApplied = false
            trains[index].ebCause = VALTripCause.none.rawValue
            if trains[index].status == .emergency { trains[index].status = .stopped }
        case .modeAuto:
            trains[index].mode = .auto
            trains[index].manualSpeedRequest = 0
            trains[index].pupitreLever = 0
            trains[index].pupitreKIBS = false
        case .modeManual:
            trains[index].mode = .manual
            trains[index].manualSpeedRequest = 0
        case .setSpeed:
            guard trains[index].mode == .manual else { return }
            trains[index].manualSpeedRequest = max(0, min(Sim.manualSpeedMax, cmd.value ?? 0))
        case .pupitreKG:
            trains[index].pupitreKG = (cmd.value ?? 0) > 0.5
            if !trains[index].pupitreKG {
                trains[index].pupitreLever = min(trains[index].pupitreLever, 0)
            }
        case .pupitreReverser:
            guard trains[index].mode == .manual else { return }
            let v = Int((cmd.value ?? 0).rounded())
            guard (-1...1).contains(v) else { return }
            if v != 0 && trains[index].speed >= 0.1 && v != trains[index].pupitreReverser { return }
            trains[index].pupitreReverser = v
        case .pupitreLever:
            guard trains[index].mode == .manual else { return }
            trains[index].pupitreLever = max(-1, min(1, cmd.value ?? 0))
        case .pupitreKIBS:
            guard trains[index].mode == .manual else { return }
            trains[index].pupitreKIBS = (cmd.value ?? 0) > 0.5
        case .pupitreKPH:
            trains[index].pupitreKPH = (cmd.value ?? 0) > 0.5
        case .kacopAck:
            trains[index].kacopSecondsSinceAck = 0
            trains[index].kacopWarning = false
            if trains[index].ebCause == VALTripCause.vigilance.rawValue
                && trains[index].speed < 0.5 {
                trains[index].isEmergencyBrakeApplied = false
                trains[index].ebCause = VALTripCause.none.rawValue
                if trains[index].status == .emergency { trains[index].status = .stopped }
            }
        }
    }

    // MARK: -- scan loop

    func tick(dt: Double) {
        let occupancy = detectOccupancy()
        for index in trains.indices {
            var state = obcu[trains[index].id] ?? ObcuState()
            advance(&trains[index], state: &state, occupancy: occupancy, dt: dt)
            obcu[trains[index].id] = state
        }
    }

    // MARK: -- wayside (detection + program selection)

    private func detectOccupancy() -> [Int: Set<UUID>] {
        var occupancy: [Int: Set<UUID>] = [:]
        for t in trains + Array(foreign.values) {
            occupancy[block(at: t.position).id, default: []].insert(t.id)
            let tail = block(at: t.position - t.travelDirection.rawValue * rameLength)
            occupancy[tail.id, default: []].insert(t.id)
        }
        return occupancy
    }

    private func block(at position: Double) -> Block {
        var p = position.truncatingRemainder(dividingBy: Sim.trackLength)
        if p < 0 { p += Sim.trackLength }
        return blocks.first { p >= $0.start && p < $0.end } ?? blocks[0]
    }

    private func nextBlock(after id: Int, direction: TravelDirection) -> Block {
        let step = direction == .forward ? 1 : -1
        var next = (id - 1 + step) % blocks.count
        if next < 0 { next += blocks.count }
        return blocks[next]
    }

    private func isOccupied(_ b: Block, by occupancy: [Int: Set<UUID>], excluding me: UUID) -> Bool {
        guard let ids = occupancy[b.id] else { return false }
        return !ids.subtracting([me]).isEmpty
    }

    /// Condensed telegram: (program, blockCode, nextCode, stopAnchor,
    /// stationId, occupiedBoundary).
    private struct Telegram {
        var program: VALSpeedProgram = .normal
        var blockCode: Double = 0
        var nextBlockCode: Double = 0
        var stopAnchor: Double? = nil
        var stationId: Int? = nil
        var occupiedBoundary: Double? = nil
        var penetrationDepth: Double? = nil
    }

    private func telegram(for train: Train, occupancy: [Int: Set<UUID>]) -> Telegram {
        var tg = Telegram()
        let b = block(at: train.position)
        tg.blockCode = b.normalCode
        tg.nextBlockCode = nextBlock(after: b.id, direction: train.travelDirection).normalCode

        // Sequential presence detection: check-in to an occupied block
        // (entry zone only -- mirror of the app's wayside).
        if isOccupied(b, by: occupancy, excluding: train.id) {
            let entry = train.travelDirection == .forward ? b.start : b.end
            let depth = distanceAhead(from: entry, to: train.position,
                                      direction: train.travelDirection)
            if depth < 30 { tg.penetrationDepth = depth }
        }

        var probe = b
        for step in 0..<blocks.count {
            let next = nextBlock(after: probe.id, direction: train.travelDirection)
            if isOccupied(next, by: occupancy, excluding: train.id) {
                let boundary = train.travelDirection == .forward ? next.start : next.end
                tg.occupiedBoundary = boundary
                if step == 0 {
                    tg.program = .perturbed
                    tg.stopAnchor = wrapped(boundary - train.travelDirection.rawValue * Sim.perturbedStopMargin)
                }
                break
            }
            probe = next
        }

        if let stationId = b.stationId, let stop = b.stopPoint, tg.program != .perturbed {
            let d = distanceAhead(from: train.position, to: stop, direction: train.travelDirection)
            if d < b.length && train.lastServicedStationId != stationId {
                tg.program = .stationArrival
                tg.stopAnchor = stop
                tg.stationId = stationId
            } else if train.lastServicedStationId == stationId {
                // Departure: withheld while doors open / dwelling or the
                // downstream block is occupied.
                let next = nextBlock(after: b.id, direction: train.travelDirection)
                let hold = train.doorsOpen || train.isDwelling
                    || isOccupied(next, by: occupancy, excluding: train.id)
                tg.program = hold ? .departureHeld : .stationDeparture
            }
        }
        return tg
    }

    // MARK: -- on-board scan (AVP + AVO / pupitre + traction envelope)

    private func advance(_ train: inout Train, state: inout ObcuState,
                         occupancy: [Int: Set<UUID>], dt: Double) {
        // Station dwell first (mirrors the app's OBCU).
        if train.isDwelling {
            runDwell(&train, dt: dt)
            if train.isDwelling {
                publish(&train, state: state, tg: telegram(for: train, occupancy: occupancy), vProgram: 0)
                return
            }
        }

        let tg = telegram(for: train, occupancy: occupancy)
        train.isDepartureHold = tg.program == .departureHeld

        // ---- SAFETY rack ------------------------------------------------
        updateSafety(&train, state: &state, tg: tg, dt: dt)
        if train.isEmergencyBrakeApplied {
            train.status = .emergency
            state.consigne = min(state.consigne, train.speed)
            state.consigneAccel = 0
            publish(&train, state: state, tg: tg, vProgram: 0)
            integrate(&train, desired: -Sim.emergencyBraking, emergency: true, dt: dt)
            return
        }
        if train.ebCause != VALTripCause.none.rawValue {
            train.ebCause = VALTripCause.none.rawValue
        }

        // ---- DRIVE rack / console A22 -----------------------------------
        let taperLead = train.speed * 2.6 + 2.0
        var vProgram = programSpeed(train: train, tg: tg, lead: taperLead)
        var desired: Double
        var motoring = true

        if train.mode == .manual {
            if train.speed < 0.1 && train.pupitreReverser != 0 {
                let dir: TravelDirection = train.pupitreReverser > 0 ? .forward : .reverse
                if dir != train.travelDirection {
                    train.travelDirection = dir
                    state.consigne = 0
                    state.consigneAccel = 0
                }
            }
            var ceiling = train.manualSpeedRequest > 0.05
                ? min(train.manualSpeedRequest, Sim.manualSpeedMax)
                : Sim.manualSpeedMax
            if train.pupitreKIBS { ceiling = min(ceiling, 3.0) }
            let inhibited = !train.pupitreKG || train.pupitreReverser == 0
                || (train.doorsOpen && !train.pupitreKIBS)
                || train.isEngineFault || train.speed >= ceiling
            let lever = max(-1.0, min(1.0, train.pupitreLever))
            desired = lever > 0
                ? (inhibited ? 0 : lever * Sim.maxAcceleration)
                : lever * Sim.nominalBraking
            motoring = !inhibited
            train.status = train.speed > 0.05 ? .moving : (train.doorsOpen ? .docked : .stopped)
            state.consigne = ceiling
            state.consigneAccel = 0
            vProgram = ceiling
        } else {
            // Perturbed-stop close-in (mirror of the app's berthing
            // profile -- land inside the margin d, don't drift over it).
            if tg.program == .perturbed, let anchor = tg.stopAnchor {
                var d = distanceAhead(from: train.position, to: anchor,
                                      direction: train.travelDirection)
                if d > Sim.trackLength / 2 { d = 0 }
                vProgram = min(vProgram, berthingProfile(d))
            }
            // Precision stop staging at platforms.
            if tg.program == .stationArrival, let anchor = tg.stopAnchor {
                let d = distanceAhead(from: train.position, to: anchor, direction: train.travelDirection)
                if d <= Sim.beaconB1Distance {
                    vProgram = min(vProgram, berthingProfile(d))
                }
                if d <= max(Sim.stopPrecision, Sim.stationStopTolerance) && train.speed < 0.1,
                   let stationId = tg.stationId {
                    beginDwell(&train, stationId: stationId)
                    state.consigne = 0
                    state.consigneAccel = 0
                    publish(&train, state: state, tg: tg, vProgram: 0)
                    return
                }
            }
            let decelZone = vProgram < tg.blockCode - 0.1
                && state.consigne >= vProgram - 0.2
            let accel = shapeConsigne(&state, toward: vProgram, dt: dt,
                                      motoringInhibited: decelZone)
            desired = (state.consigne - train.speed) * 1.6 + accel * 0.9
            desired = max(-Sim.nominalBraking * 1.15, min(Sim.maxAcceleration, desired))
            motoring = !train.isEngineFault
            train.status = train.speed > 0.05 || state.consigne > 0.05 ? .moving : .stopped
            if train.status == .stopped { desired = 0; train.speed = 0 }
        }

        publish(&train, state: state, tg: tg, vProgram: vProgram)
        if desired > 0 && !motoring { desired = 0 }
        integrate(&train, desired: desired, emergency: false, dt: dt)
    }

    private func updateSafety(_ train: inout Train, state: inout ObcuState,
                              tg: Telegram, dt: Double) {
        // Condition-driven FU (fault flags can only arrive via the wire
        // for daemon rames, but the mirror keeps the same order).
        var cause: VALTripCause = .none
        if train.isSignalFault { cause = .sfLoss }
        else if train.isDoorFault { cause = .doorFault }
        else if train.isBrakeFault { cause = .brakeFault }
        else if train.doorsOpen && train.speed > 0.5
                    && !(train.mode == .manual && train.pupitreKIBS) { cause = .doorUnlocked }
        if cause != .none {
            train.isEmergencyBrakeApplied = true
            train.ebCause = cause.rawValue
            return
        }

        // Automatic restart after an event trip once the cause clears
        // (mirror of the app's SAFETY-rack hold-off).
        if train.isEmergencyBrakeApplied {
            guard train.speed < 0.05,
                  let tripCause = VALTripCause(rawValue: train.ebCause) else { return }
            let recoverable: Bool
            switch tripCause {
            case .overspeed, .rollback:
                recoverable = true
            case .ppOverrun, .blockPenetration:
                recoverable = tg.program != .perturbed && tg.penetrationDepth == nil
            default:
                recoverable = false
            }
            if recoverable {
                state.tripHoldoff += dt
                if state.tripHoldoff >= 5.0 {
                    train.isEmergencyBrakeApplied = false
                    train.ebCause = VALTripCause.none.rawValue
                    train.status = .stopped
                    state.tripHoldoff = 0
                }
            } else {
                state.tripHoldoff = 0
            }
            return
        }
        state.tripHoldoff = 0

        // Survitesse: 10/9 over the program plus the one-crossover
        // detection allowance, floored at the berthing envelope (mirror
        // of the app's SSV).
        let ceiling = max(programSpeed(train: train, tg: tg) * Sim.avpOverspeedRatio + 0.9, 3.0)
        if train.speed > ceiling + 0.3 {
            train.isEmergencyBrakeApplied = true
            train.ebCause = VALTripCause.overspeed.rawValue
            return
        }

        // PP overrun.
        if tg.program == .perturbed, let anchor = tg.stopAnchor {
            let d = distanceAhead(from: train.position, to: anchor, direction: train.travelDirection)
            if d > Sim.trackLength / 2 && train.speed > 0.3 {
                train.isEmergencyBrakeApplied = true
                train.ebCause = VALTripCause.ppOverrun.rawValue
                return
            }
        }

        // Occupied-block penetration (sequential detection).
        if let penetration = tg.penetrationDepth {
            let tripAt = train.mode == .manual ? Sim.manualPenetrationTrip : 1.0
            if penetration > tripAt {
                train.isEmergencyBrakeApplied = true
                train.ebCause = VALTripCause.blockPenetration.rawValue
                return
            }
        }

        // Rollback.
        let commanded = train.mode == .manual && train.pupitreReverser != 0
            ? Double(train.pupitreReverser)
            : train.travelDirection.rawValue
        if train.speed * train.travelDirection.rawValue * commanded < -0.01 {
            state.rollbackDistance += train.speed * dt
            if state.rollbackDistance > Sim.rollbackTrip {
                train.isEmergencyBrakeApplied = true
                train.ebCause = VALTripCause.rollback.rawValue
                state.rollbackDistance = 0
                return
            }
        } else if train.speed > 0.1 {
            state.rollbackDistance = 0
        }

        // KACOP vigilance (manual only).
        if train.mode == .manual && train.pupitreKG {
            train.kacopSecondsSinceAck += dt
            train.kacopWarning = train.kacopSecondsSinceAck >= Sim.kacopWarningDelay
            if train.kacopSecondsSinceAck >= Sim.kacopTripDelay {
                train.isEmergencyBrakeApplied = true
                train.ebCause = VALTripCause.vigilance.rawValue
                train.kacopSecondsSinceAck = 0
                train.kacopWarning = false
            }
        } else {
            train.kacopSecondsSinceAck = 0
            train.kacopWarning = false
        }
    }

    private func programSpeed(train: Train, tg: Telegram, includeStops: Bool = true,
                              lead: Double = 0) -> Double {
        var v = tg.blockCode
        if tg.nextBlockCode < v {
            let b = block(at: train.position)
            let boundary = train.travelDirection == .forward ? b.end : b.start
            let d = distanceAhead(from: train.position, to: boundary, direction: train.travelDirection)
            let curve = (tg.nextBlockCode * tg.nextBlockCode + 2 * Sim.nominalBraking * max(0, d - lead)).squareRoot()
            v = min(v, curve)
        }
        if includeStops, let anchor = tg.stopAnchor {
            var d = distanceAhead(from: train.position, to: anchor, direction: train.travelDirection)
            if d > Sim.trackLength / 2 { d = 0 }
            let curve = (2 * Sim.nominalBraking * max(0, d - Sim.maDistanceMargin)).squareRoot()
            v = min(v, curve)
        }
        if includeStops && tg.program == .departureHeld { v = 0 }
        return max(0, v)
    }

    /// Mirror of the app's precision-stop law (soft 0.9 m/s² curve aimed
    /// 1.5 m short of the marker to absorb the loop lag).
    private func berthingProfile(_ d: Double) -> Double {
        (2 * 0.9 * max(0, d - Sim.stationStopTolerance)).squareRoot()
    }

    private func shapeConsigne(_ state: inout ObcuState, toward target: Double, dt: Double,
                               motoringInhibited: Bool = false) -> Double {
        let error = target - state.consigne
        var wanted = max(-Sim.nominalBraking * 1.15, min(Sim.maxAcceleration, error / 0.35))
        if abs(error) < 0.05 { wanted = 0 }
        if motoringInhibited { wanted = min(wanted, 0) }
        let jerkStep = Sim.jerkMax * dt
        state.consigneAccel += max(-jerkStep, min(jerkStep, wanted - state.consigneAccel))
        if motoringInhibited { state.consigneAccel = min(state.consigneAccel, 0) }
        state.consigne += state.consigneAccel * dt
        if state.consigne < 0 { state.consigne = 0; state.consigneAccel = 0 }
        return state.consigneAccel
    }

    // MARK: -- traction envelope (image série + Davis + tire grip)

    private func integrate(_ train: inout Train, desired: Double, emergency: Bool, dt: Double) {
        let mass = Sim.tareMass + Double(train.passengerCount) * Sim.passengerMass
        let v = train.speed
        let resistance = Sim.davisA * mass + Sim.davisB * v + Sim.davisC * v * v

        var demand: Double
        if emergency {
            demand = -(mass * Sim.emergencyBraking)
        } else {
            demand = mass * desired
            if abs(desired) > 0.01 || v > 0.1 { demand += resistance }
        }

        // Tire-state grip/drag envelope (mirror of the app's factors).
        var grip = 0.0, dragAccum = 0.0
        for tire in train.tires {
            switch tire.status {
            case .ok:          grip += 1.0
            case .lowPressure: grip += 0.9;  dragAccum += 0.05
            case .puncture:    grip += 0.5;  dragAccum += 0.2
            case .burst:       grip += 0.15; dragAccum += 0.5
            }
        }
        grip /= Double(max(1, train.tires.count))

        if demand > 0 {
            demand = min(demand, tractiveCapability(at: v) * grip)
            if train.isPatinage { demand *= 0.2 }
        } else if demand < 0 {
            demand = max(demand, -mass * (emergency ? Sim.emergencyBraking : Sim.nominalBraking) * max(grip, 0.3))
            if train.isEnrayage { demand *= 0.3 }
        }
        let tireDrag = dragAccum * mass * 9.81 / 400

        var accel = (demand - resistance - (v > 0.05 ? tireDrag : 0)) / mass
        if v <= 0.01 && accel < 0 && demand >= 0 { accel = 0 }
        train.acceleration = accel
        train.speed = max(0, v + accel * dt)
        train.position += train.speed * train.travelDirection.rawValue * dt
        train.position = train.position.truncatingRemainder(dividingBy: Sim.trackLength)
        if train.position < 0 { train.position += Sim.trackLength }

        updateAuxiliaries(&train, demand: demand, emergency: emergency, dt: dt)
    }

    private func tractiveCapability(at v: Double) -> Double {
        let omega = max(v, 0.1) / Sim.wheelRadius * Sim.gearRatio
        var ii = Sim.armatureCurrentMax
        var ratio = Sim.imageSerieFullField
        func loopVoltage(_ ii: Double, _ ratio: Double) -> Double {
            2 * Sim.motorTorquePerAmp2 * ratio * ii * omega + ii * Sim.armatureResistance
        }
        if loopVoltage(ii, ratio) > Sim.lineVoltage {
            ratio = Sim.imageSerieWeakField
            if loopVoltage(ii, ratio) > Sim.lineVoltage {
                ii = Sim.lineVoltage /
                    (2 * Sim.motorTorquePerAmp2 * ratio * omega + Sim.armatureResistance)
            }
        }
        let torque = Sim.motorTorquePerAmp2 * ratio * ii * ii
        return Double(Sim.motorCount) * torque * Sim.gearRatio / Sim.wheelRadius
    }

    // MARK: -- dwell / passenger exchange (unchanged behaviour)

    private func runDwell(_ train: inout Train, dt: Double) {
        train.dwellRemaining -= dt
        if train.dwellRemaining <= 0 {
            train.passengerCount = max(0, train.passengerCount + train.paxRemaining)
            train.paxRemaining = 0
            train.dwellRemaining = 0
            train.isDwelling = false
            train.doorsOpen = false
            train.status = .docked
            train.lastPaxChange = 0
            return
        }
        if train.paxRemaining != 0 {
            train.paxExchangeTimer -= dt
            if train.paxExchangeTimer <= 0 {
                if train.paxRemaining > 0 {
                    train.passengerCount += 1
                    train.paxRemaining -= 1
                } else {
                    train.passengerCount = max(0, train.passengerCount - 1)
                    train.paxRemaining += 1
                }
                train.paxExchangeTimer = train.paxExchangeInterval
            }
        }
        train.status = .docked
        train.speed = 0
        train.acceleration = 0
    }

    private func beginDwell(_ train: inout Train, stationId: Int) {
        train.isDwelling = true
        let dwell = Double.random(in: Sim.dwellMin...Sim.dwellMax)
        train.dwellRemaining = dwell
        train.doorsOpen = true
        train.status = .docked
        train.speed = 0
        train.acceleration = 0
        train.lastServicedStationId = stationId
        let headroom = max(0, Sim.paxCapacity - train.passengerCount)
        let change = Int.random(in: -min(Sim.paxAlightMax, train.passengerCount)...min(Sim.paxBoardMax, headroom))
        train.lastPaxChange = change
        train.paxRemaining = change
        train.paxExchangeInterval = abs(change) > 0 ? (dwell * 0.6) / Double(abs(change)) : 1.0
        train.paxExchangeTimer = 0
    }

    // MARK: -- projection / helpers

    private func publish(_ train: inout Train, state: ObcuState, tg: Telegram, vProgram: Double) {
        train.consigneVitesse = state.consigne
        train.speedError = state.consigne - train.speed
        train.targetSpeed = vProgram
        train.speedProgram = tg.program.rawValue

        let limit: Double
        if let anchor = tg.stopAnchor {
            limit = anchor
        } else if let boundary = tg.occupiedBoundary {
            limit = boundary - train.travelDirection.rawValue * Sim.perturbedStopMargin
        } else {
            limit = train.position - train.travelDirection.rawValue * Sim.perturbedStopMargin
        }
        train.movementAuthority = wrapped(limit)
        var d = distanceAhead(from: train.position, to: train.movementAuthority,
                              direction: train.travelDirection)
        if tg.stopAnchor != nil && d > Sim.trackLength / 2 { d = 0 }
        train.distanceToMA = d

        if let sid = tg.stationId, let s = Station.all.first(where: { $0.id == sid }) {
            train.nextStationName = s.name
        } else {
            var bestD = Double.greatestFiniteMagnitude
            for s in Station.all where s.id != train.lastServicedStationId {
                let ds = distanceAhead(from: train.position, to: s.position,
                                       direction: train.travelDirection)
                if ds < bestD { bestD = ds; train.nextStationName = s.name }
            }
        }

        if let last = train.lastServicedStationId,
           let station = Station.all.first(where: { $0.id == last }),
           block(at: train.position).id != block(at: station.position).id,
           !train.isDwelling {
            let ds = distanceAhead(from: train.position, to: station.position,
                                   direction: train.travelDirection)
            if ds > Sim.cantonLength { train.lastServicedStationId = nil }
        }
    }

    /// Mirror of the app's publishElectrical: back the bench picture
    /// (ii / il / iex / mhi, thesis notation) out of the force demand.
    private func updateAuxiliaries(_ train: inout Train, demand: Double,
                                   emergency: Bool, dt: Double) {
        let motoring = demand > 500 && !emergency
        let regenerating = demand < -500 && train.speed > 1.5 && !emergency

        if motoring || regenerating {
            let omega = max(train.speed, 0.1) / Sim.wheelRadius * Sim.gearRatio
            let torquePerMotor = (abs(demand) / 2) * Sim.wheelRadius / (2 * Sim.gearRatio)
            var ratio = Sim.imageSerieFullField
            var ii = (torquePerMotor / (Sim.motorTorquePerAmp2 * ratio)).squareRoot()
            if motoring {
                let loop = 2 * Sim.motorTorquePerAmp2 * ratio * ii * omega
                    + ii * Sim.armatureResistance
                if loop > Sim.lineVoltage {
                    ratio = Sim.imageSerieWeakField
                    ii = (torquePerMotor / (Sim.motorTorquePerAmp2 * ratio)).squareRoot()
                }
            }
            ii = min(ii, Sim.armatureCurrentMax)
            let duty = min(1, max(0,
                (2 * Sim.motorTorquePerAmp2 * ratio * ii * omega + ii * Sim.armatureResistance)
                    / Sim.lineVoltage))
            train.armatureCurrent = ii
            train.excitationCurrent = ratio * ii
            train.modulationRatio = duty
            train.lineCurrent = 2 * duty * ii * (motoring ? 1 : -0.85)
            train.tractionCurrent = max(60, 2 * ii)
            train.mainVoltage = motoring
                ? Sim.lineVoltage - abs(train.lineCurrent) * 0.02
                : min(825, Sim.lineVoltage + abs(train.lineCurrent) * 0.15)
        } else {
            train.armatureCurrent = 0
            train.excitationCurrent = 0
            train.modulationRatio = 0
            train.lineCurrent = 0
            train.tractionCurrent = 40
            train.mainVoltage = Sim.lineVoltage - 0.8
        }
        train.tractionTorque = max(-100, min(100, demand / (Sim.tareMass * Sim.maxAcceleration) * 100))
        train.compressorPressure += (train.isCompressorRunning ? 0.08 : -0.01) * dt * 10
        if train.compressorPressure < 7.4 { train.isCompressorRunning = true }
        if train.compressorPressure > 9.0 { train.isCompressorRunning = false }
        train.compressorPressure = max(6.0, min(9.5, train.compressorPressure))
    }

    private func distanceAhead(from position: Double, to target: Double,
                               direction: TravelDirection) -> Double {
        var d = direction == .forward ? target - position : position - target
        if d < 0 { d += Sim.trackLength }
        return d.truncatingRemainder(dividingBy: Sim.trackLength)
    }

    private func wrapped(_ position: Double) -> Double {
        var p = position.truncatingRemainder(dividingBy: Sim.trackLength)
        if p < 0 { p += Sim.trackLength }
        return p
    }
}
