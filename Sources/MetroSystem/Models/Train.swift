import Foundation

/// One fixed block of the circular line.
struct Canton: Identifiable, Hashable {
    let id: Int                 // 1-based canton number
    let name: String            // "Canton 3"
    let startPosition: Double   // metres along the loop
    let length: Double

    func contains(_ position: Double) -> Bool {
        position >= startPosition && position < startPosition + length
    }
}

/// A passenger station on the loop.
struct Station: Identifiable, Hashable {
    let id: Int                 // stable 1-based index
    let name: String
    let position: Double        // stop-marker position in metres
}

/// Temporary shuttle service between two stations (service provisoire):
/// trains ping-pong between the two termini with a fixed headway, and the
/// rest of the line is barred by virtual ZC barriers. A local exploitation
/// overlay -- it is not carried on the peer wire.
struct ServiceProvisoire: Equatable {
    var startStationId: Int
    var endStationId: Int
    var intervalle: TimeInterval = 60.0     // headway in seconds
}

enum TravelDirection: Double, Codable {
    case forward = 1.0
    case reverse = -1.0
}

enum TrainMode: String, Codable, CaseIterable {
    case auto       // conduite automatique intégrale (CBTC)
    case manual     // conduite manuelle limitée
}

enum TrainStatus: String, Codable {
    case stopped
    case moving
    case emergency
    case docked     // à quai
}

/// One VAL trainset (rame). A pure value type: all mutation goes through
/// `MetroWorld.mutate(_:_:)` inside the 60 Hz scan, mirroring how a PLC
/// image table is written once per cycle.
///
/// Codable: this struct IS the peer wire's `.state` payload (see
/// Networking/Protocol.swift and ClusterDaemon/…/Model.swift, which mirrors
/// it field-for-field). Fields added after first release decode tolerantly
/// via `decodeIfPresent` so an older daemon build stays wire-compatible.
struct Train: Identifiable, Hashable, Codable {
    let id: UUID
    var label: String                  // "101"
    /// Peer that simulates this rame. Only the owner's OBCU advances it;
    /// everyone else renders the broadcast state.
    var ownerPeerId: String = ""
    var position: Double               // metres along the loop
    var speed: Double = 0              // m/s (always >= 0; direction is separate)
    var acceleration: Double = 0       // m/s² applied last tick
    var targetSpeed: Double = Sim.lineSpeed
    var movementAuthority: Double = 0  // absolute limit-of-movement-authority (m)
    var travelDirection: TravelDirection = .forward
    var status: TrainStatus = .stopped
    var mode: TrainMode = .auto
    var manualSpeedRequest: Double = 0

    // Doors / station dwell.
    var doorsOpen: Bool = false
    var isDwelling: Bool = false
    var dwellRemaining: TimeInterval = 0
    var isDepartureHold: Bool = false          // held by SP interval pacing
    var lastServicedStationId: Int? = nil
    var nextStationName: String = "..."

    // Passengers.
    var passengerCount: Int = 0
    var lastPaxChange: Int = 0
    var paxRemaining: Int = 0
    var paxExchangeInterval: TimeInterval = 0
    var paxExchangeTimer: TimeInterval = 0
    var paxBoarding: Int = 0           // montée: boarded at the current stop
    var paxAlighting: Int = 0          // descente: alighted at the current stop

    // Latched fault injection (PCC failure panel / DCL SET RAME).
    var isDoorFault: Bool = false      // défaut portes -- forces FU
    var isEngineFault: Bool = false    // défaut traction -- no motoring
    var isBrakeFault: Bool = false     // défaut frein -- forces FU
    var isSignalFault: Bool = false    // défaut signal -- MA collapses to zero
    var isPatinage: Bool = false       // wheel slip under traction
    var isEnrayage: Bool = false       // wheel slide under braking
    var isEmergencyBrakeApplied: Bool = false   // FU commanded by operator

    // Asservissement telemetry (speed-regulation loop readbacks).
    var consigneVitesse: Double = 0    // commanded speed from the braking curve
    var speedError: Double = 0
    var distanceToMA: Double = 0

    // VAL backend telemetry (empty / defaults under other backends --
    // the views gate their VAL-specific rows on `speedProgram`).
    /// Raw value of `VALSpeedProgram`: which track-encoded speed program
    /// the OBCU is receiving ("" when the rame isn't driven by the VAL
    /// fixed-block backend).
    var speedProgram: String = ""
    /// Raw value of `VALTripCause`: why the FU latched ("none" when
    /// released).
    var ebCause: String = "none"

    // Console A22 -- pupitre de conduite manuelle (VAL backend, manual
    // mode). Wire-carried so a remote rame's cab state renders everywhere;
    // driven through the pupitre TrainCommands.
    var pupitreKG: Bool = false        // coupure générale (master power)
    var pupitreReverser: Int = 0       // +1 AV / 0 neutral / -1 AR
    var pupitreLever: Double = 0       // +1 traction ... -1 service brake
    var kacopSecondsSinceAck: Double = 0
    var kacopWarning: Bool = false

    // Tires (VAL pneumatic running gear).
    struct Tire: Identifiable, Hashable, Codable {
        let id: Int
        var pressure: Double = Sim.tireNominalBar
        var status: TireStatus = .ok

        /// Raw values are stable wire identifiers (they travel in `.state`
        /// payloads); the display name localizes via `Strings`
        /// ("train.tire.<status>").
        enum TireStatus: String, CaseIterable, Codable {
            case ok
            case lowPressure
            case puncture
            case burst
        }
    }
    var tires: [Tire] = (1...Sim.tireCount).map { Tire(id: $0) }

    // Auxiliary systems (synoptic data).
    var mainVoltage: Double = 750.0            // third-rail 750 V DC bus
    var batteryVoltage: Double = 76.5
    var cvsOutputVoltage: Double = 112.0       // static converter (CVS) LV output
    var tractionCurrent: Double = 0
    var tractionTorque: Double = 0     // percent, -100..100
    var lightingCurrent: Double = 15.0         // ECLAIRAGE circuit draw (A)
    var compressorPressure: Double = 8.5
    var isCompressorRunning: Bool = false
    var interiorTemperature: Double = 22.0
    var targetTemperature: Double = 22.0       // HVAC setpoint
    var brakeBoxTemperature: Double = 35.0     // TEMP COFFRE-FREIN (°C)

    // Auxiliary control states -- owner-driven telecommands shown on the
    // train-detail screen. Toggled through `MetroWorld.mutate` and
    // carried on the peer wire so a rame's synoptic reads the same everywhere.
    var isLoadSheddingActive: Bool = false     // DELESTAGE BT
    var areLightsOn: Bool = true               // ECLAIRAGE
    var areVentilated: Bool = true             // VENTILATION
    var isHeating: Bool = true                 // CHAUFFAGE
    var isSuspensionActive: Bool = true        // SUSPENSION (air-spring levelling)
    var emergencyBrakeCounter: Int = 0         // COMPTEUR FU (application count)
    var isMultimediaResetting: Bool = false    // RAZ MULTIMEDIA
    var isSoundSystemActive: Bool = true       // TEST SONORISATION
    var isVideoSystemInitialized: Bool = true  // INIT SYSTÈME VIDÉO
    var isArchiving: Bool = false              // ENR ARCHIVAGE DAM

    enum CodingKeys: String, CodingKey {
        case id, label, ownerPeerId, position, speed, acceleration
        case targetSpeed, movementAuthority, travelDirection, status, mode
        case manualSpeedRequest, doorsOpen, isDwelling, dwellRemaining
        case isDepartureHold, lastServicedStationId, nextStationName
        case passengerCount, lastPaxChange, paxRemaining
        case paxExchangeInterval, paxExchangeTimer, paxBoarding, paxAlighting
        case isDoorFault, isEngineFault, isBrakeFault, isSignalFault
        case isPatinage, isEnrayage, isEmergencyBrakeApplied
        case consigneVitesse, speedError, distanceToMA, tires
        case speedProgram, ebCause
        case pupitreKG, pupitreReverser, pupitreLever
        case kacopSecondsSinceAck, kacopWarning
        case mainVoltage, batteryVoltage, cvsOutputVoltage
        case tractionCurrent, tractionTorque, lightingCurrent
        case compressorPressure, isCompressorRunning
        case interiorTemperature, targetTemperature, brakeBoxTemperature
        case isLoadSheddingActive, areLightsOn, areVentilated, isHeating
        case isSuspensionActive, emergencyBrakeCounter, isMultimediaResetting
        case isSoundSystemActive, isVideoSystemInitialized, isArchiving
    }

    init(id: UUID, label: String, ownerPeerId: String, position: Double) {
        self.id = id
        self.label = label
        self.ownerPeerId = ownerPeerId
        self.position = position
    }

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
        paxBoarding = try c.decodeIfPresent(Int.self, forKey: .paxBoarding) ?? 0
        paxAlighting = try c.decodeIfPresent(Int.self, forKey: .paxAlighting) ?? 0
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
        cvsOutputVoltage = try c.decodeIfPresent(Double.self, forKey: .cvsOutputVoltage) ?? 112.0
        tractionCurrent = try c.decodeIfPresent(Double.self, forKey: .tractionCurrent) ?? 0
        tractionTorque = try c.decodeIfPresent(Double.self, forKey: .tractionTorque) ?? 0
        lightingCurrent = try c.decodeIfPresent(Double.self, forKey: .lightingCurrent) ?? 15.0
        compressorPressure = try c.decodeIfPresent(Double.self, forKey: .compressorPressure) ?? 8.5
        isCompressorRunning = try c.decodeIfPresent(Bool.self, forKey: .isCompressorRunning) ?? false
        interiorTemperature = try c.decodeIfPresent(Double.self, forKey: .interiorTemperature) ?? 22.0
        targetTemperature = try c.decodeIfPresent(Double.self, forKey: .targetTemperature) ?? 22.0
        brakeBoxTemperature = try c.decodeIfPresent(Double.self, forKey: .brakeBoxTemperature) ?? 35.0
        isLoadSheddingActive = try c.decodeIfPresent(Bool.self, forKey: .isLoadSheddingActive) ?? false
        areLightsOn = try c.decodeIfPresent(Bool.self, forKey: .areLightsOn) ?? true
        areVentilated = try c.decodeIfPresent(Bool.self, forKey: .areVentilated) ?? true
        isHeating = try c.decodeIfPresent(Bool.self, forKey: .isHeating) ?? true
        isSuspensionActive = try c.decodeIfPresent(Bool.self, forKey: .isSuspensionActive) ?? true
        emergencyBrakeCounter = try c.decodeIfPresent(Int.self, forKey: .emergencyBrakeCounter) ?? 0
        isMultimediaResetting = try c.decodeIfPresent(Bool.self, forKey: .isMultimediaResetting) ?? false
        isSoundSystemActive = try c.decodeIfPresent(Bool.self, forKey: .isSoundSystemActive) ?? true
        isVideoSystemInitialized = try c.decodeIfPresent(Bool.self, forKey: .isVideoSystemInitialized) ?? true
        isArchiving = try c.decodeIfPresent(Bool.self, forKey: .isArchiving) ?? false
    }

    var displayName: String { "Rame \(label)" }

    /// Signed speed (m/s) for scopes: positive in the forward running sense.
    var signedSpeed: Double { speed * travelDirection.rawValue }

    /// DELESTAGE BT: shedding the low-voltage load dims the lighting circuit
    /// and drops non-vital ventilation (the coupling the detail screen
    /// shows when load shedding is engaged); releasing it restores
    /// nominal lighting and ventilation.
    mutating func setLoadShedding(_ on: Bool) {
        isLoadSheddingActive = on
        if on {
            lightingCurrent = 5.0
            areVentilated = false
        } else {
            lightingCurrent = areLightsOn ? 15.0 : 0.0
            areVentilated = true
        }
    }

    mutating func cycleTireStatus(at index: Int) {
        guard tires.indices.contains(index) else { return }
        switch tires[index].status {
        case .ok:          tires[index].status = .lowPressure; tires[index].pressure = 6.5
        case .lowPressure: tires[index].status = .puncture;    tires[index].pressure = 4.0
        case .puncture:    tires[index].status = .burst;       tires[index].pressure = 0.0
        case .burst:       tires[index].status = .ok;          tires[index].pressure = Sim.tireNominalBar
        }
    }

    // MARK: -- Safety predicates
    //
    // Pure functions of trainset telemetry, shared by the SCADA alarm
    // samplers and the Modbus safety-chain discrete inputs so a chaîne-de-
    // sécurité contact and its alarm can never disagree. Because they read
    // only fields carried on the peer wire, they hold for remote
    // (ClusterDaemon) rames exactly as for local ones.

    /// Overspeed relative to the asservissement's commanded speed with a
    /// vital margin (mirrors an ATP ceiling-speed trip). Quiet while the
    /// emergency brake already has the rame -- the FU alarm and `ebCause`
    /// carry that state; sampling overspeed against a collapsed consigne
    /// would double-alarm every trip.
    var isOverspeed: Bool {
        speed > max(consigneVitesse, 0) + 2.0 && speed > 1.0 && !isEmergencyBrakeApplied
    }

    /// Door interlock proven: doors closed and locked (motion permitted).
    var doorInterlockLocked: Bool { !doorsOpen }

    /// MA encroachment: inside the vital stop envelope while still moving.
    var isMAEncroached: Bool {
        distanceToMA < 2.0 && speed > 0.5
    }

    /// Worst tire state on the rake (drives the PNEU alarm severity and the
    /// Modbus adhesion contact).
    var worstTire: Tire.TireStatus {
        var worst: Tire.TireStatus = .ok
        for t in tires {
            switch (worst, t.status) {
            case (_, .burst): worst = .burst
            case (.ok, _), (.lowPressure, .puncture): worst = t.status
            default: break
            }
        }
        return worst
    }
}

/// One rame's chaîne de sécurité (series safety loop) as a PLC reads it:
/// each contact is `true` when closed / healthy. Derived purely from train
/// telemetry so it is identical for local and remote (ClusterDaemon) rames.
/// Exposed on the Modbus discrete-input block.
struct SafetyChain {
    let doorInterlock: Bool
    let overspeedOK: Bool
    let maMarginOK: Bool
    let brakeOK: Bool
    let adhesionOK: Bool
    /// The whole series loop: every contact closed AND the line not under a
    /// general emergency stop.
    let intact: Bool
}
