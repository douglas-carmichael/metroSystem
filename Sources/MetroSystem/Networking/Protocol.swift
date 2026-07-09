import Foundation

// PEER WIRE.
//
// Newline-delimited JSON over TCP, discovered via Bonjour
// (`_metrosys._tcp`). Mirrored byte-for-byte by the headless daemon in
// ClusterDaemon/Sources/MetroClusterDaemon/Wire.swift -- if you change a
// message or the Train model's CodingKeys, update the mirror to match.

enum PeerOp: String, Codable {
    case hello
    case state
    case remove
    case bye
    case stats
    /// A control request aimed at a rame OWNED BY THE RECEIVER. It lets a
    /// node drive a rame it doesn't own: the request travels to the owning
    /// peer, which applies it to its own rame and broadcasts the resulting
    /// `.state` back. The receiver only ever mutates rames it owns, so this
    /// carries no authority beyond "please apply this to your rame".
    case command
}

/// The manipulations one node can request of another node's rame. Mirrors
/// exactly the exploitation actions the operator can already perform on a
/// locally-owned rame (doors, FU, driving mode, manual speed setpoint).
/// Latched fault injection and tire state remain owner-only by design --
/// they model physical conditions of the owning node's rolling stock.
enum TrainCommandKind: String, Codable {
    case openDoors
    case closeDoors
    case fuSet          // command the emergency brake
    case fuRelease      // release it
    case modeAuto       // conduite automatique
    case modeManual     // conduite manuelle
    case setSpeed       // manual-mode setpoint (value = m/s)
}

/// A control request for a specific remote rame. `value` is only
/// meaningful for `.setSpeed`; `originPeerId` records the requester for
/// audit/logging.
struct TrainCommand: Codable, Hashable {
    var trainId: UUID
    var kind: TrainCommandKind
    var value: Double?
    var originPeerId: String
}

/// Host statistics snapshot carried on `.stats` so MONITOR CLUSTER can
/// show real CPU/mem/IO numbers for every member node.
struct HostSnapshotWire: Codable {
    let cpuBusy: Double            // percent
    let memUsedPercent: Double
    let bufferedIORate: Double
    let directIORate: Double
    let lockRate: Double
    let processCount: Int
    let sampledAt: Date
}

struct PeerMessage: Codable {
    let op: PeerOp
    var peerId: String?
    var label: String?
    var train: Train?
    var trainId: UUID?
    var snapshot: HostSnapshotWire?
    var command: TrainCommand?

    static func hello(peerId: String, label: String) -> PeerMessage {
        PeerMessage(op: .hello, peerId: peerId, label: label, train: nil, trainId: nil, snapshot: nil, command: nil)
    }

    static func state(_ train: Train) -> PeerMessage {
        PeerMessage(op: .state, peerId: nil, label: nil, train: train, trainId: nil, snapshot: nil, command: nil)
    }

    static func remove(_ id: UUID) -> PeerMessage {
        PeerMessage(op: .remove, peerId: nil, label: nil, train: nil, trainId: id, snapshot: nil, command: nil)
    }

    static func bye(peerId: String) -> PeerMessage {
        PeerMessage(op: .bye, peerId: peerId, label: nil, train: nil, trainId: nil, snapshot: nil, command: nil)
    }

    static func stats(peerId: String, snapshot: HostSnapshotWire) -> PeerMessage {
        PeerMessage(op: .stats, peerId: peerId, label: nil, train: nil, trainId: nil, snapshot: snapshot, command: nil)
    }

    static func command(_ command: TrainCommand) -> PeerMessage {
        PeerMessage(op: .command, peerId: nil, label: nil, train: nil, trainId: nil, snapshot: nil, command: command)
    }
}

enum WireCodec {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode(_ msg: PeerMessage) -> Data? {
        guard var body = try? encoder.encode(msg) else { return nil }
        body.append(0x0A)   // newline frame terminator
        return body
    }

    static func decode(_ line: Data) -> PeerMessage? {
        try? decoder.decode(PeerMessage.self, from: line)
    }
}
