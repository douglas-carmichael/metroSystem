import Foundation

/// The reference driver and the dry-run tool: needs no equipment, is
/// always "connected", and logs every frame it is handed. Use it to
/// rehearse a mapping (SET HARDWARE /UNIT=...) and watch what would be
/// sent before pointing a real command station at the track -- and read
/// it as the minimal template when writing an in-process driver.
@MainActor
final class ConsoleHardwareDriver: RameHardwareDriver {
    private(set) var state: HardwareLinkState = .disconnected {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((HardwareLinkState) -> Void)?
    var onSensorEvent: ((HardwareSensorEvent) -> Void)?

    func connect(config: HardwareConfig) {
        state = .ready
        NSLog("HW CONSOLE: link open (dry-run, nothing physical attached)")
    }

    func disconnect() {
        state = .disconnected
        NSLog("HW CONSOLE: link closed")
    }

    func apply(_ frames: [RameActuation]) {
        for f in frames {
            NSLog("HW CONSOLE: unit %d (rame %@) steps=%d/%d dir=%@%@%@%@",
                  f.unit, f.label, f.speedSteps, Sim.hardwareSpeedSteps,
                  f.forward ? "FWD" : "REV",
                  f.emergencyStop ? " ESTOP" : "",
                  f.doorsOpen ? " DOORS" : "",
                  f.lightsOn ? " LIGHTS" : "")
        }
    }

    func stopAll() {
        NSLog("HW CONSOLE: STOP ALL")
    }
}
