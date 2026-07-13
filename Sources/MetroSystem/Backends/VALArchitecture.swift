import Foundation

// THE REAL VAL ARCHITECTURE, IN MINIATURE.
//
// Domain types for the rebuilt VAL backend, modelled on the system
// described in the UMTA/DOT interim assessment of VAL
// (UMTA-MA-06-0069-81-3, §3.5 "Command and Control") and the VAL 206
// traction-chain thesis (Verhille, 2007). Rack and board names follow
// the Matra/Siemens nomenclature of the O'Hare ATS maintenance contract
// (STS, 2007): OBCU DRIVE/SAFETY racks, WCU, DOCU, console A22.
//
// VAL is a FIXED-BLOCK system. The line is divided into blocks; a
// block's occupancy forbids any other vehicle from entering it. Speed
// commands are not radioed as a moving authority -- they are physically
// encoded in the guideway transmission line as antenna crossovers whose
// spacing is proportional to the block's safe speed. Each interstation
// block carries two encoded programs on separate lines:
//
//   SF ("safe frequency")  the normal program: proceed at the block code.
//                          Phase-modulated f1 (normal) / f2 (perturbed
//                          selected) / f3 (push recovery) + f4/f5
//                          (direction). Loss of the SF carrier means
//                          emergency braking -- fail-safe by absence.
//   PP ("perturbed")       a decreasing-speed profile that brings the
//                          train to a service-brake stop a margin d
//                          before the next block boundary. Selected by
//                          the WCU when the downstream block is occupied.
//
// Station blocks carry no PP; instead two successive SF sections, SFa
// (arrival, into the platform) and SFb (departure), let the DOCU admit
// a train to the platform while withholding departure.

/// Which encoded speed program the on-board equipment is currently
/// receiving. Raw values are stable wire identifiers (they ride in
/// `.state` payloads via `Train.speedProgram`).
enum VALSpeedProgram: String, Codable {
    case normal            // SF, f1: downstream block free
    case perturbed         // SF, f2: stop before the occupied block ahead
    case stationArrival    // SFa: admitted to the platform
    case stationDeparture  // SFb: departure authorized by the DOCU
    case departureHeld     // in SFb but departure withheld (DOCU)
    case pushRecovery      // f3 + remote command: 0.8 m/s accostage
    case absent            // SF carrier withdrawn -> emergency braking

    /// Fixed CLI mnemonic for MONITOR / SHOW output (in-universe firmware
    /// output -- English, not localized).
    var mnemonic: String {
        switch self {
        case .normal:           return "SF-N"
        case .perturbed:        return "PP"
        case .stationArrival:   return "SFA"
        case .stationDeparture: return "SFB"
        case .departureHeld:    return "HOLD"
        case .pushRecovery:     return "ASMD"
        case .absent:           return "ABS"
        }
    }
}

/// Why the on-board safety rack latched the emergency brake. Raw values
/// are wire identifiers; display localizes via `ebcause.*` keys.
enum VALTripCause: String, Codable {
    case none
    case overspeed         // crossover interval under 0.27 s (SSV board)
    case sfLoss            // no safe-frequency carrier (CPFS-A)
    case blockPenetration  // entered an occupied block (manual, 10 m)
    case rollback          // aft-block penetration (5 m)
    case ppOverrun         // overpassed the perturbed stopping point (CPPP-A)
    case doorUnlocked      // door train-line broken while moving
    case vigilance         // KACOP dead-man timeout (manual driving)
    case doorFault         // défaut portes latched by the operator/injector
    case brakeFault        // défaut frein
    case lineEmergency     // arrêt d'urgence général / SF withdrawn line-wide
    case controllerAlarm   // PCC watchdog interlock
    case operatorFU        // FU commanded from the PCC / pupitre

    var mnemonic: String {
        switch self {
        case .none:             return "--"
        case .overspeed:        return "SURVITESSE"
        case .sfLoss:           return "SF"
        case .blockPenetration: return "CANTON"
        case .rollback:         return "ROLLBACK"
        case .ppOverrun:        return "PP-LIMIT"
        case .doorUnlocked:     return "PORTES"
        case .vigilance:        return "KACOP"
        case .doorFault:        return "DEF-PORTES"
        case .brakeFault:       return "DEF-FREIN"
        case .lineEmergency:    return "URGENCE"
        case .controllerAlarm:  return "PCC"
        case .operatorFU:       return "FU-CDE"
        }
    }

    /// Suspect line-replaceable unit(s) for the trip, in the STS parts
    /// list's rack/board nomenclature (Attachment A of the O'Hare
    /// maintenance contract). Board designators are identifiers --
    /// identical in both languages, like the SCADA point tags. Empty when
    /// the cause is an operator action, not a fault.
    var suspectLRU: String {
        switch self {
        case .none, .operatorFU:
            return ""
        case .overspeed:        return "SAFETY RACK: SSV / RLS V-A"
        case .sfLoss:           return "SAFETY RACK: CPFS-A · WCU: AFSC/PP"
        case .blockPenetration: return "WCU: INTUSA / DCIS"
        case .rollback:         return "SAFETY RACK: MASV"
        case .ppOverrun:        return "SAFETY RACK: CPPP-A"
        case .doorUnlocked:     return "DRIVE RACK: ILTE (train line)"
        case .vigilance:        return "CONSOLE A22: KACOP loop"
        case .doorFault:        return "DRIVE RACK: ILTE · DOOR CONTROL UNIT"
        case .brakeFault:       return "TRACTION SAFETY RACK: APEP / ESSCT"
        case .lineEmergency:    return "WCU: SF withdrawal (line-wide)"
        case .controllerAlarm:  return "PCC: CC watchdog / DTU"
        }
    }
}

/// Suspect LRUs for the latched fault flags and adhesion conditions --
/// the injectable failures that don't necessarily trip the FU. Same
/// nomenclature and language-neutrality as `VALTripCause.suspectLRU`.
enum VALFaultLRU {
    static func suspects(for train: Train) -> [(point: String, lru: String)] {
        var rows: [(String, String)] = []
        if train.isDoorFault   { rows.append(("PORTES",    "DRIVE RACK: ILTE · DOOR CONTROL UNIT")) }
        if train.isEngineFault { rows.append(("TRACTION",  "DRIVE RACK: REG-A · GTO PANEL 3A6/3A7")) }
        if train.isBrakeFault  { rows.append(("FREIN",     "TRACTION SAFETY RACK: APEP / ESSCT")) }
        if train.isSignalFault { rows.append(("CTC_RADIO", "TMTC RACK: MP 68 KE · ANTENNA REA")) }
        if train.isPatinage    { rows.append(("PATINAGE",  "DRIVE RACK: ASST-A · running gear")) }
        if train.isEnrayage    { rows.append(("ENRAYAGE",  "TRACTION SAFETY RACK: APEP · running gear")) }
        if train.worstTire != .ok { rows.append(("PNEU",   "RUNNING GEAR: tire set (PNEU_CAL)")) }
        if train.isEmergencyBrakeApplied,
           let cause = VALTripCause(rawValue: train.ebCause),
           !cause.suspectLRU.isEmpty {
            rows.append((cause.mnemonic, cause.suspectLRU))
        }
        return rows
    }
}

/// One fixed block of the guideway database, with its encoded speed
/// programs. Interstation blocks carry SF + PP; station blocks carry
/// SFa/SFb around the platform stop point and the three braking beacons
/// (B1 start of deceleration, B2 end, B3 precision-stop loop).
struct VALBlock {
    let id: Int                    // matches Canton.id (1-based)
    let start: Double              // metres along the loop
    let length: Double
    let normalCode: Double         // m/s encoded in the SF crossover spacing
    let stationId: Int?            // platform inside this block, if any
    let stopPoint: Double?         // platform stop marker (absolute m)

    var end: Double { start + length }
    var isStationBlock: Bool { stationId != nil }

    func contains(_ position: Double) -> Bool {
        position >= start && position < end
    }
}

/// The guideway database: blocks, codes, beacons. Built once from the
/// `Sim` layout constants so the 10-canton loop remains authoritative.
struct VALTrackDatabase {
    /// The guideway is fixed hardware -- one shared database per process.
    static let shared = VALTrackDatabase()

    let blocks: [VALBlock]

    init() {
        let stations = Sim.stationLayout.enumerated().map { (i, s) in
            (id: i + 1, position: s.position)
        }
        blocks = (0..<Sim.cantonCount).map { i in
            let start = Double(i) * Sim.cantonLength
            let end = start + Sim.cantonLength
            let station = stations.first { $0.position >= start && $0.position < end }
            return VALBlock(id: i + 1,
                            start: start,
                            length: Sim.cantonLength,
                            normalCode: station != nil ? Sim.stationBlockSpeed : Sim.lineSpeed,
                            stationId: station?.id,
                            stopPoint: station?.position)
        }
    }

    func block(at position: Double) -> VALBlock {
        var p = position.truncatingRemainder(dividingBy: Sim.trackLength)
        if p < 0 { p += Sim.trackLength }
        return blocks.first { $0.contains(p) } ?? blocks[0]
    }

    func block(id: Int) -> VALBlock {
        blocks[(id - 1 + blocks.count) % blocks.count]
    }

    /// The next block in a running direction.
    func nextBlock(after id: Int, direction: TravelDirection) -> VALBlock {
        let step = direction == .forward ? 1 : -1
        var next = (id - 1 + step) % blocks.count
        if next < 0 { next += blocks.count }
        return blocks[next]
    }

    /// Directed distance from `position` to `target` in `direction`,
    /// wrapped to [0, trackLength).
    static func distanceAhead(from position: Double, to target: Double,
                              direction: TravelDirection) -> Double {
        var d = direction == .forward ? target - position : position - target
        if d < 0 { d += Sim.trackLength }
        return d.truncatingRemainder(dividingBy: Sim.trackLength)
    }
}

/// The uplink telegram one rame receives from the wayside each scan --
/// the WCU's program selection plus the DOCU's station orders. This is
/// the ONLY channel from the fixed equipment to the on-board equipment,
/// mirroring the guideway transmission line.
struct VALTelegram {
    var program: VALSpeedProgram = .normal
    var blockCode: Double = 0            // m/s from the crossover spacing
    /// The next block's encoded code: the crossover spacing tapers ahead
    /// of a boundary so the AVO brakes onto the lower code before entry.
    var nextBlockCode: Double = 0
    /// Absolute stopping anchor for the decreasing-speed profiles: the
    /// perturbed stop point (PP) or the platform stop marker (SFa).
    var stopAnchor: Double? = nil
    /// Station whose platform the SFa profile is stopping at.
    var stationId: Int? = nil
    /// Proportional restriction from Central (1.0 = none, 0.9 selected).
    var restriction: Double = 1.0
    /// Direction bits f4/f5. A mismatch with the tachometer direction is
    /// an AVP trip.
    var direction: TravelDirection = .forward
    /// DOCU order to reverse at the terminus (SP turnback).
    var turnback: Bool = false
    /// Occupied-block boundary ahead (absolute m) -- the PP anchor
    /// reference and the authority telemetry.
    var occupiedBoundary: Double? = nil
    /// Set when the rame's own block is ALSO occupied by another train
    /// and the rame is within the entry zone: metres progressed past the
    /// block entry. The AVP's sequential-detection penetration trip.
    var penetrationDepth: Double? = nil
}

/// Console A22 -- the pupitre de conduite manuelle carried at each end
/// of the PA car (semantics per VALPupitreSim). Level booleans arrive as
/// commands; the OBCU detects KACOP rising edges itself.
struct VALPupitre: Codable, Hashable {
    /// KG (coupure générale): master power. No traction without it;
    /// service braking remains available.
    var kg: Bool = false
    /// Manipulateur d'inversion: +1 AV (avant), 0 neutral, -1 AR (arrière).
    var reverser: Int = 0
    /// Manipulateur traction/freinage: +1 full traction ... -1 full
    /// service brake. 0 coasts (resistance only).
    var lever: Double = 0
}

/// Per-rame OBCU internal state -- everything the DRIVE and SAFETY racks
/// remember between scans and that is NOT carried on the peer wire.
struct VALOnboardState {
    // DRIVE rack (AVO, boards REG-A / ASST-A): the jerk-limited motion
    // reference the analog loop chases.
    var consigne: Double = 0             // shaped speed command (m/s)
    var consigneAccel: Double = 0        // its current slope (m/s²)

    // SAFETY rack (AVP, boards SSV / CPFS-A / CPPP-A): trip latch. FU is
    // held off by continuously proven positive data; once tripped it
    // stays applied until the rame is at a stand and the cause cleared.
    var tripCause: VALTripCause = .none
    var sfLossTimer: Double = 0          // s without carrier before trip
    var blockEntryPenetration: Double = 0 // m progressed into an occupied block
    var rollbackDistance: Double = 0     // m of movement against the commanded direction

    // Station sequence (DOCU dialogue).
    var beaconPhase: BeaconPhase = .none
    enum BeaconPhase { case none, b1Decel, b2Creep, b3PrecisionStop }

    // Vigilance (KACOP) -- manual driving only.
    var kacopTimer: Double = 0
    var kacopPreviouslyPressed: Bool = false

    /// Automatic-restart hold-off after an AVP event trip: counts up
    /// while the rame stands with the trip cause cleared; the FU
    /// releases when it matures (Central "reinitiates the system").
    var tripHoldoff: Double = 0

    // Traction chain (HR car) state.
    var traction = VALTractionState()
}

/// Traction-chain state per rame (thesis Ch.1): one armature-current
/// image per car, per-bogie wheel speeds for the adhesion law, and the
/// anti-patinage authority ramp per car.
struct VALTractionState {
    /// Wheel rim speed per bogie (m/s at the tire). Index 0-1 = car A
    /// (PA) bogies, 2-3 = car B (HR) bogies. Diverges from train speed
    /// when a bogie slips (patinage) or locks (enrayage).
    var wheelSpeed: [Double] = [0, 0, 0, 0]
    /// Anti-patinage effort authority per car (0...1): drops to 0 when
    /// the motor-speed spread trips, ramps back over patinageRampTime.
    var carAuthority: [Double] = [1, 1]
    /// Whether the anti-skid logic currently holds a car's effort down.
    var antiSkidActive: [Bool] = [false, false]
    /// Armature current (A) actually flowing, per car.
    var armatureCurrent: [Double] = [0, 0]
    /// Field weakening engaged per car (image série phase 3).
    var fieldWeakened: [Bool] = [false, false]
    /// Detected slip/slide this scan (drives the PATINAGE / ENRAYAGE
    /// process alarms when not operator-injected).
    var slipping: Bool = false
    var sliding: Bool = false

    /// Bench telemetry (thesis notation): the actual electrical picture
    /// backed out of the force demand each scan.
    var benchArmature: Double = 0   // ii, A -- per-car armature loop
    var benchLine: Double = 0       // il, A signed (negative = regen return)
    var benchField: Double = 0      // iex, A per motor
    var benchDuty: Double = 0       // mhi, 0...1
}
