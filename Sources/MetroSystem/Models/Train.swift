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
/// rest of the line is barred by virtual ZC barriers.
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
struct Train: Identifiable, Hashable {
    let id: UUID
    var label: String                  // "101"
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

    // Tires (VAL pneumatic running gear).
    struct Tire: Identifiable, Hashable {
        let id: Int
        var pressure: Double = Sim.tireNominalBar
        var status: TireStatus = .ok

        enum TireStatus: String, CaseIterable {
            case ok = "OK"
            case lowPressure = "PRESSION BASSE"
            case puncture = "CREVAISON"
            case burst = "ECLATEMENT"
        }
    }
    var tires: [Tire] = (1...Sim.tireCount).map { Tire(id: $0) }

    // Auxiliary systems (synoptic data).
    var mainVoltage: Double = 750.0
    var batteryVoltage: Double = 76.5
    var tractionCurrent: Double = 0
    var tractionTorque: Double = 0     // percent, -100..100
    var compressorPressure: Double = 8.5
    var isCompressorRunning: Bool = false
    var interiorTemperature: Double = 22.0

    var displayName: String { "Rame \(label)" }

    /// Signed speed (m/s) for scopes: positive in the forward running sense.
    var signedSpeed: Double { speed * travelDirection.rawValue }

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
    // samplers so a chaîne-de-sécurité condition and its alarm can never
    // disagree.

    /// Overspeed relative to the asservissement's commanded speed with a
    /// vital margin (mirrors an ATP ceiling-speed trip).
    var isOverspeed: Bool {
        speed > max(consigneVitesse, 0) + 2.0 && speed > 1.0
    }

    /// Door interlock proven: doors closed and locked (motion permitted).
    var doorInterlockLocked: Bool { !doorsOpen }

    /// MA encroachment: inside the vital stop envelope while still moving.
    var isMAEncroached: Bool {
        distanceToMA < 2.0 && speed > 0.5
    }

    /// Worst tire state on the rake (drives the PNEU alarm severity).
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
