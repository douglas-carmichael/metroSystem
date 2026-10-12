import Foundation
import Network
import Combine

// PUPITRE LINK -- this node as the PCC of VALPupitreSim cabs.
//
// VALPupitreSim simulates the VAL 206 manual-driving cab -- the console A22
// this app's VAL backend models -- and offers a PCC link (its PCC_API.md):
// it advertises itself over Bonjour, streams its state and, once its
// COMMANDE selector is on PCC, takes its commands from the one PCC holding
// control. This class is that PCC:
//
//   * DISCOVERY -- browses `_valpupitre._tcp` and connects to every cab it
//     finds, plus any address added with SET PUPITRE /ADD (persisted in
//     PUPITRE.JSON next to HARDWARE.JSON).
//   * CONTROL -- takes control of every free cab (one PCC per cab, as one
//     owner per rame) and pings it every second; SET PUPITRE /RELEASE gives
//     a cab back, /ACQUIRE /FORCE takes one from another PCC.
//   * THE LINE -- a cab handed to the PCC is lent this node's loop. It
//     joins at the station farthest from every train, and its rame is
//     mirrored into MetroWorld owned by "pupitre:<cab id>" -- not local, not
//     a peer -- so every surface shows it, PeerNetwork routes its controls
//     here, and the wayside counts it as block occupancy, protecting this
//     node's rames from it.
//   * PROTECTION -- in return the cab gets the stopping point the
//     fixed-block wayside would give it: 8 m short of the first occupied
//     block or barred switch zone ahead, or where it can stop while line
//     service is off. Its PA stops there; running past it trips its FU. A
//     general emergency stop brakes every cab this node controls and
//     releases them again when it ends.
//   * TRAFFIC -- five times a second the cab is told where every other
//     rame on the line is, and shows them on its 3D views.
//   * GEOMETRY -- MetroWorld places a rame by its head, the end leading in
//     its direction of travel; a cab reports the centre of its car 1, at
//     the AV end (its hello says how far each end lies from it). Positions
//     are converted both ways, so the wayside sees where the cab's rame
//     really is and the cab sees the others where they really are.
//   * SCADA -- the samplers only watch local rames, so the link raises the
//     cab rames' FU and VIGILANCE points itself, and PUPITRE when a cab
//     falls silent: its rame is then held where it was last seen, as an
//     obstacle, for `staleHold` seconds before it is dropped.
//
// Cab rames are never broadcast on the peer wire (they are not locally
// owned); every node discovers the cabs for itself. A dispatch simulator
// talking to a cab simulator -- not a safety controller.
@MainActor
final class PupitreLink: ObservableObject {
    static let shared = PupitreLink()

    /// Owner tag of a cab's rame in MetroWorld: the cab owns and simulates
    /// its own train.
    nonisolated static let ownerPrefix = "pupitre:"

    nonisolated static func isCabOwner(_ ownerPeerId: String) -> Bool {
        ownerPeerId.hasPrefix(ownerPrefix)
    }

    enum LinkState { case connecting, ready, down }

    enum Discovery: Equatable {
        case stopped
        case browsing
        case failed(String)
    }

    struct StaticAddress: Codable, Hashable {
        var host: String
        var port: UInt16
    }

    /// One cab as SHOW PUPITRE lists it.
    struct CabSummary {
        let address: String
        let viaBonjour: Bool
        let link: LinkState
        let name: String?
        let rame: String?
        let authority: String?
        let controlledHere: Bool
        let holder: String?
        let lineID: String?
        let position: Double?
        let speed: Double?
        let emergencyBrake: Bool
        let stopPointDistance: Double?
        let lastRefusal: String?
    }

    @Published private(set) var cabs: [CabSummary] = []
    @Published private(set) var discovery: Discovery = .stopped
    @Published private(set) var addresses: [StaticAddress] = []

    /// The line lent to cabs: this node's loop. Same layout, same id on
    /// every node, so a cab one PCC put on the line is on the line of all.
    let lineID: String
    let lineName = "MetroSystem VAL"
    private let lineOut: CabLineOut

    /// How long a silent cab's rame is held on the line as an obstacle.
    static let staleHold: TimeInterval = 30
    private static let heartbeat: TimeInterval = 1
    private static let retry: TimeInterval = 2
    private static let trafficInterval: TimeInterval = 0.2
    /// Cab state samples per second: the telemetry gauges follow at this rate.
    private static let stateRate: Double = 20

    private weak var world: MetroWorld?
    private var browser: NWBrowser?
    private var links: [String: CabLink] = [:]
    private var timer: Timer?
    private var wasEmergency = false
    /// Cabs this node braked for a general emergency stop, to release after.
    private var emergencyBraked: Set<String> = []
    /// Latched stopping points while line service is off.
    private var serviceHolds: [String: Double] = [:]
    private let wayside = VALWayside()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        (lineID, lineOut) = Self.makeLine(name: lineName)
        addresses = Self.loadConfig()?.addresses ?? []
    }

    // MARK: -- lifecycle

    /// Called once from bootstrap(), after the backend: starts discovery,
    /// dials the configured addresses and starts the 10 Hz link scan.
    func attach(world: MetroWorld) {
        self.world = world
        guard timer == nil else { return }
        startBrowser()
        for address in addresses { addLink(for: address) }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var pccName: String {
        "PCC \(world?.localPeerLabel ?? "MetroSystem")"
    }

    // MARK: -- discovery

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PupitreWire.serviceType, domain: nil),
                                using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:              self?.discovery = .browsing
                case .failed(let error):  self?.discovery = .failed("\(error)")
                case .waiting(let error): self?.discovery = .failed("\(error)")
                case .cancelled:          self?.discovery = .stopped
                default:                  break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.browsed(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func browsed(_ results: Set<NWBrowser.Result>) {
        var present: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // A cab speaking another protocol version is left alone.
            if case .bonjour(let txt) = result.metadata, let proto = txt["proto"],
               proto != String(PupitreWire.protocolVersion) { continue }
            let key = "bonjour:" + name
            present.insert(key)
            if links[key] == nil {
                let link = CabLink(key: key, endpoint: result.endpoint, address: name, viaBonjour: true)
                links[key] = link
                connect(link)
            }
        }
        // A service that is gone means the cab has left the network.
        for (key, link) in links where link.viaBonjour && !present.contains(key) {
            drop(link)
        }
        publish()
    }

    private func addLink(for address: StaticAddress) {
        let key = "addr:\(address.host):\(address.port)"
        guard links[key] == nil, let port = NWEndpoint.Port(rawValue: address.port) else { return }
        let link = CabLink(key: key,
                           endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: port),
                           address: "\(address.host) port \(address.port)", viaBonjour: false)
        links[key] = link
        connect(link)
    }

    // MARK: -- connections

    /// One cab connection. The same cab can be reached twice (by Bonjour and
    /// by address): the second link to say hello stands by.
    @MainActor
    private final class CabLink {
        let key: String
        let endpoint: NWEndpoint
        let address: String
        let viaBonjour: Bool
        var connection: NWConnection?
        var state: LinkState = .down
        var inbound = Data()
        var hello: CabHello?
        var rame: String?
        var cab: CabState?
        var downSince: Date?
        var retryAt = Date.distantPast
        var lastPing = Date.distantPast
        var lastAcquire = Date.distantPast
        var lastLine = Date.distantPast
        var lastTraffic = Date.distantPast
        var sentLimit: SentLimit = .unknown
        var limit: (position: Double, perturbed: Bool)?
        var releasedByOperator = false
        var lastRefusal: String?
        var nextID = 0

        enum SentLimit { case unknown, cleared, at(Double) }

        var trainID: UUID? { hello.flatMap { UUID(uuidString: $0.cab.id) } }

        init(key: String, endpoint: NWEndpoint, address: String, viaBonjour: Bool) {
            self.key = key
            self.endpoint = endpoint
            self.address = address
            self.viaBonjour = viaBonjour
        }
    }

    private func connect(_ link: CabLink) {
        link.connection?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let connection = NWConnection(to: link.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        link.connection = connection
        link.state = .connecting
        link.inbound.removeAll()
        connection.stateUpdateHandler = { [weak self, weak link, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let link, let connection, connection === link.connection else { return }
                switch state {
                case .ready:
                    link.state = .ready
                    link.downSince = nil
                    self.send(link, CabRequest(type: "hello", protocol: PupitreWire.protocolVersion,
                                               name: self.pccName, stateRateHz: Self.stateRate))
                    self.receive(link, on: connection)
                    self.publish()
                case .failed, .cancelled, .waiting:
                    // .waiting: refused or unreachable -- retry on our own clock.
                    self.linkDown(link)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ link: CabLink, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak link] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let link, connection === link.connection else { return }
                if let data, !data.isEmpty { self.consume(data, from: link) }
                if isComplete || error != nil {
                    self.linkDown(link)
                } else {
                    self.receive(link, on: connection)
                }
            }
        }
    }

    private func consume(_ data: Data, from link: CabLink) {
        link.inbound.append(data)
        while let newline = link.inbound.firstIndex(of: 0x0A) {
            let line = link.inbound[link.inbound.startIndex..<newline]
            link.inbound.removeSubrange(link.inbound.startIndex...newline)
            if !line.isEmpty { handle(Data(line), from: link) }
            if link.connection == nil { return }
        }
        // A cab never sends lines this long; don't buffer without bound.
        if link.inbound.count > 256 * 1024 { linkDown(link) }
    }

    private func linkDown(_ link: CabLink) {
        guard link.state != .down else { return }
        link.connection?.cancel()
        link.connection = nil
        link.state = .down
        link.downSince = link.downSince ?? Date()
        link.retryAt = Date().addingTimeInterval(Self.retry)
        link.sentLimit = .unknown
        emergencyBraked.remove(link.key)
        // Hold the rame where it was last seen: it is still on the line.
        if let world, let id = link.trainID,
           let idx = world.trains.firstIndex(where: { $0.id == id }) {
            world.trains[idx].speed = 0
            world.trains[idx].acceleration = 0
        }
        publish()
    }

    /// Forget a cab that has left the network: close it and take its rame
    /// off the line.
    private func drop(_ link: CabLink) {
        link.connection?.cancel()
        link.connection = nil
        removeMirror(link)
        emergencyBraked.remove(link.key)
        serviceHolds.removeValue(forKey: link.key)
        links.removeValue(forKey: link.key)
    }

    private func send(_ link: CabLink, _ request: CabRequest) {
        guard let connection = link.connection, link.state == .ready,
              var data = try? encoder.encode(request) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendCommand(_ link: CabLink, _ command: String, _ value: CabValue? = nil) {
        link.nextID += 1
        send(link, CabRequest(type: "command", id: "\(command)-\(link.nextID)",
                              command: command, value: value))
    }

    // MARK: -- inbound

    private func handle(_ line: Data, from link: CabLink) {
        guard let envelope = try? decoder.decode(CabEnvelope.self, from: line) else { return }
        switch envelope.type {
        case "hello":
            if let hello = try? decoder.decode(CabHello.self, from: line) { greeted(link, hello) }
        case "state":
            guard link.hello != nil, let state = try? decoder.decode(CabState.self, from: line) else { return }
            link.cab = state
            project(link)
        case "event":
            if let event = try? decoder.decode(CabEvent.self, from: line),
               event.event == "cab", let rame = event.rame {
                link.rame = rame
                project(link)
                publish()
            }
        case "result":
            if let result = try? decoder.decode(CabResult.self, from: line), !result.ok {
                let what = result.id?.split(separator: "-").first.map(String.init) ?? "?"
                var text = "\(what): \(result.error ?? "?")"
                if let message = result.message { text += " -- \(message)" }
                link.lastRefusal = text
                publish()
            }
        default:
            break
        }
    }

    private func greeted(_ link: CabLink, _ hello: CabHello) {
        guard hello.protocol == PupitreWire.protocolVersion else {
            link.lastRefusal = "protocol \(hello.protocol)"
            linkDown(link)
            link.retryAt = Date().addingTimeInterval(60)
            return
        }
        // One link per cab: a cab reachable twice is served by the first.
        if links.values.contains(where: { $0 !== link && $0.state == .ready
                                          && $0.hello?.cab.id == hello.cab.id }) {
            linkDown(link)
            link.downSince = nil
            link.retryAt = Date().addingTimeInterval(10)
            return
        }
        link.hello = hello
        link.rame = hello.cab.rame
        publish()
    }

    // MARK: -- the 10 Hz scan

    private func scan() {
        guard let world else { return }
        let now = Date()
        if world.isRunning { serviceHolds.removeAll() }

        for link in Array(links.values) {
            switch link.state {
            case .down:
                if now >= link.retryAt { connect(link) }
                if let since = link.downSince, now.timeIntervalSince(since) > Self.staleHold {
                    removeMirror(link)
                    link.downSince = nil
                }
            case .connecting:
                break
            case .ready:
                serve(link, world: world, now: now)
            }
            sampleAlarms(link, world: world)
        }

        // A general emergency stop ended: release what it braked.
        if wasEmergency && !world.isEmergencyStopped {
            for key in emergencyBraked {
                guard let link = links[key], link.state == .ready,
                      link.cab?.emergencyBrake.cause == "pcc" else { continue }
                sendCommand(link, "emergencyBrake", .bool(false))
            }
            emergencyBraked.removeAll()
        }
        wasEmergency = world.isEmergencyStopped
        publish()
    }

    private func serve(_ link: CabLink, world: MetroWorld, now: Date) {
        guard link.hello != nil, let cab = link.cab else { return }

        if now.timeIntervalSince(link.lastPing) >= Self.heartbeat {
            send(link, CabRequest(type: "ping"))
            link.lastPing = now
        }

        // Take control of a free cab -- unless the operator gave it back.
        if !cab.control.you, cab.control.holder == nil, !link.releasedByOperator,
           now.timeIntervalSince(link.lastAcquire) >= Self.retry {
            send(link, CabRequest(type: "acquire", id: "acquire-0"))
            link.lastAcquire = now
        }
        guard cab.control.you else { return }

        // Handed to the PCC and standing: lend it the line.
        if cab.control.authority == "pcc", cab.line.id != lineID, cab.motion.speedMS < 0.1,
           now.timeIntervalSince(link.lastLine) >= Self.retry {
            link.nextID += 1
            send(link, CabRequest(type: "line", id: "line-\(link.nextID)", line: lineOut,
                                  positionM: insertionPosition(excluding: link.trainID, world: world)))
            link.lastLine = now
        }

        guard cab.line.id == lineID, let train = mirror(of: link, in: world) else { return }
        updateLimit(link, train: train, world: world)
        if now.timeIntervalSince(link.lastTraffic) >= Self.trafficInterval {
            sendTraffic(link, excluding: train.id, world: world)
            link.lastTraffic = now
        }

        // General emergency stop: brake the cab once; released afterwards.
        if world.isEmergencyStopped, !cab.emergencyBrake.applied,
           !emergencyBraked.contains(link.key) {
            sendCommand(link, "emergencyBrake", .bool(true))
            emergencyBraked.insert(link.key)
        }
    }

    /// The station farthest from every train on the line -- where
    /// MetroWorld.addTrain would put a new rame, so a cab never joins inside
    /// another rame's block.
    private func insertionPosition(excluding id: UUID?, world: MetroWorld) -> Double {
        let others = world.trains.filter { $0.id != id }
        func clearance(_ position: Double) -> Double {
            others.map { loopDistance($0.position, position) }.min() ?? .greatestFiniteMagnitude
        }
        let best = world.activeStations().max { clearance($0.position) < clearance($1.position) }
        return best?.position ?? Sim.stationLayout[0].position
    }

    // MARK: -- traffic

    /// Tell a cab where the other rames on the line are: every rame in
    /// MetroWorld but its own, local, peer or cab alike.
    private func sendTraffic(_ link: CabLink, excluding id: UUID, world: MetroWorld) {
        let geometry = geometry(of: link)
        let trains = world.trains.filter { $0.id != id }.prefix(64).map { t in
            let label = t.label.trimmingCharacters(in: .whitespaces)
            return CabTrafficTrain(
                rame: label.isEmpty ? "?" : String(label.prefix(16)),
                positionM: cabPosition(ofHead: t.position, t.travelDirection, geometry),
                speedMS: Self.centimetres(max(0, t.speed)),
                sense: t.travelDirection == .reverse ? "AR" : "AV")
        }
        send(link, CabRequest(type: "traffic", id: "traffic", trains: Array(trains)))
    }

    // MARK: -- geometry

    /// Where a cab's rame lies around the position it reports, from its
    /// hello.
    private func geometry(of link: CabLink) -> CabHello.Geometry {
        link.hello?.geometry ?? .val206
    }

    /// The head of a cab's rame -- where MetroWorld places it -- from the
    /// position the cab reports.
    private func head(ofCabAt position: Double, _ direction: TravelDirection,
                      _ geometry: CabHello.Geometry) -> Double {
        wrapped(direction == .forward ? position + geometry.avEndM : position - geometry.arEndM)
    }

    /// The other way round: where a cab would report a rame whose head is
    /// at `head`, to the centimetre.
    private func cabPosition(ofHead head: Double, _ direction: TravelDirection,
                             _ geometry: CabHello.Geometry) -> Double {
        let position = direction == .forward ? head - geometry.avEndM : head + geometry.arEndM
        return wrapped(Self.centimetres(wrapped(position)))
    }

    private static func centimetres(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    // MARK: -- protection

    private func updateLimit(_ link: CabLink, train: Train, world: MetroWorld) {
        let limit = stopLimit(for: train, link: link, world: world)
        link.limit = limit
        // The stopping point goes to the cab as it measures its position.
        let point = limit.map { cabPosition(ofHead: $0.position, train.travelDirection, geometry(of: link)) }
        switch (link.sentLimit, point) {
        case (.at(let sent), .some(let now)) where abs(sent - now) < 0.25:
            return
        case (.cleared, .none):
            return
        case (_, .some(let now)):
            sendCommand(link, "limit", .number(now))
            link.sentLimit = .at(now)
        case (_, .none):
            sendCommand(link, "limit")
            link.sentLimit = .cleared
        }
    }

    /// The stopping point the fixed-block wayside imposes on a cab's rame:
    /// the nearest of 8 m before the first occupied block ahead (VALWayside's
    /// perturbed program), 8 m before a barred switch zone, and -- with line
    /// service off -- where the rame can brake to a stand. Nil: run free.
    private func stopLimit(for train: Train, link: CabLink,
                           world: MetroWorld) -> (position: Double, perturbed: Bool)? {
        let direction = train.travelDirection
        let track = VALTrackDatabase.shared
        var best: (ahead: Double, position: Double, perturbed: Bool)?

        func consider(_ point: Double, perturbed: Bool) {
            let position = wrapped(point)
            var ahead = VALTrackDatabase.distanceAhead(from: train.position, to: position,
                                                       direction: direction)
            // As the cab counts it: just behind is passed, not a lap away.
            if ahead > Sim.trackLength - 50 { ahead -= Sim.trackLength }
            if best == nil || ahead < best!.ahead {
                best = (ahead, position, perturbed)
            }
        }

        // Occupied blocks ahead, from every other rame on the line.
        let others = world.trains.filter { $0.id != train.id }
        let occupancy = wayside.detectOccupancy(trains: others)
        let here = track.block(at: train.position)
        if occupancy[here.id] != nil, others.contains(where: {
            track.block(at: $0.position).id == here.id
                && VALTrackDatabase.distanceAhead(from: train.position, to: $0.position,
                                                  direction: direction) < here.length
        }) {
            // Sharing a block with a rame ahead: stop now.
            consider(train.position, perturbed: true)
        }
        var probe = here
        for step in 0..<track.blocks.count {
            let next = track.nextBlock(after: probe.id, direction: direction)
            if occupancy[next.id] != nil {
                let boundary = direction == .forward ? next.start : next.end
                consider(boundary - direction.rawValue * Sim.perturbedStopMargin, perturbed: step == 0)
                break
            }
            probe = next
        }

        // Switch zones whose points are moving or set against the route.
        if let val = BackendManager.shared.engine as? VALSimBackend {
            for zone in val.switchTable() where zone.reversed || !zone.locked {
                let entry = direction == .forward ? zone.entry : zone.exit
                consider(entry - direction.rawValue * Sim.perturbedStopMargin, perturbed: true)
            }
        }

        // Line service off: nothing departs, and a running rame brakes to a
        // stand where it can (latched, so the point doesn't run ahead of it).
        if !world.isRunning {
            let hold = serviceHolds[link.key] ?? (train.speed < 0.1
                ? train.position
                : train.position + direction.rawValue * (train.speed * train.speed / 2 + 1))
            serviceHolds[link.key] = hold
            consider(hold, perturbed: false)
        }

        return best.map { ($0.position, $0.perturbed) }
    }

    // MARK: -- the rame in MetroWorld

    private func mirror(of link: CabLink, in world: MetroWorld) -> Train? {
        guard let id = link.trainID else { return nil }
        return world.trains.first { $0.id == id }
    }

    /// Write the cab's state onto its rame in MetroWorld -- adding the rame
    /// when the cab arrives on this line, removing it when it leaves.
    private func project(_ link: CabLink) {
        guard let world, let hello = link.hello, let cab = link.cab, let id = link.trainID else { return }
        guard cab.line.id == lineID else {
            removeMirror(link)
            return
        }
        let existing = world.trains.firstIndex { $0.id == id }
        var t = existing.map { world.trains[$0] }
            ?? Train(id: id, label: link.rame ?? hello.cab.rame,
                     ownerPeerId: Self.ownerPrefix + hello.cab.id,
                     position: cab.motion.positionM)
        let previousLabel = existing == nil ? nil : t.label
        t.label = link.rame ?? hello.cab.rame
        t.passengerCount = 0

        t.travelDirection = cab.motion.sense == "AR" ? .reverse : .forward
        t.position = head(ofCabAt: cab.motion.positionM, t.travelDirection, geometry(of: link))
        t.speed = max(0, cab.motion.speedMS)
        t.acceleration = cab.motion.accelerationMS2
        t.mode = cab.cab.pa ? .auto : .manual
        t.manualSpeedRequest = 0

        t.doorsOpen = cab.voyants.port
        t.isDwelling = cab.pa.berthed != nil
        t.dwellRemaining = cab.pa.dwellRemainingS
        t.lastServicedStationId = cab.pa.berthed.map { $0 + 1 }
        t.nextStationName = cab.station.next.flatMap { index in
            world.stations.indices.contains(index) ? world.stations[index].name : nil
        } ?? "..."
        t.isEmergencyBrakeApplied = cab.emergencyBrake.applied
        t.ebCause = Self.tripCause(cab.emergencyBrake.cause)
        if t.isEmergencyBrakeApplied {
            t.status = .emergency
        } else if t.isDwelling || t.doorsOpen {
            t.status = .docked
        } else {
            t.status = t.speed > 0.05 ? .moving : .stopped
        }

        // Console A22, as the cab sets it.
        t.pupitreKG = cab.cab.kg
        t.pupitreReverser = cab.cab.reverser == "AV" ? 1 : (cab.cab.reverser == "AR" ? -1 : 0)
        t.pupitreLever = cab.cab.masterController
        t.pupitreKIBS = cab.cab.kibs
        t.pupitreKPH = cab.cab.kph
        t.kacopSecondsSinceAck = cab.vigilance.timerS
        t.kacopWarning = cab.vigilance.warning

        // The fixed-block picture: the program and stopping point this
        // node's wayside gives the cab, and the speed that respects it.
        let limit = link.limit
        t.speedProgram = (limit?.perturbed == true ? VALSpeedProgram.perturbed : .normal).rawValue
        if let limit {
            t.movementAuthority = limit.position
            t.distanceToMA = max(0, VALTrackDatabase.distanceAhead(
                from: t.position, to: limit.position, direction: t.travelDirection))
        } else {
            t.movementAuthority = wrapped(t.position - t.travelDirection.rawValue * Sim.perturbedStopMargin)
            t.distanceToMA = Sim.trackLength - Sim.perturbedStopMargin
        }
        let ceiling = cab.drive.paActive
            ? (hello.limits?.paCruiseMS ?? Sim.lineSpeed)
            : (hello.limits?.maxSpeedMS ?? Sim.manualSpeedMax)
        let curve = limit == nil ? Double.infinity : (2 * 1.0 * max(0, t.distanceToMA - 1)).squareRoot()
        t.consigneVitesse = min(ceiling, curve)
        t.targetSpeed = t.consigneVitesse
        t.speedError = t.consigneVitesse - t.speed

        if let telemetry = cab.telemetry {
            // The cab's own instruments: its traction chain and auxiliaries,
            // as the VAL backend computes them for a local rame.
            let traction = telemetry.traction, aux = telemetry.auxiliaries
            t.mainVoltage = traction.lineVoltageV
            t.lineCurrent = traction.lineCurrentA
            t.armatureCurrent = traction.armatureCurrentA
            t.excitationCurrent = traction.fieldCurrentA
            t.modulationRatio = traction.chopperDuty
            t.tractionCurrent = traction.tractionCurrentA
            t.tractionTorque = traction.torquePct
            t.cvsOutputVoltage = aux.converterV
            t.batteryVoltage = aux.batteryV
            t.lightingCurrent = aux.lightingA
            t.isCompressorRunning = aux.compressor
            t.compressorPressure = aux.mainReservoirBar
            t.brakeBoxTemperature = aux.brakeBoxC
        } else {
            // A cab that sends no instruments: paint the same plausible TCMS
            // picture the PRATIC mirrors get, from what the cab is doing.
            let demand = max(-1, min(1, cab.drive.demand))
            t.tractionTorque = cab.voyants.trac ? demand * 100 : (cab.voyants.frein ? -abs(demand) * 100 : 0)
            t.tractionCurrent = cab.voyants.trac
                ? min(1500, 400 + t.speed * 60)
                : (cab.voyants.frein ? 120 : (t.speed > 0.05 ? 40 : 0))
            t.mainVoltage = cab.cab.kg ? 750 - t.tractionCurrent * 0.02 : 750
            t.cvsOutputVoltage = 112.0 - (750 - t.mainVoltage) * 0.01
            t.lightingCurrent = (t.areLightsOn ? 15.0 : 0) + (cab.cab.kph ? 2.0 : 0)
        }

        if let existing {
            world.trains[existing] = t
        } else {
            world.upsert(t)
        }
        if let previousLabel, previousLabel != t.label {
            clearAlarms(label: previousLabel, world: world)
        }
    }

    private func removeMirror(_ link: CabLink) {
        guard let world, let id = link.trainID,
              let train = world.trains.first(where: { $0.id == id }) else { return }
        clearAlarms(label: train.label, world: world)
        world.remove(id: id, ownedBy: train.ownerPeerId)
        link.sentLimit = .unknown
        link.limit = nil
    }

    /// The cab's FU causes, in the VAL backend's trip vocabulary.
    private static func tripCause(_ cause: String?) -> String {
        switch cause {
        case nil:                 return VALTripCause.none.rawValue
        case "deadman"?:          return VALTripCause.vigilance.rawValue
        case "pccLink"?:          return VALTripCause.controllerAlarm.rawValue
        case "limit"?:            return VALTripCause.ppOverrun.rawValue
        default:                  return VALTripCause.operatorFU.rawValue
        }
    }

    // MARK: -- SCADA

    private func sampleAlarms(_ link: CabLink, world: MetroWorld) {
        guard let train = mirror(of: link, in: world) else { return }
        let source = "RAME \(train.label)"
        sample(world, source, "FU", train.isEmergencyBrakeApplied, .major, "alarm.msg.fu")
        sample(world, source, "VIGILANCE", train.kacopWarning, .minor, "alarm.msg.kacop")
        sample(world, source, "PUPITRE", link.state != .ready, .major, "alarm.msg.pupitre")
    }

    private func clearAlarms(label: String, world: MetroWorld) {
        for point in ["FU", "VIGILANCE", "PUPITRE"] {
            world.clearAlarm(source: "RAME \(label)", point: point)
        }
    }

    private func sample(_ world: MetroWorld, _ source: String, _ point: String,
                        _ condition: Bool, _ severity: AlarmSeverity, _ messageKey: String) {
        if condition {
            world.raiseAlarm(source: source, point: point, severity: severity,
                             message: Strings.lookup(messageKey, lang: .en), processDriven: true)
        } else {
            world.clearAlarm(source: source, point: point)
        }
    }

    // MARK: -- commands (PeerNetwork routes cab rames here)

    private func link(for train: Train) -> CabLink? {
        links.values.first { $0.trainID == train.id && $0.state == .ready }
            ?? links.values.first { $0.trainID == train.id }
    }

    /// Whether this node can drive the cab: it holds control and the cab is
    /// under PCC command.
    func canControl(_ train: Train) -> Bool {
        guard let link = link(for: train), link.state == .ready, let cab = link.cab else { return false }
        return cab.control.you && cab.control.authority == "pcc"
    }

    /// An exploitation action on a cab's rame, as cab commands. False only
    /// when the cab is unreachable.
    @discardableResult
    func control(_ train: Train, _ kind: TrainCommandKind, value: Double?) -> Bool {
        guard let link = link(for: train), link.state == .ready, let cab = link.cab else { return false }
        func on(_ v: Double?) -> CabValue { .bool((v ?? 0) > 0.5) }
        switch kind {
        case .openDoors:
            sendCommand(link, "doorsOpen", .string("both"))
        case .closeDoors:
            sendCommand(link, "doorsClose")
        case .fuSet:
            sendCommand(link, "emergencyBrake", .bool(true))
        case .fuRelease:
            sendCommand(link, "emergencyBrake", .bool(false))
        case .modeAuto:
            // The cab's PA drives only with KG on and the reverser set.
            if !cab.cab.kg { sendCommand(link, "kg", .bool(true)) }
            if cab.cab.reverser == "0" { sendCommand(link, "reverser", .string("AV")) }
            sendCommand(link, "pa", .bool(true))
        case .modeManual:
            sendCommand(link, "pa", .bool(false))
        case .pupitreKG:
            sendCommand(link, "kg", on(value))
        case .pupitreReverser:
            let v = Int((value ?? 0).rounded())
            sendCommand(link, "reverser", .string(v > 0 ? "AV" : (v < 0 ? "AR" : "0")))
        case .pupitreLever:
            sendCommand(link, "masterController", .number(max(-1, min(1, value ?? 0))))
        case .pupitreKIBS:
            sendCommand(link, "kibs", on(value))
        case .pupitreKPH:
            sendCommand(link, "kph", on(value))
        case .kacopAck:
            sendCommand(link, "kacop")
            // As on a local rame: acknowledging at a stand releases a
            // vigilance trip.
            if cab.emergencyBrake.cause == "deadman" && cab.motion.speedMS < 0.5 {
                sendCommand(link, "emergencyBrake", .bool(false))
            }
        case .setSpeed, .avpSelect, .avpVoting:
            // The cab has no CML governor and no AVP strings.
            break
        }
        return true
    }

    // MARK: -- operator surface (SET PUPITRE)

    private func link(forRame rame: String) -> CabLink? {
        links.values.first { ($0.rame ?? "").caseInsensitiveCompare(rame) == .orderedSame && $0.state == .ready }
    }

    /// Take control of a cab; `force` takes it from another PCC.
    func acquire(rame: String, force: Bool) -> Bool {
        guard let link = link(forRame: rame) else { return false }
        link.releasedByOperator = false
        send(link, CabRequest(type: "acquire", id: "acquire-0", force: force ? true : nil))
        link.lastAcquire = Date()
        return true
    }

    /// Give a cab back; it is not taken again until /ACQUIRE.
    func release(rame: String) -> Bool {
        guard let link = link(forRame: rame) else { return false }
        link.releasedByOperator = true
        send(link, CabRequest(type: "release", id: "release-0"))
        return true
    }

    func addAddress(host: String, port: UInt16) -> Bool {
        let address = StaticAddress(host: host, port: port)
        guard !host.isEmpty, port > 0, !addresses.contains(address) else { return false }
        addresses.append(address)
        persistConfig()
        addLink(for: address)
        return true
    }

    func removeAddress(host: String, port: UInt16) -> Bool {
        let address = StaticAddress(host: host, port: port)
        guard let index = addresses.firstIndex(of: address) else { return false }
        addresses.remove(at: index)
        persistConfig()
        if let link = links["addr:\(host):\(port)"] { drop(link) }
        publish()
        return true
    }

    // MARK: -- summaries

    private func publish() {
        cabs = links.values
            .map { link in
                let cab = link.cab
                return CabSummary(address: link.address,
                                  viaBonjour: link.viaBonjour,
                                  link: link.state,
                                  name: link.hello?.cab.name,
                                  rame: link.rame,
                                  authority: cab?.control.authority,
                                  controlledHere: cab?.control.you ?? false,
                                  holder: cab?.control.holder,
                                  lineID: cab?.line.id,
                                  position: cab?.motion.positionM,
                                  speed: cab?.motion.speedMS,
                                  emergencyBrake: cab?.emergencyBrake.applied ?? false,
                                  stopPointDistance: cab?.limit?.distanceM,
                                  lastRefusal: link.lastRefusal)
            }
            .sorted { ($0.rame ?? "~") .localizedStandardCompare($1.rame ?? "~") == .orderedAscending }
    }

    // MARK: -- helpers

    private func wrapped(_ position: Double) -> Double {
        var p = position.truncatingRemainder(dividingBy: Sim.trackLength)
        if p < 0 { p += Sim.trackLength }
        return p
    }

    private func loopDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, Sim.trackLength - d)
    }

    /// The loop, its stations and cantons, and an id derived from them: the
    /// same layout gives the same id on every node.
    private static func makeLine(name: String) -> (String, CabLineOut) {
        let stations = Sim.stationLayout.map { CabLineOut.Station(name: $0.name, positionM: $0.position) }
        let blocks = (0..<Sim.cantonCount).map {
            CabLineOut.Block(id: $0 + 1, startM: Double($0) * Sim.cantonLength, lengthM: Sim.cantonLength)
        }
        var canonical = "\(Sim.trackLength)"
        for s in stations { canonical += "|\(s.name)@\(s.positionM)" }
        for b in blocks { canonical += "|\(b.startM)+\(b.lengthM)" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let id = "metroSystem-" + String(hash, radix: 16)
        return (id, CabLineOut(id: id, name: name, lengthM: Sim.trackLength, loop: true,
                               stations: stations, blocks: blocks))
    }

    // MARK: -- config persistence

    private struct Config: Codable {
        var addresses: [StaticAddress] = []
    }

    /// JSON sidecar next to HARDWARE.JSON:
    /// ~/Library/Application Support/MetroSystem/PUPITRE.JSON
    private static func configURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MetroSystem", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PUPITRE.JSON")
    }

    private static func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL()) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private func persistConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Config(addresses: addresses)) else { return }
        try? data.write(to: Self.configURL(), options: .atomic)
    }
}
