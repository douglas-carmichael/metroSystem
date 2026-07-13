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

    // VAL 206 motion profile (DOT assessment values, as in the app).
    static let lineSpeed: Double = 15.0
    static let maxAcceleration: Double = 1.3
    static let nominalBraking: Double = 1.3
    static let emergencyBraking: Double = 2.15
    static let jerkMax: Double = 0.65

    static let safetyMargin: Double = 50.0
    static let maDistanceMargin: Double = 1.0

    // Fixed-block AVP parameters (mirror of the app's VAL backend).
    static let perturbedStopMargin: Double = 8.0
    static let avpOverspeedRatio: Double = 0.30 / 0.27
    static let manualPenetrationTrip: Double = 10.0
    static let rollbackTrip: Double = 5.0
    static let stationBlockSpeed: Double = 8.0
    static let asmdSpeed: Double = 0.8
    static let beaconB1Distance: Double = 100.0
    static let beaconB2Distance: Double = 16.0
    static let beaconB3Distance: Double = 8.0
    static let stopPrecision: Double = 0.30

    // Traction chain envelope (image série; see the app's VALTraction).
    static let tareMass: Double = 31_000
    static let passengerMass: Double = 70
    static let motorCount: Int = 4
    static let gearRatio: Double = 8.6
    static let wheelRadius: Double = 0.445
    static let imageSerieFullField: Double = 0.059
    static let imageSerieWeakField: Double = 0.034
    static let motorTorquePerAmp2: Double = 0.0326
    static let armatureResistance: Double = 0.16
    static let armatureCurrentMax: Double = 620
    static let lineVoltage: Double = 750
    static let davisA: Double = 0.011 * 9.81
    static let davisB: Double = 30.0
    static let davisC: Double = 2.6

    // Console A22 vigilance.
    static let kacopWarningDelay: Double = 14.0
    static let kacopTripDelay: Double = 20.0

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

/// Mirror of the app's `VALSpeedProgram` (raw values ride the wire in
/// `Train.speedProgram`).
enum VALSpeedProgram: String, Codable {
    case normal
    case perturbed
    case stationArrival
    case stationDeparture
    case departureHeld
    case pushRecovery
    case absent
}

/// Mirror of the app's `VALTripCause` (raw values ride the wire in
/// `Train.ebCause`).
enum VALTripCause: String, Codable {
    case none
    case overspeed
    case sfLoss
    case blockPenetration
    case rollback
    case ppOverrun
    case doorUnlocked
    case vigilance
    case doorFault
    case brakeFault
    case lineEmergency
    case controllerAlarm
    case operatorFU
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

    // VAL fixed-block telemetry + console A22 (mirror of the app's).
    var speedProgram: String = ""
    var ebCause: String = "none"
    var pupitreKG: Bool = false
    var pupitreReverser: Int = 0
    var pupitreLever: Double = 0
    var kacopSecondsSinceAck: Double = 0
    var kacopWarning: Bool = false

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

    // Traction-chain bench telemetry (mirror of the app's fields).
    var armatureCurrent: Double = 0
    var lineCurrent: Double = 0
    var excitationCurrent: Double = 0
    var modulationRatio: Double = 0

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
        case speedProgram, ebCause
        case pupitreKG, pupitreReverser, pupitreLever
        case kacopSecondsSinceAck, kacopWarning
        case mainVoltage, batteryVoltage, tractionCurrent, tractionTorque
        case compressorPressure, isCompressorRunning, interiorTemperature
        case armatureCurrent, lineCurrent, excitationCurrent, modulationRatio
    }

    init(id: UUID, label: String, ownerPeerId: String, position: Double) {
        self.id = id
        self.label = label
        self.ownerPeerId = ownerPeerId
        self.position = position
    }

    /// Tolerant decoding, like the app's: fields added after first
    /// release fall back to their defaults so an older peer build stays
    /// wire-compatible in both directions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        ownerPeerId = try c.decodeIfPresent(String.self, forKey: .ownerPeerId) ?? ""
        position = try c.decode(Double.self, forKey: .position)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        acceleration = try c.decodeIfPresent(Double.self, forKey: .acceleration) ?? 0
        targetSpeed = try c.decodeIfPresent(Double.self, forKey: .targetSpeed) ?? Sim.lineSpeed
        movementAuthority = try c.decodeIfPresent(Double.self, forKey: .movementAuthority) ?? 0
        travelDirection = try c.decodeIfPresent(TravelDirection.self, forKey: .travelDirection) ?? .forward
        status = try c.decodeIfPresent(TrainStatus.self, forKey: .status) ?? .stopped
        mode = try c.decodeIfPresent(TrainMode.self, forKey: .mode) ?? .auto
        manualSpeedRequest = try c.decodeIfPresent(Double.self, forKey: .manualSpeedRequest) ?? 0
        doorsOpen = try c.decodeIfPresent(Bool.self, forKey: .doorsOpen) ?? false
        isDwelling = try c.decodeIfPresent(Bool.self, forKey: .isDwelling) ?? false
        dwellRemaining = try c.decodeIfPresent(TimeInterval.self, forKey: .dwellRemaining) ?? 0
        isDepartureHold = try c.decodeIfPresent(Bool.self, forKey: .isDepartureHold) ?? false
        lastServicedStationId = try c.decodeIfPresent(Int.self, forKey: .lastServicedStationId)
        nextStationName = try c.decodeIfPresent(String.self, forKey: .nextStationName) ?? "..."
        passengerCount = try c.decodeIfPresent(Int.self, forKey: .passengerCount) ?? 0
        lastPaxChange = try c.decodeIfPresent(Int.self, forKey: .lastPaxChange) ?? 0
        paxRemaining = try c.decodeIfPresent(Int.self, forKey: .paxRemaining) ?? 0
        paxExchangeInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .paxExchangeInterval) ?? 0
        paxExchangeTimer = try c.decodeIfPresent(TimeInterval.self, forKey: .paxExchangeTimer) ?? 0
        isDoorFault = try c.decodeIfPresent(Bool.self, forKey: .isDoorFault) ?? false
        isEngineFault = try c.decodeIfPresent(Bool.self, forKey: .isEngineFault) ?? false
        isBrakeFault = try c.decodeIfPresent(Bool.self, forKey: .isBrakeFault) ?? false
        isSignalFault = try c.decodeIfPresent(Bool.self, forKey: .isSignalFault) ?? false
        isPatinage = try c.decodeIfPresent(Bool.self, forKey: .isPatinage) ?? false
        isEnrayage = try c.decodeIfPresent(Bool.self, forKey: .isEnrayage) ?? false
        isEmergencyBrakeApplied = try c.decodeIfPresent(Bool.self, forKey: .isEmergencyBrakeApplied) ?? false
        consigneVitesse = try c.decodeIfPresent(Double.self, forKey: .consigneVitesse) ?? 0
        speedError = try c.decodeIfPresent(Double.self, forKey: .speedError) ?? 0
        distanceToMA = try c.decodeIfPresent(Double.self, forKey: .distanceToMA) ?? 0
        speedProgram = try c.decodeIfPresent(String.self, forKey: .speedProgram) ?? ""
        ebCause = try c.decodeIfPresent(String.self, forKey: .ebCause) ?? "none"
        pupitreKG = try c.decodeIfPresent(Bool.self, forKey: .pupitreKG) ?? false
        pupitreReverser = try c.decodeIfPresent(Int.self, forKey: .pupitreReverser) ?? 0
        pupitreLever = try c.decodeIfPresent(Double.self, forKey: .pupitreLever) ?? 0
        kacopSecondsSinceAck = try c.decodeIfPresent(Double.self, forKey: .kacopSecondsSinceAck) ?? 0
        kacopWarning = try c.decodeIfPresent(Bool.self, forKey: .kacopWarning) ?? false
        tires = try c.decodeIfPresent([Tire].self, forKey: .tires)
            ?? (1...Sim.tireCount).map { Tire(id: $0) }
        mainVoltage = try c.decodeIfPresent(Double.self, forKey: .mainVoltage) ?? 750.0
        batteryVoltage = try c.decodeIfPresent(Double.self, forKey: .batteryVoltage) ?? 76.5
        tractionCurrent = try c.decodeIfPresent(Double.self, forKey: .tractionCurrent) ?? 0
        tractionTorque = try c.decodeIfPresent(Double.self, forKey: .tractionTorque) ?? 0
        compressorPressure = try c.decodeIfPresent(Double.self, forKey: .compressorPressure) ?? 8.5
        isCompressorRunning = try c.decodeIfPresent(Bool.self, forKey: .isCompressorRunning) ?? false
        interiorTemperature = try c.decodeIfPresent(Double.self, forKey: .interiorTemperature) ?? 22.0
        armatureCurrent = try c.decodeIfPresent(Double.self, forKey: .armatureCurrent) ?? 0
        lineCurrent = try c.decodeIfPresent(Double.self, forKey: .lineCurrent) ?? 0
        excitationCurrent = try c.decodeIfPresent(Double.self, forKey: .excitationCurrent) ?? 0
        modulationRatio = try c.decodeIfPresent(Double.self, forKey: .modulationRatio) ?? 0
    }
}
