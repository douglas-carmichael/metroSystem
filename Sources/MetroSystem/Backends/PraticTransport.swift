import Foundation

// PRATIC TRANSPORT -- the normalized state stream.
//
// The brief's rule: decouple transport from rendering. The physical link
// to the PRATIC network may be RF, serial or IR; the front end consumes
// a normalized message stream and does not care about the wire. This
// file is that seam: PraticHardwareBackend talks only to the
// PraticTransport protocol, and each transport turns the messages into
// whatever its medium carries.
//
// Shipping transports:
//   JSONL   newline-delimited JSON over TCP -- works today against any
//           gateway process (a Pi bridging the RF link, a laptop on the
//           bench). The reference wire, documented in
//           docs/pratic-backends.md.
//   SERIAL  a stub that fails cleanly with a pointer here -- the place
//           to integrate the real serial/RF hardware when it exists.

/// One normalized message, both directions. A flat envelope keyed by
/// `type` keeps the wire trivially readable and versionable; absent
/// fields are omitted from the JSON entirely.
///
/// Telemetry (network -> front end):
///   {"type":"train","train":"201","position":123.4,"speed":2.1,
///    "forward":true,"confidence":"localized","link":"ok"}
///   {"type":"wayside","station":3,"faulted":false}       detection ping
///   {"type":"turnout","turnout":1,"reversed":true}
///
/// Commands (front end -> network):
///   {"type":"ma","train":"201","limit":350.0,"target":10.0}
///   {"type":"target","train":"201","target":8.0}
///   {"type":"mode","train":"201","auto":false}
///   {"type":"estop","train":"201","engaged":true}         train-scoped
///   {"type":"estop","engaged":true}                       network-wide
///   {"type":"relocalize","train":"201","balise":4}
///   {"type":"turnout","turnout":1,"reversed":true}
struct PraticWireMessage: Codable {
    var type: String
    var train: String? = nil
    var position: Double? = nil
    var speed: Double? = nil
    var forward: Bool? = nil
    var confidence: String? = nil
    var link: String? = nil
    var station: Int? = nil
    var faulted: Bool? = nil
    var turnout: Int? = nil
    var reversed: Bool? = nil
    var limit: Double? = nil
    var target: Double? = nil
    var auto: Bool? = nil
    var engaged: Bool? = nil
    var balise: Int? = nil
}

@MainActor
protocol PraticTransport: AnyObject {
    var state: HardwareLinkState { get }
    var onState: ((HardwareLinkState) -> Void)? { get set }
    var onMessage: ((PraticWireMessage) -> Void)? { get set }

    func connect(host: String, port: UInt16)
    func disconnect()
    func send(_ message: PraticWireMessage)
}

/// Newline-JSON over TCP, built on the same HardwareTCPLink plumbing as
/// the model-track drivers. The gateway on the other end owns the radio.
@MainActor
final class PraticJSONLTransport: PraticTransport {
    private(set) var state: HardwareLinkState = .disconnected {
        didSet { onState?(state) }
    }
    var onState: ((HardwareLinkState) -> Void)?
    var onMessage: ((PraticWireMessage) -> Void)?

    private let link = HardwareTCPLink()
    private var inbound = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        link.onState = { [weak self] st in
            guard let self else { return }
            if case .ready = st { self.inbound.removeAll() }
            self.state = st
        }
        link.onData = { [weak self] data in self?.consume(data) }
    }

    func connect(host: String, port: UInt16) {
        link.connect(host: host, port: port)
    }

    func disconnect() {
        link.cancel()
        state = .disconnected
    }

    func send(_ message: PraticWireMessage) {
        guard var body = try? encoder.encode(message) else { return }
        body.append(0x0A)
        link.send(body)
    }

    private func consume(_ data: Data) {
        inbound.append(data)
        while let nl = inbound.firstIndex(of: 0x0A) {
            let line = inbound.subdata(in: inbound.startIndex..<nl)
            inbound.removeSubrange(inbound.startIndex...nl)
            guard !line.isEmpty,
                  let msg = try? decoder.decode(PraticWireMessage.self, from: line) else { continue }
            onMessage?(msg)
        }
    }
}

/// INTEGRATION STUB for the direct serial / RF link.
///
/// When the physical PRATIC comms hardware is on the bench, implement
/// this class: open the device (ORSSerialPort, IOKit, or a USB-CDC
/// bridge), frame the byte stream, and translate frames to and from
/// PraticWireMessage. Until then it fails cleanly so the operator sees
/// exactly what is missing, and the JSONL transport (plus an external
/// gateway) remains the working path.
@MainActor
final class PraticSerialTransportStub: PraticTransport {
    private(set) var state: HardwareLinkState = .disconnected {
        didSet { onState?(state) }
    }
    var onState: ((HardwareLinkState) -> Void)?
    var onMessage: ((PraticWireMessage) -> Void)?

    func connect(host: String, port: UInt16) {
        // TODO(pratic-hw): open the serial device named by `host`
        // (e.g. /dev/cu.usbserial-XXXX) at the agreed baud rate, start a
        // read loop, and drive onMessage/onState. See
        // docs/pratic-backends.md, "Writing a transport".
        state = .failed("SERIAL transport not implemented -- use JSONL, or integrate here")
    }

    func disconnect() {
        state = .disconnected
    }

    func send(_ message: PraticWireMessage) {
        // TODO(pratic-hw): frame and write the command to the device.
    }
}
