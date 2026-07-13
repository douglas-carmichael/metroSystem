import Foundation

/// The moving-block CBTC simulation (SET BACKEND CBTC_SIM) -- the scan
/// that originally drove this app, kept as its own backend when the VAL
/// engine was rebuilt around the real fixed-block architecture
/// (Backends/VALSimBackend.swift and friends). Its continuous
/// movement-authority envelope is the modern-CBTC counterpoint to VAL's
/// 1983 track-encoded speed programs. A 60 Hz PLC-style cyclic pass:
///
///   1. computeMovementAuthorities()  the wayside ZC pass (continuous
///      LMA to the leader minus a margin, moving-block style)
///   2. enforceServiceProvisoire()    terminus reversal + headway holds
///   3. advance() per local rame      the on-board (OBCU) logic
///      / deadReckon() per remote     interpolate between peer snapshots
///   4. alarm samplers                process-driven SCADA points
///
/// CBTC DISPATCH SIMULATOR, NOT A SAFETY CONTROLLER: real installations
/// (IEEE 1474.1 / EN 62290) run vital, redundant processors with
/// hardware voting; this models the behaviour so the PCC panels and
/// SCADA log read like the real thing, but nothing here is approved to
/// move a train.
@MainActor
final class CBTCSimBackend: MetroBackendEngine {
    private weak var world: MetroWorld?
    private var timer: Timer?
    private var lastTickAt: Date = .init()
    private var doorOpenSince: [UUID: Date] = [:]
    /// SP interval pacing: last departure timestamp per terminus station.
    private var lastTerminusDeparture: [Int: Date] = [:]

    init(world: MetroWorld) {
        self.world = world
    }

    func start() {
        guard timer == nil else { return }
        lastTickAt = Date()
        let t = Timer(timeInterval: Sim.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: -- scan loop

    private func tick() {
        guard let world else { return }
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTickAt))
        lastTickAt = now

        computeMovementAuthorities(world: world)
        enforceServiceProvisoire(world: world, now: now)

        for index in world.trains.indices {
            if world.trains[index].ownerPeerId == world.localPeerId {
                advance(&world.trains[index], dt: dt, world: world)
            } else {
                deadReckon(&world.trains[index], dt: dt)
            }
        }

        sampleSystemAlarms(world: world)
        sampleTrainAlarms(world: world, at: now)
    }

    /// Dead-reckon a peer-owned rame between `.state` snapshots: integrate
    /// the last reported speed along its running direction. At the daemon's
    /// default 60 Hz broadcast the snapshots dominate; at lower rates this
    /// keeps motion smooth instead of stepping.
    private func deadReckon(_ train: inout Train, dt: Double) {
        guard train.speed > 0.01 else { return }
        train.position += train.speed * train.travelDirection.rawValue * dt
        train.position = train.position.truncatingRemainder(dividingBy: Sim.trackLength)
        if train.position < 0 { train.position += Sim.trackLength }
    }

    /// Zone-controller pass: each locally-owned train's LMA is the tail of
    /// the train ahead (local OR remote) minus the safety margin, or an SP
    /// virtual barrier when one is closer. Direction-aware so reversed
    /// shuttles brake toward the correct barrier. Peer-owned trains are
    /// obstacles only -- their own node computes their authority.
    private func computeMovementAuthorities(world: MetroWorld) {
        let trackLength = Sim.trackLength
        let snapshot = world.trains

        for me in snapshot where me.ownerPeerId == world.localPeerId {
            var minDist = Double.greatestFiniteMagnitude
            var obstaclePos: Double? = nil
            var isSPBarrier = false

            for other in snapshot where other.id != me.id {
                var d: Double = me.travelDirection == .forward
                    ? other.position - me.position
                    : me.position - other.position
                if d <= 0 { d += trackLength }
                if d < minDist {
                    minDist = d
                    obstaclePos = other.position
                }
            }

            var stranded = false
            if let sp = world.activeSP {
                stranded = world.isStranded(me, sp: sp)
                if !stranded {
                    let barriers = [sp.startStationId, sp.endStationId]
                        .compactMap { sid in world.stations.first(where: { $0.id == sid })?.position }
                    for barrier in barriers {
                        var d: Double = me.travelDirection == .forward
                            ? barrier - me.position
                            : me.position - barrier
                        if d <= 0 { d += trackLength }
                        if d <= minDist + 0.1 {
                            minDist = d
                            obstaclePos = barrier
                            isSPBarrier = true
                        }
                    }
                }
            }

            var ma: Double
            if stranded {
                ma = me.position                       // vital stop in place
            } else if let leaderPos = obstaclePos {
                let margin = isSPBarrier ? 0.0 : Sim.safetyMargin
                if me.travelDirection == .forward {
                    ma = leaderPos - margin
                    if ma < 0 { ma += trackLength }
                } else {
                    ma = (leaderPos + margin).truncatingRemainder(dividingBy: trackLength)
                }
            } else {
                // Line to itself all the way around.
                if me.travelDirection == .forward {
                    ma = (me.position + trackLength - Sim.safetyMargin)
                        .truncatingRemainder(dividingBy: trackLength)
                } else {
                    ma = me.position - trackLength + Sim.safetyMargin
                    if ma < 0 { ma += trackLength }
                }
            }

            // Direct write (not mutate): the MA refresh happens every scan
            // for every local train; broadcasting it as an operator event
            // would flood the wire. The periodic state rebroadcast carries it.
            if let idx = world.trains.firstIndex(where: { $0.id == me.id }) {
                world.trains[idx].movementAuthority = ma
                world.trains[idx].targetSpeed = Sim.lineSpeed
            }
        }
    }

    /// SP shuttle behaviour: reverse a rame docked at a terminus pointing
    /// at the barrier, and pace departures from the termini to the
    /// configured headway. Locally-owned rames only.
    private func enforceServiceProvisoire(world: MetroWorld, now: Date) {
        guard let sp = world.activeSP else {
            for t in world.locallyOwned() where t.isDepartureHold {
                world.mutate(t.id) { $0.isDepartureHold = false }
            }
            lastTerminusDeparture.removeAll()
            return
        }
        for t in world.locallyOwned() {
            if t.status == .docked, t.speed == 0, t.paxRemaining == 0, !world.isStranded(t, sp: sp) {
                if (t.lastServicedStationId == sp.startStationId && t.travelDirection == .reverse) ||
                   (t.lastServicedStationId == sp.endStationId && t.travelDirection == .forward) {
                    world.mutate(t.id) { tr in
                        tr.travelDirection = tr.travelDirection == .forward ? .reverse : .forward
                        tr.speed = 0
                        tr.movementAuthority = tr.position
                    }
                }
            }
            let atTerminus = t.status == .docked &&
                (t.lastServicedStationId == sp.startStationId || t.lastServicedStationId == sp.endStationId)
            if atTerminus, let stationId = t.lastServicedStationId {
                let lastDep = lastTerminusDeparture[stationId] ?? .distantPast
                if now.timeIntervalSince(lastDep) < sp.intervalle && lastDep != .distantPast {
                    if !t.isDepartureHold { world.mutate(t.id) { $0.isDepartureHold = true } }
                } else {
                    if t.dwellRemaining <= 0 { lastTerminusDeparture[stationId] = now }
                    if t.isDepartureHold { world.mutate(t.id) { $0.isDepartureHold = false } }
                }
            } else if t.isDepartureHold {
                world.mutate(t.id) { $0.isDepartureHold = false }
            }
        }
    }

    // MARK: -- per-train scan (OBCU logic)

    private func advance(_ train: inout Train, dt: Double, world: MetroWorld) {
        let trackLength = Sim.trackLength

        var effectiveDistToMA = directedDistance(to: train.movementAuthority, train: train)
        if effectiveDistToMA < 0 { effectiveDistToMA += trackLength }

        // Vital overrides: FU, door fault, brake fault, controller-freeze
        // alarm, line-wide emergency -- maximum-rate brake to a stand.
        if train.isDoorFault || train.isBrakeFault || train.isEmergencyBrakeApplied ||
           world.isEmergencyStopped || motionInhibitedByAlarm(world: world) {
            train.status = .emergency
            train.distanceToMA = effectiveDistToMA
            applyPhysics(&train, acceleration: -Sim.emergencyBraking, trackLength: trackLength)
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Line service off: brake to a stand and hold.
        if !world.isRunning {
            if train.speed > 0 {
                applyPhysics(&train, acceleration: -Sim.nominalBraking, trackLength: trackLength)
            } else {
                train.acceleration = 0
                train.status = train.isDwelling ? .docked : .stopped
            }
            train.distanceToMA = effectiveDistToMA
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Manual driving (conduite manuelle limitée).
        if train.mode == .manual {
            if train.doorsOpen {
                train.status = train.speed > 0 ? .moving : .docked
                applyPhysics(&train, acceleration: train.speed > 0 ? -Sim.emergencyBraking : 0, trackLength: trackLength)
            } else {
                let target = min(train.manualSpeedRequest, Sim.manualSpeedMax)
                var desiredAcc: Double = 0
                if train.speed < target { desiredAcc = Sim.maxAcceleration }
                else if train.speed > target { desiredAcc = -Sim.emergencyBraking }
                if train.isEngineFault {
                    desiredAcc = train.speed > 0 ? -0.1 : 0
                }
                train.status = train.speed > 0 ? .moving : .stopped
                applyPhysics(&train, acceleration: applyAdhesion(desiredAcc, train: train), trackLength: trackLength)
            }
            train.distanceToMA = effectiveDistToMA
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Station dwell (à quai, doors open, passenger exchange).
        if train.isDwelling {
            train.dwellRemaining -= dt
            if train.dwellRemaining <= 0 {
                train.passengerCount = max(0, train.passengerCount + train.paxRemaining)
                train.paxRemaining = 0
                train.dwellRemaining = 0
                if !train.isDepartureHold {
                    train.isDwelling = false
                    train.doorsOpen = false
                    train.status = .moving
                    train.lastPaxChange = 0
                    train.paxBoarding = 0
                    train.paxAlighting = 0
                }
            } else {
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
                train.distanceToMA = effectiveDistToMA
                updateAuxiliaries(&train, dt: dt)
                return
            }
        }

        // Target-station resolution: nearest unserviced stop marker within
        // the approach window becomes the stopping target if it's closer
        // than the ZC's authority.
        let servedStations = world.activeStations()
        var distToStop: Double? = nil
        var targetStationId: Int? = nil
        for station in servedStations where train.lastServicedStationId != station.id {
            let d = directedDistance(to: station.position, train: train)
            if d >= -5.0 && d < Sim.stationApproachWindow {
                if distToStop == nil || d < distToStop! {
                    distToStop = d
                    targetStationId = station.id
                }
            }
        }

        if let nextId = targetStationId {
            train.nextStationName = world.stationName(id: nextId)
        }

        if let dist = distToStop, let stationId = targetStationId {
            if dist < effectiveDistToMA { effectiveDistToMA = dist }
            if dist <= Sim.stationStopTolerance && abs(train.speed) < 0.1 {
                beginDwell(&train, stationId: stationId)
                train.distanceToMA = effectiveDistToMA
                updateAuxiliaries(&train, dt: dt)
                return
            }
        } else if let lastId = train.lastServicedStationId,
                  let lastStation = world.stations.first(where: { $0.id == lastId }) {
            let d = directedDistance(to: lastStation.position, train: train)
            if d > 200 { train.lastServicedStationId = nil }
        }

        // Signal fault: the rame loses its radio MA -- ATP collapses the
        // authority to zero and the braking curve stops the train.
        if train.isSignalFault { effectiveDistToMA = 0 }

        // Asservissement (speed regulation): braking-curve target speed,
        // proportional control, vital FU envelope, adhesion model.
        var consigne: Double = 0
        if effectiveDistToMA > Sim.maDistanceMargin {
            let curve = (2 * Sim.nominalBraking * (effectiveDistToMA - Sim.maDistanceMargin)).squareRoot()
            consigne = min(train.targetSpeed, curve)
        }
        let speedError = consigne - train.speed
        var desiredAcc = speedError * 1.0          // Kp = 1.0

        let safeBrakingDistance = (train.speed * train.speed) / (2 * Sim.emergencyBraking)
        if effectiveDistToMA <= safeBrakingDistance + 0.5 {
            desiredAcc = -Sim.emergencyBraking
        }
        if train.isEngineFault {
            desiredAcc = min(desiredAcc, train.speed > 0 ? -0.1 : 0)
        }
        desiredAcc = max(-Sim.emergencyBraking, min(Sim.maxAcceleration, desiredAcc))

        if abs(train.speed) < 0.05 && consigne < 0.1 {
            train.status = .stopped
            train.speed = 0
            desiredAcc = 0
        } else {
            train.status = .moving
        }

        train.consigneVitesse = consigne
        train.speedError = speedError
        train.distanceToMA = effectiveDistToMA

        applyPhysics(&train, acceleration: applyAdhesion(desiredAcc, train: train), trackLength: trackLength)
        updateAuxiliaries(&train, dt: dt)
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
        // Passenger exchange as separate alighting (descente) then boarding
        // (montée) flows so the detail screen can show both; the net change
        // is what the dwell loop applies one-by-one to the load.
        let alighting = Int.random(in: 0...min(Sim.paxAlightMax, train.passengerCount))
        let headroom = max(0, Sim.paxCapacity - (train.passengerCount - alighting))
        let boarding = Int.random(in: 0...min(Sim.paxBoardMax, headroom))
        let change = boarding - alighting
        train.paxBoarding = boarding
        train.paxAlighting = alighting
        train.lastPaxChange = change
        train.paxRemaining = change
        train.paxExchangeInterval = abs(change) > 0 ? (dwell * 0.6) / Double(abs(change)) : 1.0
        train.paxExchangeTimer = 0
    }

    /// Tire-adhesion and patinage / enrayage model applied to the traction
    /// or braking command.
    private func applyAdhesion(_ desiredAcc: Double, train: Train) -> Double {
        var final = desiredAcc
        var adhesion = 0.0
        var drag = 0.0
        for tire in train.tires {
            switch tire.status {
            case .ok:          adhesion += 1.0
            case .lowPressure: adhesion += 0.9; drag += 0.05
            case .puncture:    adhesion += 0.5; drag += 0.2
            case .burst:       adhesion += 0.1; drag += 0.5
            }
        }
        let avg = adhesion / Double(max(1, train.tires.count))
        final *= avg
        if train.isPatinage && final > 0 { final *= 0.2 }
        if train.isEnrayage && final < 0 { final *= 0.3 }
        if train.speed > 0 {
            final -= drag
        } else if train.speed == 0 && final < drag {
            final = max(final, 0) == 0 ? 0 : final - drag
        }
        return final
    }

    private func applyPhysics(_ train: inout Train, acceleration: Double, trackLength: Double) {
        train.acceleration = acceleration
        train.speed += acceleration * Sim.tickInterval
        if train.speed < 0 { train.speed = 0 }
        train.position += train.speed * train.travelDirection.rawValue * Sim.tickInterval
        train.position = train.position.truncatingRemainder(dividingBy: trackLength)
        if train.position < 0 { train.position += trackLength }
    }

    /// Direction-aware distance from the train to an absolute track point,
    /// normalised to (-L/2, L/2].
    private func directedDistance(to target: Double, train: Train) -> Double {
        var d = target - train.position
        if train.travelDirection == .reverse { d = train.position - target }
        if d < -Sim.trackLength / 2 { d += Sim.trackLength }
        else if d > Sim.trackLength / 2 { d -= Sim.trackLength }
        return d
    }

    /// Synthetic-but-plausible auxiliary telemetry so the synoptic and DCL
    /// SHOW RAME sheets read like a live TCMS.
    private func updateAuxiliaries(_ train: inout Train, dt: Double) {
        let motoring = train.acceleration > 0.05
        let braking = train.acceleration < -0.05
        train.tractionCurrent = motoring ? min(1500, 400 + train.speed * 60) : (braking ? 120 : 40)
        train.tractionTorque = max(-100, min(100, train.acceleration / Sim.maxAcceleration * 100))
        train.mainVoltage = 750 - train.tractionCurrent * 0.02
        train.compressorPressure += (train.isCompressorRunning ? 0.08 : -0.01) * dt * 10
        if train.compressorPressure < 7.4 { train.isCompressorRunning = true }
        if train.compressorPressure > 9.0 { train.isCompressorRunning = false }
        train.compressorPressure = max(6.0, min(9.5, train.compressorPressure))

        // Static converter (CVS): ~112 V DC low-voltage bus while the 750 V
        // line is up; it sags if third-rail pickup collapses.
        train.cvsOutputVoltage = train.mainVoltage > 400
            ? 112.0 - (750 - train.mainVoltage) * 0.01
            : max(0, train.cvsOutputVoltage - 40 * dt)
        // Lighting circuit draw follows the lamps and DELESTAGE BT shedding.
        train.lightingCurrent = train.areLightsOn
            ? (train.isLoadSheddingActive ? 5.0 : 15.0)
            : 0.0
        // Friction-brake box heats under service/emergency braking, cools
        // otherwise (bounded to a plausible TCMS range).
        let brakeHeat = (braking || train.isEmergencyBrakeApplied) ? 14.0 : -6.0
        train.brakeBoxTemperature = max(30, min(140, train.brakeBoxTemperature + brakeHeat * dt))
        // Cabin temperature drifts toward the HVAC setpoint; load shedding
        // parks ventilation so it drifts a few degrees warm.
        let comfortTarget = train.targetTemperature + (train.isLoadSheddingActive ? 3.0 : 0.0)
        train.interiorTemperature += (comfortTarget - train.interiorTemperature) * 0.02
        // RAZ MULTIMEDIA is momentary: the reset self-clears once acknowledged.
        if train.isMultimediaResetting { train.isMultimediaResetting = false }
    }

    // MARK: -- alarm sampling

    private func sampleSystemAlarms(world: MetroWorld) {
        switch world.lineMode {
        case .emergency:
            world.raiseAlarm(source: "SYS", point: "SAFETY_MODE", severity: .critical,
                             message: Strings.lookup("alarm.msg.emergency", lang: .en),
                             processDriven: true)
        case .serviceProvisoire:
            world.raiseAlarm(source: "SYS", point: "SAFETY_MODE", severity: .major,
                             message: Strings.lookup("alarm.msg.sp", lang: .en),
                             processDriven: true)
        case .normal, .stopped:
            world.clearAlarm(source: "SYS", point: "SAFETY_MODE")
        }
    }

    private func sampleTrainAlarms(world: MetroWorld, at now: Date) {
        // A node's SCADA only monitors the rames it OWNS. Remote rames are
        // the owning node's responsibility -- sampling their broadcast
        // state here would raise faults this node can't remediate.
        let localTrains = world.locallyOwned()
        let currentIds = Set(localTrains.map(\.id))
        doorOpenSince = doorOpenSince.filter { currentIds.contains($0.key) }

        for train in localTrains {
            let source = "RAME \(train.label)"

            sample(world, source, "OVERSPEED", train.isOverspeed, .critical, "alarm.msg.overspeed")
            sample(world, source, "MA_LIMIT", train.isMAEncroached, .critical, "alarm.msg.malimit")
            sample(world, source, "FU", train.isEmergencyBrakeApplied, .major, "alarm.msg.fu")
            sample(world, source, "PORTES", train.isDoorFault, .critical, "alarm.msg.doorfault")
            sample(world, source, "TRACTION", train.isEngineFault, .major, "alarm.msg.enginefault")
            sample(world, source, "FREIN", train.isBrakeFault, .critical, "alarm.msg.brakefault")
            sample(world, source, "CTC_RADIO", train.isSignalFault, .major, "alarm.msg.signalfault")
            sample(world, source, "PATINAGE", train.isPatinage, .advisory, "alarm.msg.patinage")
            sample(world, source, "ENRAYAGE", train.isEnrayage, .advisory, "alarm.msg.enrayage")

            switch train.worstTire {
            case .ok:
                world.clearAlarm(source: source, point: "PNEU")
            case .lowPressure:
                world.raiseAlarm(source: source, point: "PNEU", severity: .minor,
                                 message: Strings.lookup("alarm.msg.tirelow", lang: .en), processDriven: true)
            case .puncture:
                world.raiseAlarm(source: source, point: "PNEU", severity: .major,
                                 message: Strings.lookup("alarm.msg.tirepuncture", lang: .en), processDriven: true)
            case .burst:
                world.raiseAlarm(source: source, point: "PNEU", severity: .critical,
                                 message: Strings.lookup("alarm.msg.tireburst", lang: .en), processDriven: true)
            }

            let full = Double(train.passengerCount) >= Double(Sim.paxCapacity) * 0.8
            sample(world, source, "PAX_LOAD", full, .advisory, "alarm.msg.paxfull")

            // Doors held open past the dwell in normal running -- a platform
            // obstruction or a stuck door leaf.
            let shouldTrack = train.doorsOpen && world.lineMode != .emergency
            if shouldTrack {
                let since = doorOpenSince[train.id] ?? now
                doorOpenSince[train.id] = since
                if now.timeIntervalSince(since) > Sim.dwellMax + 6.0 && !train.isDepartureHold {
                    world.raiseAlarm(source: source, point: "DOOR_OPEN", severity: .minor,
                                     message: Strings.lookup("alarm.msg.doorheld", lang: .en), processDriven: true)
                } else {
                    world.clearAlarm(source: source, point: "DOOR_OPEN")
                }
            } else {
                doorOpenSince.removeValue(forKey: train.id)
                world.clearAlarm(source: source, point: "DOOR_OPEN")
            }
        }
    }

    /// Sample one process-driven point: raise while the condition holds,
    /// return-to-normal when it clears.
    private func sample(_ world: MetroWorld, _ source: String, _ point: String,
                        _ condition: Bool, _ severity: AlarmSeverity, _ messageKey: String) {
        if condition {
            world.raiseAlarm(source: source, point: point, severity: severity,
                             message: Strings.lookup(messageKey, lang: .en), processDriven: true)
        } else {
            world.clearAlarm(source: source, point: point)
        }
    }

    /// A latched SYS/CONTROLLER fault (PCC watchdog) freezes every local
    /// rame, like a controller-fault interlock in a real DCS.
    private func motionInhibitedByAlarm(world: MetroWorld) -> Bool {
        world.alarmLog.contains { $0.isActive && $0.source == "SYS" && $0.point == "CONTROLLER" }
    }
}
