import Foundation

/// The out-of-process plug point: streams actuation frames as
/// newline-delimited JSON to any TCP listener, and accepts sensor events
/// back on the same socket. An external gateway written in any language
/// adapts the stream to hardware the app has never heard of -- Marklin,
/// LEGO Powered Up, a bench of ESCs -- without recompiling the app. The
/// wire uses the same newline-JSON framing as the peer link (WireCodec).
///
/// Outbound, one JSON object per line:
///   {"type":"actuation","frames":[{"unit":101,"label":"101",
///     "speedSteps":63,"forward":true,"emergencyStop":false,
///     "doorsOpen":false,"lightsOn":true}, ...]}
///   {"type":"stopAll"}
///   {"type":"power","on":true}
///
/// Inbound, one JSON object per line:
///   {"type":"sensor","sensorId":3,"active":true}
@MainActor
final class JSONLinesTCPDriver: RameHardwareDriver {
    private(set) var state: HardwareLinkState = .disconnected {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((HardwareLinkState) -> Void)?
    var onSensorEvent: ((HardwareSensorEvent) -> Void)?

    private let link = HardwareTCPLink()
    private var inbound = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct Outbound: Codable {
        var type: String
        var frames: [RameActuation]? = nil
        var on: Bool? = nil
    }

    private struct Inbound: Codable {
        var type: String
        var sensorId: Int?
        var active: Bool?
    }

    init() {
        link.onState = { [weak self] st in
            guard let self else { return }
            if case .ready = st { self.inbound.removeAll() }
            self.state = st
        }
        link.onData = { [weak self] data in self?.consume(data) }
    }

    func connect(config: HardwareConfig) {
        link.connect(host: config.host, port: config.port)
    }

    func disconnect() {
        link.cancel()
        state = .disconnected
    }

    func apply(_ frames: [RameActuation]) {
        sendLine(Outbound(type: "actuation", frames: frames))
    }

    func stopAll() {
        sendLine(Outbound(type: "stopAll"))
    }

    func setTrackPower(_ on: Bool) -> Bool {
        sendLine(Outbound(type: "power", on: on))
        return true
    }

    private func sendLine(_ message: Outbound) {
        guard var body = try? encoder.encode(message) else { return }
        body.append(0x0A)
        link.send(body)
    }

    /// Frame inbound bytes on newlines; unparseable lines are dropped so a
    /// chatty gateway can't wedge the link.
    private func consume(_ data: Data) {
        inbound.append(data)
        while let nl = inbound.firstIndex(of: 0x0A) {
            let line = inbound.subdata(in: inbound.startIndex..<nl)
            inbound.removeSubrange(inbound.startIndex...nl)
            guard !line.isEmpty,
                  let msg = try? decoder.decode(Inbound.self, from: line),
                  msg.type == "sensor",
                  let id = msg.sensorId, let active = msg.active else { continue }
            onSensorEvent?(HardwareSensorEvent(sensorId: id, active: active))
        }
    }
}
