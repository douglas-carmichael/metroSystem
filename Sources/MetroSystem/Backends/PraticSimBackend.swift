import Foundation

/// The PRATIC network, simulated: a moving-block CBTC scan over the same
/// loop, with the failure modes the front end exists to surface --
/// heartbeat loss, odometry drift, balise fixes, delocalization and
/// operator re-referencing. Runs at `Sim.praticScanHz` and mirrors every
/// train into MetroWorld so the whole retro surface renders it.
///
/// Deliberate simplification: on link loss the (simulated) autopilot
/// brakes to a stand -- the real MA-timeout behaviour -- so the
/// last-known position the PCC shows stays close to the truth while the
/// uncertainty region conveys the doubt. Injections (SET PRATIC
/// /INJECT=...) exercise every state the brief calls out.
@MainActor
final class PraticSimBackend: PraticBackend {
    let network = PraticNetwork()
    var transportState: HardwareLinkState { .ready }

    private weak var world: MetroWorld?
    private var timer: Timer?
    /// Labels under an injected comms loss (heartbeats suppressed).
    private var commsLost: Set<String> = []
    /// Loop coordinate of each train's last balise fix, for drift growth.
    private var lastFixPosition: [UUID: Double] = [:]

    init(world: MetroWorld) {
        self.world = world
        seedTrains()
    }

    private func seedTrains() {
        let count = Sim.praticSeedTrainCount
        for i in 0..<count {
            let position = Double(i) * (Sim.trackLength / Double(count))
            var train = PraticTrain(id: UUID(),
                                    label: String(Sim.praticFirstTrainNumber + i),
                                    position: position,
                                    maLimit: position)
            train.lastUpdate = Date()
            network.trains.append(train)
            lastFixPosition[train.id] = position
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / Sim.praticScanHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        clearAllAlarms()
    }

    // MARK: -- scan (wayside pass + per-train autopilot, like MetroWorld.tick)

    private func scan() {
        guard let world else { return }
        let dt = 1.0 / Sim.praticScanHz
        let now = Date()

        for idx in network.trains.indices {
            network.syncIntents(into: &network.trains[idx], world: world)
        }
        computeAuthorities(now: now)
        // Passenger-service mode (SET PRATIC /SIMULATION=PASSENGER): the
        // autopilot serves the stations; in TEST mode it free-runs on the
        // MA picture alone, the bare CBTC bench.
        let stations = BackendManager.shared.praticPassengerService ? world.activeStations() : []
        for idx in network.trains.indices {
            advance(&network.trains[idx], dt: dt, now: now,
                    isRunning: world.isRunning, stations: stations)
        }
        updateWayside(now: now)
        sampleAlarms(world: world)
        for train in network.trains {
            network.project(train, into: world)
        }
    }

    /// The wayside MA pass: each train's limit of authority is the rear
    /// of the nearest obstacle ahead -- another train's position padded
    /// by ITS uncertainty (a delocalized train casts a wide shadow) --
    /// minus the moving-block margin. An operator MA further restricts.
    private func computeAuthorities(now: Date) {
        let snapshot = network.trains
        for idx in network.trains.indices {
            var me = network.trains[idx]

            if me.confidence == .delocalized {
                // No trusted position -> no authority beyond where it is.
                me.maLimit = me.position
                network.trains[idx] = me
                continue
            }

            var bestDistance = Double.greatestFiniteMagnitude
            var limit: Double
            if me.direction == .forward {
                limit = (me.position + Sim.trackLength - Sim.praticSafetyMargin)
                    .truncatingRemainder(dividingBy: Sim.trackLength)
            } else {
                limit = me.position - Sim.trackLength + Sim.praticSafetyMargin
                if limit < 0 { limit += Sim.trackLength }
            }
            for other in snapshot where other.id != me.id {
                // Envelope rear: the obstacle position pulled toward me
                // by its own uncertainty.
                let pad = other.uncertainty
                var d = me.direction == .forward
                    ? other.position - me.position
                    : me.position - other.position
                if d <= 0 { d += Sim.trackLength }
                d -= pad
                if d < bestDistance {
                    bestDistance = d
                    let margin = Sim.praticSafetyMargin + pad
                    if me.direction == .forward {
                        var l = other.position - margin
                        if l < 0 { l += Sim.trackLength }
                        limit = l
                    } else {
                        limit = (other.position + margin)
                            .truncatingRemainder(dividingBy: Sim.trackLength)
                    }
                }
            }
            // Operator restriction wins when it is nearer.
            if let manual = me.manualMALimit {
                let dManual = network.distanceAhead(from: me, to: manual)
                let dAuto = network.distanceAhead(from: me, to: limit)
                if dManual < dAuto { limit = manual }
            }
            if network.loopDistance(limit, me.maLimit) > 0.5 {
                me.maIssuedAt = now
            }
            me.maLimit = limit
            me.maProfileSpeed = me.targetSpeed
            network.trains[idx] = me
        }
    }

    /// The onboard pass: heartbeat/link model, odometry drift and balise
    /// fixes, confidence derivation, then the autopilot regulation.
    private func advance(_ train: inout PraticTrain, dt: Double, now: Date,
                         isRunning: Bool, stations: [Station]) {
        // Heartbeats arrive every scan unless the comms loss injection
        // holds them; link health derives from the silence.
        if !commsLost.contains(train.label) {
            train.lastUpdate = now
        }
        let silence = now.timeIntervalSince(train.lastUpdate)
        if silence > Sim.praticLinkLost {
            train.linkStatus = .lost
        } else if silence > Sim.praticLinkDegraded {
            train.linkStatus = .degraded
        } else {
            train.linkStatus = .ok
        }

        // Balise fix: crossing a reference with a live link re-anchors
        // the position; between fixes the odometry uncertainty grows
        // with distance travelled.
        let nearest = network.nearestBalise(to: train.position)
        if train.linkStatus == .ok,
           network.loopDistance(nearest.position, train.position) <= Sim.praticBaliseTolerance {
            train.uncertainty = 0
            lastFixPosition[train.id] = train.position
        }

        if silence > Sim.praticDelocalized || train.uncertainty > Sim.praticDelocThreshold {
            train.confidence = .delocalized
        } else if train.linkStatus != .ok || train.uncertainty > Sim.praticDelocThreshold / 2 {
            train.confidence = .uncertain
        } else {
            train.confidence = .localized
        }

        // Station stopping target (auto only -- a manual driver stops by
        // hand): the nearest unserviced served station inside the
        // approach window. The window starts just behind the marker so a
        // train that halts a little past it still counts as arrived.
        // Leaving passenger service (or auto) ends any dwell in progress.
        if stations.isEmpty {
            if train.isDwelling || train.passengerCount > 0 { endDwell(&train, emptyTrain: true) }
            train.lastServicedStationId = nil
        } else if !train.modeAuto && train.isDwelling {
            endDwell(&train, emptyTrain: false)
        }
        var stopDistance: Double? = nil
        train.nextStationId = nil
        if train.modeAuto && !train.isDwelling {
            for station in stations where station.id != train.lastServicedStationId {
                var d = network.distanceAhead(from: train, to: station.position)
                if d > Sim.trackLength - Sim.stationStopTolerance { d -= Sim.trackLength }
                if d < Sim.stationApproachWindow, stopDistance.map({ d < $0 }) ?? true {
                    stopDistance = d
                    train.nextStationId = station.id
                }
            }
        }
        // Once the train has pulled away from its last stop, forget it so
        // a single-station loop (or a short SP) still stops next lap.
        if !train.isDwelling, let lastId = train.lastServicedStationId,
           let last = stations.first(where: { $0.id == lastId }) {
            let behind = network.distanceAhead(from: train, to: last.position)
            if behind > Sim.stationStopTolerance && behind < Sim.trackLength - Sim.stationStopTolerance {
                train.lastServicedStationId = nil
            }
        }

        // Autopilot: emergency stop, MA timeout (link not ok), service
        // off and delocalization all brake to a stand; otherwise regulate
        // to the braking curve toward the nearer of the limit of
        // authority and the station stop marker, then dwell à quai.
        var consigne: Double = 0
        var brakingRate = Sim.nominalBraking
        if train.emergencyStopped || train.confidence == .delocalized {
            brakingRate = Sim.emergencyBraking
        } else if isRunning && train.linkStatus == .ok {
            if train.modeAuto && train.isDwelling {
                // Doors open: hold at a stand until the dwell expires.
                runDwell(&train, dt: dt)
            } else if train.modeAuto, let d = stopDistance, abs(d) <= Sim.stationStopTolerance,
                      train.speed < 0.1, let stationId = train.nextStationId {
                // Arrived on the marker: open up and start the dwell.
                beginDwell(&train, stationId: stationId)
            } else if train.modeAuto {
                let distance = network.distanceAhead(from: train, to: train.maLimit)
                if distance > Sim.maDistanceMargin {
                    let curve = (2 * Sim.nominalBraking * (distance - Sim.maDistanceMargin)).squareRoot()
                    consigne = min(train.maProfileSpeed, curve)
                }
                // The stop marker is a target, not an obstacle: brake to
                // it exactly (no MA margin) so the train halts on it.
                if let d = stopDistance {
                    consigne = min(consigne, (2 * Sim.nominalBraking * max(0, d)).squareRoot())
                }
            } else {
                consigne = min(train.manualSpeedRequest, Sim.manualSpeedMax)
            }
        }
        train.consigne = consigne

        var acceleration: Double
        if train.speed < consigne {
            acceleration = min(Sim.maxAcceleration, (consigne - train.speed) / dt)
        } else {
            acceleration = max(-brakingRate, (consigne - train.speed) / dt)
        }
        if train.emergencyStopped || train.confidence == .delocalized {
            acceleration = train.speed > 0 ? -Sim.emergencyBraking : 0
        }
        train.speed = max(0, train.speed + acceleration * dt)
        let travelled = train.speed * dt
        train.position += travelled * train.direction.rawValue
        train.position = train.position.truncatingRemainder(dividingBy: Sim.trackLength)
        if train.position < 0 { train.position += Sim.trackLength }
        // Odometry drift between fixes.
        train.uncertainty += travelled * Sim.praticUncertaintyGrowth
    }

    // MARK: -- station dwell / passenger exchange (passenger-service mode)

    /// Doors open on the marker: draw the alighting (descente) and
    /// boarding (montée) flows -- the same exchange model as the VAL and
    /// CBTC_SIM backends -- and pace the net change across the dwell.
    private func beginDwell(_ train: inout PraticTrain, stationId: Int) {
        train.speed = 0
        let dwell = Double.random(in: Sim.dwellMin...Sim.dwellMax)
        train.dwellRemaining = dwell
        train.lastServicedStationId = stationId
        let alighting = Int.random(in: 0...min(Sim.paxAlightMax, train.passengerCount))
        let headroom = max(0, Sim.paxCapacity - (train.passengerCount - alighting))
        let boarding = Int.random(in: 0...min(Sim.paxBoardMax, headroom))
        let change = boarding - alighting
        train.paxAlighting = alighting
        train.paxBoarding = boarding
        train.paxRemaining = change
        train.paxExchangeInterval = change != 0 ? (dwell * 0.6) / Double(abs(change)) : 1.0
        train.paxExchangeTimer = 0
    }

    /// One scan of a dwell: step the load one passenger at a time, and
    /// settle the exchange when the doors close.
    private func runDwell(_ train: inout PraticTrain, dt: Double) {
        train.speed = 0
        train.dwellRemaining = max(0, train.dwellRemaining - dt)
        if train.dwellRemaining == 0 {
            endDwell(&train, emptyTrain: false)
            return
        }
        guard train.paxRemaining != 0 else { return }
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

    /// Close the doors: settle any exchange still pending, or -- leaving
    /// passenger service for the TEST bench -- run the train empty.
    private func endDwell(_ train: inout PraticTrain, emptyTrain: Bool) {
        train.passengerCount = emptyTrain
            ? 0
            : max(0, min(Sim.paxCapacity, train.passengerCount + train.paxRemaining))
        train.paxRemaining = 0
        train.paxBoarding = 0
        train.paxAlighting = 0
        train.dwellRemaining = 0
    }

    private func updateWayside(now: Date) {
        for idx in network.stations.indices {
            let station = network.stations[idx]
            guard !station.faulted else { continue }
            let seen = network.trains.contains {
                network.loopDistance($0.position, station.position) <= 2.0
            }
            if seen { network.stations[idx].lastDetection = now }
        }
    }

    // MARK: -- SCADA integration (process-driven raise / return-to-normal)

    private func sampleAlarms(world: MetroWorld) {
        for train in network.trains {
            let source = "RAME \(train.label)"
            if train.confidence == .delocalized {
                world.raiseAlarm(source: source, point: "DELOC", severity: .critical,
                                 message: Strings.lookup("alarm.msg.deloc", lang: .en),
                                 processDriven: true)
            } else {
                world.clearAlarm(source: source, point: "DELOC")
            }
            if train.linkStatus != .ok {
                world.raiseAlarm(source: source, point: "COMMS", severity: .major,
                                 message: Strings.lookup("alarm.msg.comms", lang: .en),
                                 processDriven: true)
            } else {
                world.clearAlarm(source: source, point: "COMMS")
            }
            if train.speed > train.consigne + 1.0 {
                world.raiseAlarm(source: source, point: "OVERSPEED", severity: .critical,
                                 message: Strings.lookup("alarm.msg.overspeed", lang: .en),
                                 processDriven: true)
            } else {
                world.clearAlarm(source: source, point: "OVERSPEED")
            }
        }
        for station in network.stations {
            let source = "WAYSIDE \(station.id)"
            if station.faulted {
                world.raiseAlarm(source: source, point: "SENSOR", severity: .major,
                                 message: Strings.lookup("alarm.msg.wayside", lang: .en),
                                 processDriven: true)
            } else {
                world.clearAlarm(source: source, point: "SENSOR")
            }
        }
    }

    private func clearAllAlarms() {
        guard let world else { return }
        for train in network.trains {
            let source = "RAME \(train.label)"
            world.clearAlarm(source: source, point: "DELOC")
            world.clearAlarm(source: source, point: "COMMS")
            world.clearAlarm(source: source, point: "OVERSPEED")
        }
        for station in network.stations {
            world.clearAlarm(source: "WAYSIDE \(station.id)", point: "SENSOR")
        }
    }

    // MARK: -- command surface

    func issueMovementAuthority(label: String, limit: Double?) -> Bool {
        guard let idx = network.trainIndex(labelled: label) else { return false }
        if let limit {
            guard limit >= 0, limit < Sim.trackLength else { return false }
            network.trains[idx].manualMALimit = limit
        } else {
            network.trains[idx].manualMALimit = nil
        }
        network.trains[idx].maIssuedAt = Date()
        return true
    }

    func setTargetSpeed(label: String, speed: Double) -> Bool {
        guard let idx = network.trainIndex(labelled: label) else { return false }
        network.trains[idx].targetSpeed = max(0, min(Sim.lineSpeed, speed))
        return true
    }

    /// The delocalization recovery: re-reference the train against a
    /// balise (the named one, or the nearest to its last-known position)
    /// and restore the link. The explicit manual action the brief calls
    /// for -- a delocalized train never recovers by itself.
    func relocalize(label: String, baliseId: Int?) -> Bool {
        guard let idx = network.trainIndex(labelled: label) else { return false }
        let balise: PraticBalise
        if let baliseId {
            guard let named = network.balise(id: baliseId) else { return false }
            balise = named
        } else {
            balise = network.nearestBalise(to: network.trains[idx].position)
        }
        commsLost.remove(network.trains[idx].label)
        network.trains[idx].position = balise.position
        network.trains[idx].uncertainty = 0
        network.trains[idx].confidence = .localized
        network.trains[idx].linkStatus = .ok
        network.trains[idx].lastUpdate = Date()
        lastFixPosition[network.trains[idx].id] = balise.position
        return true
    }

    func throwTurnout(id: Int, reversed: Bool) -> Bool {
        guard let idx = network.turnouts.firstIndex(where: { $0.id == id }),
              !network.turnouts[idx].locked else { return false }
        network.turnouts[idx].reversed = reversed
        return true
    }

    func inject(_ injection: PraticInjection) -> Bool {
        switch injection {
        case .commsLoss(let label):
            guard let idx = network.trainIndex(labelled: label) else { return false }
            commsLost.insert(network.trains[idx].label)
            return true
        case .commsRestore(let label):
            guard let idx = network.trainIndex(labelled: label) else { return false }
            commsLost.remove(network.trains[idx].label)
            return true
        case .sensorFault(let stationId):
            guard let idx = network.stations.firstIndex(where: { $0.id == stationId }) else { return false }
            network.stations[idx].faulted = true
            return true
        case .sensorRestore(let stationId):
            guard let idx = network.stations.firstIndex(where: { $0.id == stationId }) else { return false }
            network.stations[idx].faulted = false
            return true
        }
    }

    // Transport plumbing does not apply to the simulation.
    func configureTransport(kind: String?, host: String?, port: UInt16?) -> Bool { false }
    func connectTransport() -> Bool { false }
    func disconnectTransport() {}
}
