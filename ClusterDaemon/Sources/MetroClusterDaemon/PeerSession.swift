import Foundation

// Transport-agnostic peer-protocol coordinator.
//
// The `hello`/`state`/`stats`/`bye` handshake, the connection dedup keyed
// by peerId, the "higher peerId dials out so each pair forms one link"
// rule, and broadcast live here, once, over the minimal `RawConn`
// abstraction; the transport backend only differs in how connections are
// made and discovered.
//
// Threading contract: every method here runs on the node's serial queue,
// and a `RawConn` MUST deliver its `onReady`/`onMessage`/`onClosed`
// callbacks on that same queue. So there are no locks.

/// One framed peer connection, however it's transported.
protocol RawConn: AnyObject {
    var remotePeerId: String? { get set }
    var remoteLabel: String? { get set }
    /// One-shot flags so an inbound `.state`/`.stats`/`.command` is logged
    /// once per peer as a wire round-trip confirmation, not at the
    /// broadcast rate.
    var didLogInboundState: Bool { get set }
    var didLogInboundStats: Bool { get set }
    var didLogInboundCommand: Bool { get set }
    var onReady: (() -> Void)? { get set }
    var onMessage: ((PeerMessage) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func start()
    func send(_ msg: PeerMessage)
    func cancel()
}

/// The per-node link surface `ClusterNode` drives, regardless of backend.
protocol PeerLink: AnyObject {
    var connectionCount: Int { get }
    func start()
    func stop(sendBye: Bool)
    func broadcast(_ msg: PeerMessage)
}

final class PeerSession {
    let peerId: String
    let label: String

    private let logger: Logger
    /// Supplies the node's current rames so a freshly-connected peer gets a
    /// `.state` for each straight after the `.hello`.
    private let trainsProvider: () -> [Train]
    /// Applies a peer-forwarded control request to one of this node's
    /// rames (see `RameSimulator.apply`). Called on the serial queue.
    private let commandSink: (TrainCommand) -> Void
    /// Feeds inbound foreign-train state into the simulator so its ZC pass
    /// can protect this node's trains against the whole shared loop.
    private let foreignUpsert: (Train) -> Void
    private let foreignRemove: (UUID) -> Void
    private let foreignRemovePeer: (String) -> Void

    private var connections: [String: RawConn] = [:]
    private var pending: [ObjectIdentifier: RawConn] = [:]

    var connectionCount: Int { connections.count }

    init(peerId: String, label: String, logger: Logger,
         trainsProvider: @escaping () -> [Train],
         commandSink: @escaping (TrainCommand) -> Void,
         foreignUpsert: @escaping (Train) -> Void,
         foreignRemove: @escaping (UUID) -> Void,
         foreignRemovePeer: @escaping (String) -> Void) {
        self.peerId = peerId
        self.label = label
        self.logger = logger
        self.trainsProvider = trainsProvider
        self.commandSink = commandSink
        self.foreignUpsert = foreignUpsert
        self.foreignRemove = foreignRemove
        self.foreignRemovePeer = foreignRemovePeer
    }

    /// Take ownership of a new connection (inbound or outbound), wire its
    /// callbacks, and start it. Must be called on the serial queue.
    func adopt(_ conn: RawConn) {
        attach(conn)
        pending[ObjectIdentifier(conn)] = conn
        conn.start()
    }

    func broadcast(_ msg: PeerMessage) {
        for conn in connections.values { conn.send(msg) }
    }

    func stop(sendBye: Bool) {
        if sendBye { broadcast(.bye(peerId: peerId)) }
        for conn in connections.values { conn.cancel() }
        for conn in pending.values { conn.cancel() }
        connections.removeAll()
        pending.removeAll()
    }

    /// True if we already have (or are dialing) this peer — lets a backend
    /// skip a redundant outbound dial.
    func hasPeer(_ remoteId: String) -> Bool {
        if connections[remoteId] != nil { return true }
        for c in pending.values where c.remotePeerId == remoteId { return true }
        return false
    }

    // MARK: -- callbacks

    private func attach(_ conn: RawConn) {
        conn.onReady = { [weak self, weak conn] in
            guard let self, let conn else { return }
            conn.send(.hello(peerId: self.peerId, label: self.label))
            for train in self.trainsProvider() { conn.send(.state(train)) }
        }
        conn.onMessage = { [weak self, weak conn] msg in
            guard let self, let conn else { return }
            self.handle(msg, from: conn)
        }
        conn.onClosed = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.cleanup(conn)
        }
    }

    private func handle(_ message: PeerMessage, from conn: RawConn) {
        switch message.op {
        case .hello:
            guard let remoteId = message.peerId else { return }
            if connections[remoteId] != nil {
                // The other dedup race path already won — drop this duplicate.
                conn.cancel()
                pending.removeValue(forKey: ObjectIdentifier(conn))
                return
            }
            conn.remotePeerId = remoteId
            conn.remoteLabel = message.label ?? remoteId
            connections[remoteId] = conn
            pending.removeValue(forKey: ObjectIdentifier(conn))
            logger.log("[\(label)] peer UP  \(conn.remoteLabel ?? remoteId) [\(String(remoteId.prefix(8)))] — \(connections.count) link(s)")
        case .bye:
            cleanup(conn)
        case .state:
            // Track the sender's trains as ZC obstacles on the shared loop.
            // Log the first decoded `.state` per peer to confirm the full
            // wire round-trip (their encode → our decode of the shared
            // Train model).
            guard let train = message.train else { return }
            foreignUpsert(train)
            if !conn.didLogInboundState {
                conn.didLogInboundState = true
                logger.log(String(format: "[%@] rx STATE ok — train %@ @ %.0f m from %@",
                                  label, train.label, train.position, conn.remoteLabel ?? "?"))
            }
        case .remove:
            if let id = message.trainId { foreignRemove(id) }
        case .stats:
            if !conn.didLogInboundStats, let snap = message.snapshot {
                conn.didLogInboundStats = true
                logger.log(String(format: "[%@] rx STATS ok — %@ cpu %.0f%% mem %.0f%%",
                                  label, conn.remoteLabel ?? "?", snap.cpuBusy, snap.memUsedPercent))
            }
        case .command:
            // A peer (the app) is driving one of our rames. Apply it to the
            // sim; the next `.state` broadcast carries the result back.
            if let cmd = message.command {
                if !conn.didLogInboundCommand {
                    conn.didLogInboundCommand = true
                    logger.log("[\(label)] rx CMD ok — \(cmd.kind.rawValue)\(cmd.value.map { String(format: " %.1f", $0) } ?? "") from \(conn.remoteLabel ?? "?")")
                }
                commandSink(cmd)
            }
        }
    }

    private func cleanup(_ conn: RawConn) {
        pending.removeValue(forKey: ObjectIdentifier(conn))
        if let remoteId = conn.remotePeerId {
            connections.removeValue(forKey: remoteId)
            foreignRemovePeer(remoteId)
            logger.log("[\(label)] peer DOWN \(conn.remoteLabel ?? remoteId) [\(String(remoteId.prefix(8)))] — \(connections.count) link(s)")
        }
        conn.cancel()
    }
}
