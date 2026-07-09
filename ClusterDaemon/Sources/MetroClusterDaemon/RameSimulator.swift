import Foundation

/// Owns one node's fleet of rames and steps them through the same
/// asservissement + zone-controller model the app runs in
/// `MetroWorld.tick()`. Faithfulness matters: the app dead-reckons our
/// rames between `.state` broadcasts, so if our physics diverged from the
/// app's the rame would visibly stutter between corrections.
///
/// SHARED-LOOP CBTC: unlike separate elevator shafts, every node's trains
/// run on the same circular track. The simulator therefore keeps a map of
/// FOREIGN trains (the app's, or another daemon node's), fed from inbound
/// `.state` broadcasts, and its ZC pass treats them as obstacles when
/// computing movement authority for its OWN trains -- each node protects
/// its own trains against the whole picture, exactly one authority per
/// train.
///
/// Deliberately omitted vs. the app: SCADA alarm sampling, service
/// provisoire, and the line-service switch (a daemon node is always in
/// service). Those are per-node exploitation concerns not carried on the
/// peer protocol.
final class RameSimulator {
    private(set) var trains: [Train] = []
    private let ownerPeerId: String

    /// Latest state of every train some other node owns, keyed by id.
    /// Obstacles for the ZC pass; never advanced here.
    private var foreign: [UUID: Train] = [:]

    init(ownerPeerId: String, trainCount: Int, nodeIndex: Int) {
        self.ownerPeerId = ownerPeerId
        spawn(count: max(1, trainCount), nodeIndex: nodeIndex)
    }

    /// Spawn trains evenly around the loop with a per-node phase offset so
    /// two daemon nodes started together don't materialise on top of each
    /// other (the ZC keeps them apart once running).
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
    /// of this node's rames. Mirrors the app's `MetroWorld.applyControl`:
    /// the change lands on the owned rame and is picked up by the next
    /// `.state` broadcast. Requests for a rame this node doesn't own are
    /// ignored. Must be called on the node's serial queue.
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
        case .fuRelease:
            trains[index].isEmergencyBrakeApplied = false
            if trains[index].status == .emergency { trains[index].status = .stopped }
        case .modeAuto:
            trains[index].mode = .auto
            trains[index].manualSpeedRequest = 0
        case .modeManual:
            trains[index].mode = .manual
            trains[index].manualSpeedRequest = 0
        case .setSpeed:
            guard trains[index].mode == .manual else { return }
            trains[index].manualSpeedRequest = max(0, min(Sim.manualSpeedMax, cmd.value ?? 0))
        }
    }

    // MARK: -- scan loop

    func tick(dt: Double) {
        computeMovementAuthorities()
        for index in trains.indices {
            advance(&trains[index], dt: dt)
        }
    }

    /// Zone-controller pass: own trains protected against every known
    /// train, own or foreign (port of MetroWorld.computeMovementAuthorities
    /// without the SP barriers).
    private func computeMovementAuthorities() {
        let trackLength = Sim.trackLength
        let everyone: [Train] = trains + Array(foreign.values)

        for (index, me) in trains.enumerated() {
            var minDist = Double.greatestFiniteMagnitude
            var obstaclePos: Double? = nil

            for other in everyone where other.id != me.id {
                var d: Double = me.travelDirection == .forward
                    ? other.position - me.position
                    : me.position - other.position
                if d <= 0 { d += trackLength }
                if d < minDist {
                    minDist = d
                    obstaclePos = other.position
                }
            }

            var ma: Double
            if let leaderPos = obstaclePos {
                if me.travelDirection == .forward {
                    ma = leaderPos - Sim.safetyMargin
                    if ma < 0 { ma += trackLength }
                } else {
                    ma = (leaderPos + Sim.safetyMargin).truncatingRemainder(dividingBy: trackLength)
                }
            } else {
                ma = (me.position + trackLength - Sim.safetyMargin)
                    .truncatingRemainder(dividingBy: trackLength)
            }
            trains[index].movementAuthority = ma
            trains[index].targetSpeed = Sim.lineSpeed
        }
    }

    // MARK: -- per-train scan (port of MetroWorld.advance)

    private func advance(_ train: inout Train, dt: Double) {
        let trackLength = Sim.trackLength

        var effectiveDistToMA = directedDistance(to: train.movementAuthority, train: train)
        if effectiveDistToMA < 0 { effectiveDistToMA += trackLength }

        // Vital overrides.
        if train.isDoorFault || train.isBrakeFault || train.isEmergencyBrakeApplied {
            train.status = .emergency
            train.distanceToMA = effectiveDistToMA
            applyPhysics(&train, acceleration: -Sim.emergencyBraking, trackLength: trackLength)
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Manual driving.
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

        // Station dwell.
        if train.isDwelling {
            train.dwellRemaining -= dt
            if train.dwellRemaining <= 0 {
                train.passengerCount = max(0, train.passengerCount + train.paxRemaining)
                train.paxRemaining = 0
                train.dwellRemaining = 0
                train.isDwelling = false
                train.doorsOpen = false
                train.status = .moving
                train.lastPaxChange = 0
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

        // Target-station resolution.
        var distToStop: Double? = nil
        var targetStationId: Int? = nil
        for station in Station.all where train.lastServicedStationId != station.id {
            let d = directedDistance(to: station.position, train: train)
            if d >= -5.0 && d < Sim.stationApproachWindow {
                if distToStop == nil || d < distToStop! {
                    distToStop = d
                    targetStationId = station.id
                }
            }
        }

        if let nextId = targetStationId,
           let station = Station.all.first(where: { $0.id == nextId }) {
            train.nextStationName = station.name
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
                  let lastStation = Station.all.first(where: { $0.id == lastId }) {
            let d = directedDistance(to: lastStation.position, train: train)
            if d > 200 { train.lastServicedStationId = nil }
        }

        if train.isSignalFault { effectiveDistToMA = 0 }

        // Asservissement.
        var consigne: Double = 0
        if effectiveDistToMA > Sim.maDistanceMargin {
            let curve = (2 * Sim.nominalBraking * (effectiveDistToMA - Sim.maDistanceMargin)).squareRoot()
            consigne = min(train.targetSpeed, curve)
        }
        let speedError = consigne - train.speed
        var desiredAcc = speedError * 1.0

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
        let headroom = max(0, Sim.paxCapacity - train.passengerCount)
        let change = Int.random(in: -min(Sim.paxAlightMax, train.passengerCount)...min(Sim.paxBoardMax, headroom))
        train.lastPaxChange = change
        train.paxRemaining = change
        train.paxExchangeInterval = abs(change) > 0 ? (dwell * 0.6) / Double(abs(change)) : 1.0
        train.paxExchangeTimer = 0
    }

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

    private func directedDistance(to target: Double, train: Train) -> Double {
        var d = target - train.position
        if train.travelDirection == .reverse { d = train.position - target }
        if d < -Sim.trackLength / 2 { d += Sim.trackLength }
        else if d > Sim.trackLength / 2 { d -= Sim.trackLength }
        return d
    }

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
    }
}
