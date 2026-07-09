import Foundation

// WIRE-COMPATIBLE MIRROR of the app's Train model and Sim constants.
//
// Keep in sync with Sources/MetroSystem/Models/Train.swift (especially
// `CodingKeys`) and Sources/MetroSystem/Models/Constants.swift -- the app
// decodes these bytes. Only the fields that travel on the wire are
// mirrored; app-side extras decode tolerantly on both ends.

enum Sim {
    static let cantonCount: Int = 10
    static let cantonLength: Double = 100.0
    static var trackLength: Double { Double(cantonCount) * cantonLength }

    static let lineSpeed: Double = 15.0
    static let maxAcceleration: Double = 1.0
    static let nominalBraking: Double = 0.8
    static let emergencyBraking: Double = 1.2

    static let safetyMargin: Double = 50.0
    static let maDistanceMargin: Double = 1.0

    static let stationApproachWindow: Double = 150.0
    static let stationStopTolerance: Double = 1.5
    static let dwellMin: Double = 5.0
    static let dwellMax: Double = 10.0
    static let paxCapacity: Int = 120
    static let paxBoardMax: Int = 20
    static let paxAlightMax: Int = 10

    static let tireCount: Int = 8
    static let tireNominalBar: Double = 9.0

    static let manualSpeedMax: Double = 20.0

    static let tickHz: Double = 60.0
    static var tickInterval: Double { 1.0 / tickHz }

    static let bonjourServiceType: String = "_metrosys._tcp"

    /// Mirror of the app's station layout (Lille VAL Ligne 1 flavour).
    static let stationLayout: [(name: String, position: Double)] = [
        ("CHU - Eurasanté",    50.0),
        ("Gambetta",          200.0),
        ("Gare Lille Flandres", 350.0),
        ("Fives",             550.0),
        ("Pont de Bois",      700.0),
        ("4 Cantons",         850.0),
    ]
}

struct Station {
    let id: Int
    let name: String
    let position: Double

    static let all: [Station] = Sim.stationLayout.enumerated().map { (i, s) in
        Station(id: i + 1, name: s.name, position: s.position)
    }
}

enum TravelDirection: Double, Codable {
    case forward = 1.0
    case reverse = -1.0
}

enum TrainMode: String, Codable {
    case auto
    case manual
}

enum TrainStatus: String, Codable {
    case stopped
    case moving
    case emergency
    case docked
}

/// Mirror of the app's `Train`. Property names and CodingKeys must match
/// field-for-field -- this struct IS the `.state` payload the app decodes.
struct Train: Identifiable, Codable {
    let id: UUID
    var label: String
    var ownerPeerId: String = ""
    var position: Double
    var speed: Double = 0
    var acceleration: Double = 0
    var targetSpeed: Double = Sim.lineSpeed
    var movementAuthority: Double = 0
    var travelDirection: TravelDirection = .forward
    var status: TrainStatus = .stopped
    var mode: TrainMode = .auto
    var manualSpeedRequest: Double = 0

    var doorsOpen: Bool = false
    var isDwelling: Bool = false
    var dwellRemaining: TimeInterval = 0
    var isDepartureHold: Bool = false
    var lastServicedStationId: Int? = nil
    var nextStationName: String = "..."

    var passengerCount: Int = 0
    var lastPaxChange: Int = 0
    var paxRemaining: Int = 0
    var paxExchangeInterval: TimeInterval = 0
    var paxExchangeTimer: TimeInterval = 0

    var isDoorFault: Bool = false
    var isEngineFault: Bool = false
    var isBrakeFault: Bool = false
    var isSignalFault: Bool = false
    var isPatinage: Bool = false
    var isEnrayage: Bool = false
    var isEmergencyBrakeApplied: Bool = false

    var consigneVitesse: Double = 0
    var speedError: Double = 0
    var distanceToMA: Double = 0

    struct Tire: Identifiable, Codable {
        let id: Int
        var pressure: Double = Sim.tireNominalBar
        var status: TireStatus = .ok

        enum TireStatus: String, Codable {
            case ok
            case lowPressure
            case puncture
            case burst
        }
    }
    var tires: [Tire] = (1...Sim.tireCount).map { Tire(id: $0) }

    var mainVoltage: Double = 750.0
    var batteryVoltage: Double = 76.5
    var tractionCurrent: Double = 0
    var tractionTorque: Double = 0
    var compressorPressure: Double = 8.5
    var isCompressorRunning: Bool = false
    var interiorTemperature: Double = 22.0

    enum CodingKeys: String, CodingKey {
        case id, label, ownerPeerId, position, speed, acceleration
        case targetSpeed, movementAuthority, travelDirection, status, mode
        case manualSpeedRequest, doorsOpen, isDwelling, dwellRemaining
        case isDepartureHold, lastServicedStationId, nextStationName
        case passengerCount, lastPaxChange, paxRemaining
        case paxExchangeInterval, paxExchangeTimer
        case isDoorFault, isEngineFault, isBrakeFault, isSignalFault
        case isPatinage, isEnrayage, isEmergencyBrakeApplied
        case consigneVitesse, speedError, distanceToMA, tires
        case mainVoltage, batteryVoltage, tractionCurrent, tractionTorque
        case compressorPressure, isCompressorRunning, interiorTemperature
    }

    init(id: UUID, label: String, ownerPeerId: String, position: Double) {
        self.id = id
        self.label = label
        self.ownerPeerId = ownerPeerId
        self.position = position
    }
}
