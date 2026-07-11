import Foundation

// MODEL-TRACK HARDWARE ABSTRACTION -- SHARED TYPES.
//
// The simulator can mirror its locally-owned rames onto physical model
// trains (an N/HO layout, a DCC command station, a bench of motor
// controllers...). Everything hardware-facing speaks these types:
//
//   RameActuation       one rame's desired physical state (the "output
//                       image" a PLC would write to its outputs)
//   HardwareSensorEvent feedback from the layout (occupancy detectors)
//   HardwareLinkState   health of the link to the command station
//   HardwareConfig      operator-tunable settings, persisted across runs
//
// HardwareBridge samples the simulation and produces RameActuation frames;
// a RameHardwareDriver (see HardwareDriver.swift) turns them into whatever
// protocol the physical equipment speaks. LIKE EVERYTHING ELSE HERE, THIS
// DRIVES HOBBY MODEL TRAINS ONLY -- it is a dispatch simulator, not a
// safety controller, and nothing in it is approved to move a real train.

/// One rame's desired physical state, produced by the bridge every output
/// scan. `speedSteps` is the traction demand quantised to the classic DCC
/// 126-step throttle range so identical frames compare equal (the bridge
/// dedupes on equality) and drivers can map it directly.
struct RameActuation: Codable, Equatable {
    /// Hardware unit the frame addresses (e.g. the DCC cab/locomotive
    /// address). Resolved from the rame label via the config's unit map.
    var unit: Int
    /// Rame label ("101") the frame was derived from, for logs and for
    /// out-of-process drivers that prefer the simulator's naming.
    var label: String
    /// Traction demand, 0...`Sim.hardwareSpeedSteps` (0 = stop).
    var speedSteps: Int
    /// Running direction (true = the loop's forward sense).
    var forward: Bool
    /// Vital stop: FU applied, arret d'urgence general, or the rame is in
    /// its emergency state. Drivers should use their protocol's emergency
    /// stop (not a plain speed-0) where one exists.
    var emergencyStop: Bool
    var doorsOpen: Bool
    var lightsOn: Bool

    /// Normalised 0...1 traction demand, for drivers that want a float.
    var throttle: Double { Double(speedSteps) / Double(Sim.hardwareSpeedSteps) }
}

/// Feedback from the physical layout: an occupancy detector (or any
/// point sensor) changed state. Sensor ids 1...`Sim.cantonCount` are, by
/// convention, the entry detector of the matching canton -- that is what
/// the optional position-resync uses. `receivedAt` is stamped locally and
/// never travels on a wire.
struct HardwareSensorEvent: Codable, Equatable {
    var sensorId: Int
    var active: Bool
    var receivedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case sensorId, active
    }
}

/// Health of the link between the bridge and the physical equipment.
enum HardwareLinkState: Equatable {
    case disconnected
    case connecting
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    /// Localization key for the state's display label (the DCL verbs and
    /// any panel indicator render through this).
    var localizationKey: String {
        switch self {
        case .disconnected: return "hardware.state.offline"
        case .connecting:   return "hardware.state.connecting"
        case .ready:        return "hardware.state.ready"
        case .failed:       return "hardware.state.failed"
        }
    }

    /// The failure detail, when there is one.
    var failureReason: String? {
        if case .failed(let why) = self { return why }
        return nil
    }
}

/// Operator-tunable hardware settings, persisted as JSON under the app's
/// Application Support directory. NOTE: whether the output is ENABLED is
/// deliberately NOT part of this -- the link never drives hardware at
/// launch; the operator must re-arm it each session (SET HARDWARE
/// /ENABLE), the same way a real test bench wants a deliberate action
/// before anything moves.
struct HardwareConfig: Codable {
    /// Registry id of the selected driver ("CONSOLE", "JSONL", "DCCEX", or
    /// a driver a plugin registered).
    var driverId: String = "CONSOLE"
    /// TCP endpoint for the drivers that dial out (JSONL, DCCEX).
    var host: String = "127.0.0.1"
    var port: UInt16 = 2560
    /// Scales the throttle derived from the simulated speed, so a layout
    /// whose locos run scale-fast can be tamed without touching the sim.
    var speedScale: Double = 1.0
    /// When true, an active canton-entry sensor snaps the nearest
    /// locally-owned rame's simulated position to that canton boundary.
    var resyncEnabled: Bool = false
    /// Rame label -> hardware unit. A rame with no entry uses its numeric
    /// label as the unit (rame 101 -> DCC address 101).
    var unitMap: [String: Int] = [:]

    init() {}

    // Tolerant decoding so a config written by an older build (or hand
    // edited) never bricks the store -- missing fields keep their defaults.
    private enum CodingKeys: String, CodingKey {
        case driverId, host, port, speedScale, resyncEnabled, unitMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        driverId = try c.decodeIfPresent(String.self, forKey: .driverId) ?? "CONSOLE"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 2560
        speedScale = try c.decodeIfPresent(Double.self, forKey: .speedScale) ?? 1.0
        resyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .resyncEnabled) ?? false
        unitMap = try c.decodeIfPresent([String: Int].self, forKey: .unitMap) ?? [:]
    }

    /// The hardware unit a rame maps to, or nil when neither an explicit
    /// mapping nor the numeric-label fallback yields a usable address.
    func unit(forLabel label: String) -> Int? {
        if let mapped = unitMap[label] { return mapped > 0 ? mapped : nil }
        if let numeric = Int(label), numeric > 0 { return numeric }
        return nil
    }
}
