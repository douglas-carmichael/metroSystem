import Foundation
import Network

// MODEL-TRACK HARDWARE ABSTRACTION -- THE DRIVER PLUG POINT.
//
// A RameHardwareDriver turns the bridge's RameActuation frames into
// whatever protocol a piece of physical equipment speaks, and feeds
// layout sensors back. Drivers are registered as descriptors in
// HardwareDriverRegistry; the operator picks one with
// SET HARDWARE /DRIVER=name.
//
// Two ways to plug new hardware in:
//
//  1. IN-PROCESS: write a class conforming to RameHardwareDriver and
//     register a descriptor (one line in HardwareDriverRegistry.init, or
//     from anywhere via HardwareDriverRegistry.shared.register). The
//     built-in CONSOLE / JSONL / DCCEX drivers are the templates.
//
//  2. OUT-OF-PROCESS: run any external program -- Python, Node, an
//     Arduino gateway -- that accepts the JSONL driver's newline-JSON
//     stream (see JSONLinesTCPDriver.swift and
//     docs/hardware-drivers.md). No Swift, no recompile: the process IS
//     the plugin. This is the deliberately-preferred extension point:
//     loading third-party dylibs/bundles into the app would fight code
//     signing and Swift ABI pinning for no gain over a socket.

/// Everything a hardware backend must provide. Drivers are @MainActor,
/// like the rest of the object graph -- Network.framework callbacks must
/// hop to the main actor before touching driver state (the Modbus server
/// establishes the pattern; HardwareTCPLink does it for you).
@MainActor
protocol RameHardwareDriver: AnyObject {
    /// Current link health. Update via `onStateChange` so the bridge and
    /// the DCL verbs track it.
    var state: HardwareLinkState { get }
    /// The bridge wires these after instantiating the driver.
    var onStateChange: ((HardwareLinkState) -> Void)? { get set }
    var onSensorEvent: ((HardwareSensorEvent) -> Void)? { get set }

    /// Open the link described by `config` (host/port for TCP drivers).
    /// Must be safe to call repeatedly; a reconnect drops the old link.
    func connect(config: HardwareConfig)
    func disconnect()

    /// Push a batch of actuation frames. Only called while `state` is
    /// ready and the operator has ENABLEd the output; the bridge has
    /// already deduped, so send everything you are given.
    func apply(_ frames: [RameActuation])

    /// Vital stop for everything on the layout. Called on DISABLE,
    /// disconnect and driver swap -- must be cheap and unconditional.
    func stopAll()

    /// Turn track power on/off where the protocol supports it (DCC-EX
    /// does). Return false when unsupported so the verb can say so.
    func setTrackPower(_ on: Bool) -> Bool
}

extension RameHardwareDriver {
    func setTrackPower(_ on: Bool) -> Bool { false }
}

/// Registry metadata for one driver. `name`/`summary` are vendor metadata
/// (like the LPD product strings and installed-image names): language-
/// neutral technical text, identical in both UI languages.
struct HardwareDriverDescriptor {
    let id: String          // registry key, matched case-insensitively
    let name: String
    let summary: String
    let makeDriver: @MainActor () -> RameHardwareDriver
}

/// The driver catalogue. Built-ins register in init; anything else --
/// a project-specific driver compiled into the app -- can call
/// `register(_:)` before the operator selects it.
@MainActor
final class HardwareDriverRegistry {
    static let shared = HardwareDriverRegistry()

    private(set) var descriptors: [HardwareDriverDescriptor] = []

    private init() {
        register(HardwareDriverDescriptor(
            id: "CONSOLE",
            name: "Console dry-run",
            summary: "Logs every frame; no equipment needed. Wiring/rehearsal aid.",
            makeDriver: { ConsoleHardwareDriver() }))
        register(HardwareDriverDescriptor(
            id: "JSONL",
            name: "Newline-JSON TCP bridge",
            summary: "Streams frames as JSON lines to any external gateway process.",
            makeDriver: { JSONLinesTCPDriver() }))
        register(HardwareDriverDescriptor(
            id: "DCCEX",
            name: "DCC-EX command station",
            summary: "DCC-EX native protocol over TCP (EX-CommandStation, default port 2560).",
            makeDriver: { DCCEXDriver() }))
    }

    func register(_ descriptor: HardwareDriverDescriptor) {
        guard self.descriptor(for: descriptor.id) == nil else { return }
        descriptors.append(descriptor)
    }

    func descriptor(for id: String) -> HardwareDriverDescriptor? {
        descriptors.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}

/// Shared plumbing for the TCP drivers: owns the NWConnection, hops every
/// callback to the main actor (the ModbusClient pattern), and hands the
/// driver raw inbound bytes to frame however its protocol frames them.
@MainActor
final class HardwareTCPLink {
    /// Raw inbound bytes, already on the main actor.
    var onData: ((Data) -> Void)?
    /// Connection-state transitions, already on the main actor.
    var onState: ((HardwareLinkState) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "net.dcarmichael.metro.hardware")

    func connect(host: String, port: UInt16) {
        cancel()
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState?(.failed("bad endpoint \(host):\(port)"))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self else { return }
            Task { @MainActor in
                // A cancelled predecessor still emits events; only the
                // current connection may drive the reported state.
                guard let conn, conn === self.connection else { return }
                switch state {
                case .setup, .preparing:
                    self.onState?(.connecting)
                case .ready:
                    self.onState?(.ready)
                    self.receiveLoop()
                case .waiting(let error):
                    // NWConnection keeps retrying in .waiting; surface the
                    // reason but leave the attempt running.
                    self.onState?(.failed(String(describing: error)))
                case .failed(let error):
                    self.onState?(.failed(String(describing: error)))
                case .cancelled:
                    self.onState?(.disconnected)
                @unknown default:
                    break
                }
            }
        }
        connection = conn
        onState?(.connecting)
        conn.start(queue: queue)
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self, weak conn] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                guard let conn, conn === self.connection else { return }
                if let data, !data.isEmpty {
                    self.onData?(data)
                }
                if isComplete || error != nil {
                    self.onState?(.disconnected)
                    return
                }
                self.receiveLoop()
            }
        }
    }
}
