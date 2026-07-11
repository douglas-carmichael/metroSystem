import Foundation

/// Drives a DCC-EX EX-CommandStation over its native text protocol on
/// TCP (an EX-CommandStation with WiFi/Ethernet listens on port 2560).
/// This is the driver that puts simulated rames on a real DCC layout:
/// each rame's actuation frame becomes a `<t>` throttle command against
/// its mapped cab address, plus `<F>` function commands for the lights
/// (F0) and a doors cue (F1 -- commonly mapped to a door/sound effect on
/// models that have one).
///
///   <t 1 CAB SPEED DIR>   throttle: SPEED 0..126, -1 = emergency stop,
///                         DIR 1 = forward, 0 = reverse
///   <F CAB FUNC STATE>    decoder function on/off
///   <!>                   emergency stop everything
///   <1> / <0>             track power on / off
///
/// Feedback: DCC-EX broadcasts `<Q id>` / `<q id>` when a defined sensor
/// goes active / inactive; both surface as HardwareSensorEvents (define
/// sensors 1..N at the canton-entry detectors to use the position resync).
/// Track power is never switched implicitly -- the operator does it with
/// SET HARDWARE /POWER=ON, mirroring how a layout is actually worked.
@MainActor
final class DCCEXDriver: RameHardwareDriver {
    private(set) var state: HardwareLinkState = .disconnected {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((HardwareLinkState) -> Void)?
    var onSensorEvent: ((HardwareSensorEvent) -> Void)?

    private let link = HardwareTCPLink()
    private var inbound = ""

    init() {
        link.onState = { [weak self] st in
            guard let self else { return }
            if case .ready = st {
                self.inbound = ""
                // Ask the station to identify itself; the reply also
                // confirms the link is really a command station.
                self.send("<s>")
            }
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
        for f in frames {
            let steps = f.emergencyStop ? -1 : min(Sim.hardwareSpeedSteps, max(0, f.speedSteps))
            send("<t 1 \(f.unit) \(steps) \(f.forward ? 1 : 0)>")
            send("<F \(f.unit) 0 \(f.lightsOn ? 1 : 0)>")
            send("<F \(f.unit) 1 \(f.doorsOpen ? 1 : 0)>")
        }
    }

    func stopAll() {
        send("<!>")
    }

    func setTrackPower(_ on: Bool) -> Bool {
        send(on ? "<1>" : "<0>")
        return true
    }

    private func send(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        link.send(data)
    }

    /// DCC-EX frames messages in angle brackets; accumulate text and pull
    /// out each complete `<...>`, tolerating noise between frames.
    private func consume(_ data: Data) {
        inbound += String(decoding: data, as: UTF8.self)
        while let close = inbound.firstIndex(of: ">") {
            let chunk = String(inbound[..<close])
            inbound = String(inbound[inbound.index(after: close)...])
            guard let open = chunk.lastIndex(of: "<") else { continue }
            handleMessage(String(chunk[chunk.index(after: open)...]))
        }
        // Discard unframed noise so the buffer can't grow without bound.
        if inbound.count > 4096, !inbound.contains("<") { inbound = "" }
    }

    /// The body between the brackets, e.g. "Q 3" (sensor 3 active) or
    /// "q 3" (inactive). Everything else -- status, throttle echoes -- is
    /// ignored for now.
    private func handleMessage(_ body: String) {
        let parts = body.split(separator: " ")
        guard parts.count >= 2, let id = Int(parts[1]) else { return }
        switch parts[0] {
        case "Q": onSensorEvent?(HardwareSensorEvent(sensorId: id, active: true))
        case "q": onSensorEvent?(HardwareSensorEvent(sensorId: id, active: false))
        default: break
        }
    }
}
