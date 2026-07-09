import Foundation
import Network
import Combine

// SIMULATION TRANSPORT.
//
// This module uses Bonjour / mDNS (service type `_metrosys._tcp`) to
// discover other PCC nodes on the same LAN -- another Mac running the app,
// or headless ClusterDaemon nodes. In a real CBTC install, the wayside and
// the PCC do NOT find each other by mDNS -- they talk over an engineered,
// redundant backbone with statically configured addressing. Bonjour is
// used here only because the simulator runs on regular macOS hardware;
// the peer-protocol payloads (`Networking/Protocol.swift`) are kept small
// and idempotent so the same code could in principle run over a fieldbus
// driver substituted at this layer.

struct DiscoveredPeer: Identifiable, Hashable {
    let id: String          // remote peerId
    let displayName: String
    let address: String
}

enum PeerNetworkState: String {
    case idle
    case discovering
    case ready
}

@MainActor
final class PeerNetwork: ObservableObject {
    @Published var peers: [DiscoveredPeer] = []
    @Published var state: PeerNetworkState = .idle
    /// Most-recent host-stats snapshot received from each remote peer,
    /// keyed by remote peer id. MONITOR CLUSTER reads this so the
    /// per-node row shows real CPU/mem/IO numbers for every member, not
    /// just the local node.
    @Published var peerStats: [String: HostSnapshotWire] = [:]

    private weak var world: MetroWorld?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "net.dcarmichael.metro.net")
    private var statsTimer: Timer?
    private var stateTimer: Timer?
    private static let statsBroadcastInterval: TimeInterval = 5.0

    private var connections: [String: PeerConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: PeerConnection] = [:]

    // Plain constants captured at init so non-main-actor callbacks can read them.
    nonisolated let localPeerId: String
    nonisolated let localPeerLabel: String

    init(peerId: String = UUID().uuidString,
         label: String = Host.current().localizedName ?? "PCC") {
        self.localPeerId = peerId
        self.localPeerLabel = label
    }

    func attach(world: MetroWorld) {
        self.world = world
        // Operator actions push the fresh state immediately; the periodic
        // rebroadcast below carries the 60 Hz physics motion at a gentler
        // rate.
        world.onLocalChange = { [weak self] train in
            guard let self else { return }
            Task { @MainActor in
                self.broadcast(.state(train))
            }
        }
        world.onLocalRemove = { [weak self] id in
            guard let self else { return }
            Task { @MainActor in
                self.broadcast(.remove(id))
            }
        }
    }

    func start() {
        guard listener == nil else { return }
        state = .discovering
        startListener()
        startBrowser()
        startStatsBroadcast()
        startStateBroadcast()
    }

    func stop() {
        broadcast(.bye(peerId: localPeerId))
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        statsTimer?.invalidate()
        statsTimer = nil
        stateTimer?.invalidate()
        stateTimer = nil
        peerStats.removeAll()
        state = .idle
    }

    private func startStatsBroadcast() {
        statsTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.statsBroadcastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.broadcastLocalSnapshot() }
        }
        statsTimer = t
    }

    /// Periodic `.state` rebroadcast of every locally-owned rame so peers
    /// track our motion (they dead-reckon between these snapshots).
    private func startStateBroadcast() {
        stateTimer?.invalidate()
        let interval = 1.0 / Sim.peerStateBroadcastHz
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.connections.isEmpty,
                      let world = self.world else { return }
                for train in world.locallyOwned() {
                    self.broadcast(.state(train))
                }
            }
        }
        stateTimer = t
    }

    private func broadcastLocalSnapshot() {
        guard !connections.isEmpty else { return }
        let s = HostStats.shared.snapshot()
        let snap = HostSnapshotWire(cpuBusy: s.cpuBusy,
                                    memUsedPercent: s.memUsedPercent,
                                    bufferedIORate: s.bufferedIORate,
                                    directIORate: s.directIORate,
                                    lockRate: s.lockRate,
                                    processCount: s.processCount,
                                    sampledAt: s.sampledAt)
        broadcast(.stats(peerId: localPeerId, snapshot: snap))
    }

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func startListener() {
        let parameters = Self.tcpParameters()
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            NSLog("Failed to create NWListener: \(error)")
            return
        }
        let txt = NWTXTRecord([
            "peerId": localPeerId,
            "label": localPeerLabel,
        ])
        listener.service = NWListener.Service(
            name: localPeerLabel + "-" + String(localPeerId.prefix(8)),
            type: Sim.bonjourServiceType,
            txtRecord: txt
        )
        listener.newConnectionHandler = { [weak self] nwConn in
            guard let self else { return }
            Task { @MainActor in
                self.handleIncoming(nwConn)
            }
        }
        listener.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            Task { @MainActor in
                if case .ready = s { self.state = .ready }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Sim.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleBrowse(results: results)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowse(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata else { continue }
            let remoteId = txt["peerId"] ?? ""
            if remoteId.isEmpty || remoteId == localPeerId { continue }
            if connections[remoteId] != nil { continue }
            if remoteId > localPeerId {
                // Only the higher peerId initiates, so each pair has one connection.
                continue
            }
            openConnection(to: result, expectedPeerId: remoteId)
        }
    }

    private func openConnection(to result: NWBrowser.Result, expectedPeerId: String) {
        let nwConn = NWConnection(to: result.endpoint, using: Self.tcpParameters())
        let peer = PeerConnection(connection: nwConn,
                                   isClientSide: true,
                                   expectedPeerId: expectedPeerId,
                                   queue: queue)
        attachHandlers(peer)
        peer.start()
        pendingConnections[ObjectIdentifier(peer)] = peer
    }

    private func handleIncoming(_ nwConn: NWConnection) {
        let peer = PeerConnection(connection: nwConn,
                                   isClientSide: false,
                                   expectedPeerId: nil,
                                   queue: queue)
        attachHandlers(peer)
        peer.start()
        pendingConnections[ObjectIdentifier(peer)] = peer
    }

    private func attachHandlers(_ peer: PeerConnection) {
        let myId = self.localPeerId
        let myLabel = self.localPeerLabel
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.send(.hello(peerId: myId, label: myLabel))
            Task { @MainActor in
                guard let world = self.world else { return }
                for train in world.locallyOwned() {
                    peer.send(.state(train))
                }
            }
        }
        peer.onMessage = { [weak self, weak peer] msg in
            guard let self, let peer else { return }
            Task { @MainActor in
                self.handle(message: msg, from: peer)
            }
        }
        peer.onClosed = { [weak self, weak peer] in
            guard let self, let peer else { return }
            Task { @MainActor in
                self.cleanup(peer: peer)
            }
        }
    }

    private func handle(message: PeerMessage, from peer: PeerConnection) {
        switch message.op {
        case .hello:
            guard let remoteId = message.peerId else { return }
            if connections[remoteId] != nil {
                peer.cancel()
                pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
                return
            }
            peer.remotePeerId = remoteId
            peer.remoteLabel = message.label ?? remoteId
            connections[remoteId] = peer
            pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
            peers.append(DiscoveredPeer(id: remoteId,
                                        displayName: peer.remoteLabel ?? remoteId,
                                        address: peer.remoteEndpoint))
        case .state:
            guard let train = message.train else { return }
            // Never adopt a rame claiming our own ownership -- a confused
            // peer must not overwrite what we simulate.
            guard train.ownerPeerId != localPeerId else { return }
            world?.upsert(train)
        case .remove:
            guard let id = message.trainId, let world,
                  let remoteId = peer.remotePeerId else { return }
            world.remove(id: id, ownedBy: remoteId)
        case .stats:
            guard let remoteId = peer.remotePeerId, let snap = message.snapshot else { return }
            peerStats[remoteId] = snap
        case .command:
            // A peer is asking us to drive one of OUR rames. applyControl
            // goes through mutate, so a request for a rame we don't own is
            // ignored; the mutation (if any) re-broadcasts the new state to
            // every peer, including the requester.
            guard let cmd = message.command else { return }
            world?.applyControl(trainId: cmd.trainId, kind: cmd.kind, value: cmd.value)
        case .bye:
            cleanup(peer: peer)
        }
    }

    // MARK: -- Remote rame control

    /// Whether this node can issue control commands to `train`: it either
    /// owns the rame (drives it directly) or holds a live link to the
    /// owning peer (forwards the command). Used by the PCC panel to
    /// enable/disable a rame's controls.
    func canControl(_ train: Train) -> Bool {
        if train.ownerPeerId == localPeerId { return true }
        return connections[train.ownerPeerId] != nil
    }

    /// Issue a control action against `train`, whether it's local or
    /// remote. Local rames are mutated in place; remote rames have the
    /// request forwarded to the owning peer over the wire. Returns false
    /// only when the rame is remote and no link to its owner is up.
    @discardableResult
    func control(_ train: Train, _ kind: TrainCommandKind, value: Double? = nil) -> Bool {
        if train.ownerPeerId == localPeerId {
            world?.applyControl(trainId: train.id, kind: kind, value: value)
            return true
        }
        guard let conn = connections[train.ownerPeerId] else { return false }
        conn.send(.command(TrainCommand(trainId: train.id,
                                        kind: kind,
                                        value: value,
                                        originPeerId: localPeerId)))
        return true
    }

    private func cleanup(peer: PeerConnection) {
        pendingConnections.removeValue(forKey: ObjectIdentifier(peer))
        if let remoteId = peer.remotePeerId {
            connections.removeValue(forKey: remoteId)
            peers.removeAll { $0.id == remoteId }
            peerStats.removeValue(forKey: remoteId)
            world?.removeAll(ownedBy: remoteId)
        }
        peer.cancel()
    }

    private func broadcast(_ msg: PeerMessage) {
        for (_, peer) in connections {
            peer.send(msg)
        }
    }
}

final class PeerConnection: @unchecked Sendable {
    let isClientSide: Bool
    let expectedPeerId: String?
    var remotePeerId: String?
    var remoteLabel: String?
    var onReady: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var inboundBuffer = Data()
    private var hasClosed = false

    init(connection: NWConnection, isClientSide: Bool, expectedPeerId: String?, queue: DispatchQueue) {
        self.connection = connection
        self.isClientSide = isClientSide
        self.expectedPeerId = expectedPeerId
        self.queue = queue
    }

    var remoteEndpoint: String {
        switch connection.endpoint {
        case let .hostPort(host, port): return "\(host):\(port.rawValue)"
        case let .service(name, _, _, _): return name
        default: return "?"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveLoop()
            case .failed, .cancelled:
                self.fireClosedOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ msg: PeerMessage) {
        guard let data = WireCodec.encode(msg) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func fireClosedOnce() {
        guard !hasClosed else { return }
        hasClosed = true
        onClosed?()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inboundBuffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                self.fireClosedOnce()
                return
            }
            self.receiveLoop()
        }
    }

    private func drainLines() {
        while let idx = inboundBuffer.firstIndex(of: 0x0A) {
            let line = inboundBuffer[..<idx]
            inboundBuffer.removeSubrange(...idx)
            if let msg = WireCodec.decode(Data(line)) {
                onMessage?(msg)
            }
        }
    }
}
