import Foundation

// PRATIC DOMAIN MODEL.
//
// PRATIC (Projet de Reseau Automatique de Trains Inter-Connectes) is a
// model-scale, CBTC-compliant train autopilot: wayside sensing, onboard
// odometry, a comms link, and a real traction inverter. This app is its
// PCC / dispatcher front end. The domain differs from the VAL simulation
// in the ways that matter to CBTC:
//
//   * MOVING BLOCK -- no fixed sections; each train reports position and
//     speed continuously and gets a movement authority (limit + speed)
//     computed around the live picture.
//   * POSITION CONFIDENCE IS A STATE -- localized / uncertain /
//     delocalized, driven by balise fixes, odometry drift and link
//     health. Delocalization is the defining failure mode; recovery is
//     an explicit re-reference against a balise.
//   * LINK STATUS IS A STATE -- ok / degraded / lost from heartbeat age;
//     stale data is flagged, never silently frozen.
//
// Model-first: the UI and DCL verbs are reactive views over this state.
// Track coordinates reuse the app's loop (0..Sim.trackLength); segments
// are the cantons, so the existing synoptic and panels can display
// PRATIC trains through the MetroWorld mirror (see PraticBackend.swift).

enum PraticLinkStatus: String, Codable {
    case ok, degraded, lost

    var localizationKey: String {
        switch self {
        case .ok:       return "pratic.link.ok"
        case .degraded: return "pratic.link.degraded"
        case .lost:     return "pratic.link.lost"
        }
    }
}

enum PraticConfidence: String, Codable {
    case localized, uncertain, delocalized

    var localizationKey: String {
        switch self {
        case .localized:   return "pratic.conf.localized"
        case .uncertain:   return "pratic.conf.uncertain"
        case .delocalized: return "pratic.conf.delocalized"
        }
    }
}

/// One PRATIC trainset. `id` is shared with the train's MetroWorld
/// mirror, so the PCC panel's controls (FU, mode, manual speed) land on
/// the mirror and the backend reads them back as operator intents.
struct PraticTrain: Identifiable, Codable {
    let id: UUID
    var label: String
    /// Loop coordinate (m). Under lost comms this is the LAST-KNOWN
    /// position; `uncertainty` is the radius of the doubt around it.
    var position: Double
    var speed: Double = 0
    var direction: TravelDirection = .forward
    var targetSpeed: Double = Sim.lineSpeed
    var manualSpeedRequest: Double = 0
    var modeAuto: Bool = true
    var emergencyStopped: Bool = false

    // Movement authority: absolute limit-of-authority coordinate plus
    // the profile speed to it. `maIssuedAt` ages the display.
    var maLimit: Double
    var maProfileSpeed: Double = Sim.lineSpeed
    var maIssuedAt: Date = Date()
    /// Operator-issued MA (SET PRATIC /MA=...). The sim's wayside pass
    /// respects it as a further restriction; the hardware backend
    /// forwards it to the wayside.
    var manualMALimit: Double? = nil

    var linkStatus: PraticLinkStatus = .ok
    var confidence: PraticConfidence = .localized
    /// Position uncertainty radius (m); grows with odometry travel,
    /// collapses to 0 on a balise fix or an operator re-localization.
    var uncertainty: Double = 0
    var lastUpdate: Date = Date()
    /// Regulation output for the detail displays (consigne vitesse).
    var consigne: Double = 0

    /// Segment-relative coordinate (segment = canton).
    var segmentId: Int {
        min(Sim.cantonCount, Int(position / Sim.cantonLength) + 1)
    }
    var segmentOffset: Double {
        position - Double(segmentId - 1) * Sim.cantonLength
    }
}

/// Fixed reference point the trains re-localize against. One per canton
/// entry boundary (balise n at the start of canton n).
struct PraticBalise: Identifiable {
    let id: Int
    let position: Double
}

/// A wayside sensor station (train detector). The sim marks detections
/// as trains pass; the hardware backend forwards the real detections.
struct PraticWaysideStation: Identifiable {
    let id: Int
    let position: Double
    var lastDetection: Date? = nil
    var faulted: Bool = false
}

/// A turnout/switch. The demo loop has no physical branches yet, so
/// these model the depot/crossover stubs the PRATIC layout plans for --
/// state and interlock plumbing is real, topology impact is not.
struct PraticTurnout: Identifiable {
    let id: Int
    var reversed: Bool = false
    var locked: Bool = false
}

/// The live PRATIC network picture -- the store both backends publish
/// into and every PRATIC view/verb reads from.
@MainActor
final class PraticNetwork: ObservableObject {
    @Published var trains: [PraticTrain] = []
    @Published var stations: [PraticWaysideStation]
    @Published var turnouts: [PraticTurnout]
    let balises: [PraticBalise]

    init() {
        balises = (1...Sim.cantonCount).map {
            PraticBalise(id: $0, position: Double($0 - 1) * Sim.cantonLength)
        }
        stations = (1...Sim.cantonCount).map {
            PraticWaysideStation(id: $0, position: Double($0 - 1) * Sim.cantonLength)
        }
        turnouts = [PraticTurnout(id: 1), PraticTurnout(id: 2)]
    }

    func trainIndex(labelled label: String) -> Int? {
        trains.firstIndex { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    func balise(id: Int) -> PraticBalise? {
        balises.first { $0.id == id }
    }

    func nearestBalise(to position: Double) -> PraticBalise {
        balises.min {
            loopDistance($0.position, position) < loopDistance($1.position, position)
        } ?? balises[0]
    }

    func loopDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, Sim.trackLength - d)
    }
}
