import Foundation

/// The real PRATIC network: state arrives as normalized telemetry over a
/// PraticTransport, commands go back the same way, and the trains drive
/// themselves (GoA4) -- this backend supervises. What it owns locally is
/// exactly what the brief prescribes for the front end:
///
///   * STALENESS. A watchdog derives link status from heartbeat age and
///     degrades the picture (uncertain, then delocalized with a growing
///     uncertainty region) instead of freezing the last value silently.
///   * INTENT DIFFING. The PCC's FU / mode / manual-speed actions land
///     on the MetroWorld mirror; the watchdog compares them to what was
///     last sent and forwards only the changes as commands.
///   * OPTIMISTIC ECHO. Commands update the local picture immediately
///     and the next telemetry from the network confirms or corrects.
///
/// The MA computation lives wayside in the real system; the dispatcher
/// can still impose a manual restriction (/MA=...), which is forwarded.
@MainActor
final class PraticHardwareBackend: PraticBackend {
    let network = PraticNetwork()
    var transportState: HardwareLinkState { transport.state }

    private weak var world: MetroWorld?
    private var transport: PraticTransport
    private var transportKind: String = "JSONL"
    private(set) var host: String = "127.0.0.1"
    private(set) var port: UInt16 = Sim.praticDefaultPort
    private var timer: Timer?
    /// Last operator intents forwarded per train label, for diffing.
    private struct SentIntents: Equatable {
        var emergencyStopped = false
        var modeAuto = true
        var manualSpeed: Double = 0
        var targetSpeed: Double = Sim.lineSpeed
        var manualMALimit: Double? = nil
    }
    private var sentIntents: [String: SentIntents] = [:]

    init(world: MetroWorld) {
        self.world = world
        transport = PraticJSONLTransport()
        wireTransport()
    }

    private func wireTransport() {
        transport.onMessage = { [weak self] msg in self?.handle(msg) }
        transport.onState = { _ in }   // surfaced via transportState
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / Sim.praticScanHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdog() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        transport.disconnect()
        clearAllAlarms()
    }

    // MARK: -- inbound telemetry

    private func handle(_ msg: PraticWireMessage) {
        let now = Date()
        switch msg.type {
        case "train":
            guard let label = msg.train else { return }
            let idx: Int
            if let existing = network.trainIndex(labelled: label) {
                idx = existing
            } else {
                // First sighting: adopt the train into the picture.
                let fresh = PraticTrain(id: UUID(), label: label,
                                        position: msg.position ?? 0,
                                        maLimit: msg.position ?? 0)
                network.trains.append(fresh)
                network.trains.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
                idx = network.trainIndex(labelled: label) ?? network.trains.count - 1
            }
            var train = network.trains[idx]
            if let p = msg.position {
                train.position = p.truncatingRemainder(dividingBy: Sim.trackLength)
                if train.position < 0 { train.position += Sim.trackLength }
            }
            if let s = msg.speed { train.speed = max(0, s) }
            if let f = msg.forward { train.direction = f ? .forward : .reverse }
            if let c = msg.confidence, let conf = PraticConfidence(rawValue: c) {
                train.confidence = conf
                if conf == .localized { train.uncertainty = 0 }
            }
            if let l = msg.link, let link = PraticLinkStatus(rawValue: l) {
                train.linkStatus = link
            }
            if let limit = msg.limit { train.maLimit = limit; train.maIssuedAt = now }
            if let target = msg.target { train.maProfileSpeed = target }
            train.lastUpdate = now
            train.consigne = min(train.maProfileSpeed, train.targetSpeed)
            network.trains[idx] = train
        case "wayside":
            guard let id = msg.station,
                  let idx = network.stations.firstIndex(where: { $0.id == id }) else { return }
            if let faulted = msg.faulted {
                network.stations[idx].faulted = faulted
            }
            if msg.faulted != true {
                network.stations[idx].lastDetection = now
            }
        case "turnout":
            guard let id = msg.turnout,
                  let idx = network.turnouts.firstIndex(where: { $0.id == id }) else { return }
            if let reversed = msg.reversed { network.turnouts[idx].reversed = reversed }
        default:
            break
        }
    }

    // MARK: -- watchdog scan (staleness + intent diffing + projection)

    private func watchdog() {
        guard let world else { return }
        let now = Date()
        let dt = 1.0 / Sim.praticScanHz

        for idx in network.trains.indices {
            network.syncIntents(into: &network.trains[idx], world: world)
            forwardChangedIntents(&network.trains[idx])

            var train = network.trains[idx]
            let silence = now.timeIntervalSince(train.lastUpdate)
            if silence > Sim.praticLinkLost {
                train.linkStatus = .lost
            } else if silence > Sim.praticLinkDegraded {
                train.linkStatus = .degraded
            }
            if train.linkStatus != .ok {
                // Degrade rather than freeze: the doubt around the
                // last-known position grows with what the train could
                // have travelled since we last heard from it.
                train.uncertainty += train.speed * dt
                train.confidence = silence > Sim.praticDelocalized
                    || train.uncertainty > Sim.praticDelocThreshold
                    ? .delocalized : .uncertain
            }
            network.trains[idx] = train
        }

        sampleAlarms(world: world, transportDown: !transport.state.isReady)
        for train in network.trains {
            network.project(train, into: world)
        }
    }

    /// Forward FU / mode / manual-speed / target / manual-MA changes to
    /// the network, once per change.
    private func forwardChangedIntents(_ train: inout PraticTrain) {
        let current = SentIntents(emergencyStopped: train.emergencyStopped,
                                  modeAuto: train.modeAuto,
                                  manualSpeed: train.manualSpeedRequest,
                                  targetSpeed: train.targetSpeed,
                                  manualMALimit: train.manualMALimit)
        let previous = sentIntents[train.label]
        guard current != previous else { return }
        if previous?.emergencyStopped != current.emergencyStopped {
            transport.send(PraticWireMessage(type: "estop", train: train.label,
                                             engaged: current.emergencyStopped))
        }
        if previous?.modeAuto != current.modeAuto {
            transport.send(PraticWireMessage(type: "mode", train: train.label,
                                             auto: current.modeAuto))
        }
        if previous?.manualSpeed != current.manualSpeed && !current.modeAuto {
            transport.send(PraticWireMessage(type: "target", train: train.label,
                                             target: current.manualSpeed))
        }
        if previous?.targetSpeed != current.targetSpeed {
            transport.send(PraticWireMessage(type: "target", train: train.label,
                                             target: current.targetSpeed))
        }
        if previous?.manualMALimit != current.manualMALimit {
            transport.send(PraticWireMessage(type: "ma", train: train.label,
                                             limit: current.manualMALimit ?? Sim.trackLength,
                                             target: current.targetSpeed))
        }
        sentIntents[train.label] = current
    }

    // MARK: -- SCADA integration

    private func sampleAlarms(world: MetroWorld, transportDown: Bool) {
        if transportDown {
            world.raiseAlarm(source: "PRATIC", point: "TRANSPORT", severity: .critical,
                             message: Strings.lookup("alarm.msg.pratictransport", lang: .en),
                             processDriven: true)
        } else {
            world.clearAlarm(source: "PRATIC", point: "TRANSPORT")
        }
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
        world.clearAlarm(source: "PRATIC", point: "TRANSPORT")
        for train in network.trains {
            let source = "RAME \(train.label)"
            world.clearAlarm(source: source, point: "DELOC")
            world.clearAlarm(source: source, point: "COMMS")
        }
        for station in network.stations {
            world.clearAlarm(source: "WAYSIDE \(station.id)", point: "SENSOR")
        }
    }

    // MARK: -- command surface

    func issueMovementAuthority(label: String, limit: Double?) -> Bool {
        guard let idx = network.trainIndex(labelled: label) else { return false }
        if let limit { guard limit >= 0, limit < Sim.trackLength else { return false } }
        network.trains[idx].manualMALimit = limit
        // The watchdog's intent diff forwards it; nothing else to do.
        return true
    }

    func setTargetSpeed(label: String, speed: Double) -> Bool {
        guard let idx = network.trainIndex(labelled: label) else { return false }
        network.trains[idx].targetSpeed = max(0, min(Sim.lineSpeed, speed))
        return true
    }

    /// Forward the re-reference request; the onboard/wayside pair does
    /// the actual fix. Optimistically mark the train uncertain (pending
    /// confirmation) so the operator sees the action took.
    func relocalize(label: String, baliseId: Int?) -> Bool {
        guard let idx = network.trainIndex(labelled: label) else { return false }
        transport.send(PraticWireMessage(type: "relocalize",
                                         train: network.trains[idx].label,
                                         balise: baliseId))
        if network.trains[idx].confidence == .delocalized {
            network.trains[idx].confidence = .uncertain
        }
        return true
    }

    func throwTurnout(id: Int, reversed: Bool) -> Bool {
        guard let idx = network.turnouts.firstIndex(where: { $0.id == id }),
              !network.turnouts[idx].locked else { return false }
        transport.send(PraticWireMessage(type: "turnout", turnout: id, reversed: reversed))
        network.turnouts[idx].reversed = reversed
        return true
    }

    /// Failure injection is a simulation affordance; the real network
    /// fails on its own terms.
    func inject(_ injection: PraticInjection) -> Bool { false }

    // MARK: -- transport plumbing

    func configureTransport(kind: String?, host: String?, port: UInt16?) -> Bool {
        if let kind {
            switch kind.uppercased() {
            case "JSONL":
                transport.disconnect()
                transport = PraticJSONLTransport()
                transportKind = "JSONL"
            case "SERIAL":
                transport.disconnect()
                transport = PraticSerialTransportStub()
                transportKind = "SERIAL"
            default:
                return false
            }
            wireTransport()
        }
        if let host { self.host = host }
        if let port { self.port = port }
        return true
    }

    var transportDescription: String { "\(transportKind) \(host):\(port)" }

    func connectTransport() -> Bool {
        transport.connect(host: host, port: port)
        return true
    }

    func disconnectTransport() {
        transport.disconnect()
    }
}
