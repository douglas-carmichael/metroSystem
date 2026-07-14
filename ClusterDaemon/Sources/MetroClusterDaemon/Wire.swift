import Foundation

// WIRE-COMPATIBLE MIRROR of Sources/MetroSystem/Networking/Protocol.swift.
//
// Newline-delimited JSON over TCP. The app uses a plain JSONEncoder /
// JSONDecoder (default `deferredToDate` date strategy) for this channel --
// we must too, or the `.stats` snapshot's `sampledAt` would fail to decode
// on the app side. Optional fields are encoded with `encodeIfPresent`
// (Swift's synthesized Codable), so a `.hello` carries only op/peerId/label.

/// Mirror of the app's `HostSnapshotWire`. Feeds the app's MONITOR CLUSTER
/// per-node row.
struct HostSnapshot: Codable {
    let cpuBusy: Double            // percent
    let memUsedPercent: Double
    let bufferedIORate: Double
    let directIORate: Double
    let lockRate: Double
    let processCount: Int
    let sampledAt: Date
}

enum PeerOp: String, Codable {
    case hello
    case state
    case remove
    case bye
    case stats
    /// A control request aimed at a rame owned by the receiver (see the
    /// app's `Protocol.swift`). The daemon honours these against its own
    /// rames so the app can drive daemon-owned rames remotely.
    case command
}

/// Mirror of the app's `TrainCommandKind`.
enum TrainCommandKind: String, Codable {
    case openDoors
    case closeDoors
    case fuSet
    case fuRelease
    case modeAuto
    case modeManual
    case setSpeed
    // Console A22 (VAL manual driving).
    case pupitreKG
    case pupitreReverser
    case pupitreLever
    case pupitreKIBS
    case pupitreKPH
    case kacopAck
    // AVP redundancy (string selection / comparison mode).
    case avpSelect
    case avpVoting
}

/// Mirror of the app's `TrainCommand`.
struct TrainCommand: Codable {
    var trainId: UUID
    var kind: TrainCommandKind
    var value: Double?
    var originPeerId: String
}

struct PeerMessage: Codable {
    let op: PeerOp
    var peerId: String?
    var label: String?
    var train: Train?
    var trainId: UUID?
    var snapshot: HostSnapshot?
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

    static func stats(peerId: String, snapshot: HostSnapshot) -> PeerMessage {
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
