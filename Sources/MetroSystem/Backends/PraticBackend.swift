import Foundation
import Combine

// BACKEND SELECTION.
//
// The front end (PCC panels, 3D synoptic, DCL, Modbus, peer wire) is a
// view over MetroWorld. Which engine PUTS state into that world is the
// backend, and there are three:
//
//   VAL         the original self-contained VAL simulation -- MetroWorld
//               ticks its own physics (unchanged behaviour, the default).
//   PRATIC_SIM  a simulation of the PRATIC moving-block CBTC network:
//               heartbeats, balise fixes, position confidence,
//               delocalization and recovery -- for developing and
//               demonstrating the front end without hardware.
//   PRATIC_HW   the real PRATIC network: state arrives as a normalized
//               telemetry stream over a pluggable transport
//               (Backends/PraticTransport.swift); commands go back the
//               same way. The trains are autonomous (GoA4) -- this
//               backend supervises, it does not drive.
//
// Both PRATIC backends publish the domain picture in a PraticNetwork and
// MIRROR each train into MetroWorld (same UUID), so every existing
// surface keeps working: the PCC panel's FU/mode/speed controls mutate
// the mirror and the backend reads them back as operator intents; the
// synoptic, dynamics scope, Modbus map and peer wire all see the trains.
// PRATIC-specific state (link, confidence, MA age, wayside, turnouts)
// surfaces through SHOW PRATIC / SET PRATIC and the SCADA annunciator.
//
// Switching backends REPLACES the locally-owned fleet (each backend
// seeds/loads its own trains); remote peers' trains are untouched.

enum BackendKind: String, CaseIterable {
    case val = "VAL"
    case praticSim = "PRATIC_SIM"
    case praticHardware = "PRATIC_HW"

    var summaryKey: String {
        switch self {
        case .val:            return "backend.val.summary"
        case .praticSim:      return "backend.sim.summary"
        case .praticHardware: return "backend.hw.summary"
        }
    }
}

/// Failure injections for exercising the front end (sim backend only --
/// the hardware backend reports what the real network does).
enum PraticInjection {
    case commsLoss(label: String)
    case commsRestore(label: String)
    case sensorFault(stationId: Int)
    case sensorRestore(stationId: Int)
}

/// The command surface of a PRATIC backend -- the Section 6 controls of
/// the brief. Label-addressed because that is what the operator types.
/// Every mutator returns false when the target does not resolve (or the
/// operation is not supported by this backend).
@MainActor
protocol PraticBackend: AnyObject {
    var network: PraticNetwork { get }
    /// Health of the path to the state source (.ready always, for the sim).
    var transportState: HardwareLinkState { get }

    func start()
    func stop()

    @discardableResult func issueMovementAuthority(label: String, limit: Double?) -> Bool
    @discardableResult func setTargetSpeed(label: String, speed: Double) -> Bool
    @discardableResult func relocalize(label: String, baliseId: Int?) -> Bool
    @discardableResult func throwTurnout(id: Int, reversed: Bool) -> Bool
    @discardableResult func inject(_ injection: PraticInjection) -> Bool

    // Transport plumbing (hardware backend; the sim returns false).
    @discardableResult func configureTransport(kind: String?, host: String?, port: UInt16?) -> Bool
    @discardableResult func connectTransport() -> Bool
    func disconnectTransport()
}

/// Owns the active backend. A main-actor singleton like HardwareBridge:
/// one backend per process, reachable from the DCL verbs and bootstrap.
@MainActor
final class BackendManager: ObservableObject {
    static let shared = BackendManager()

    @Published private(set) var kind: BackendKind = .val
    private(set) var pratic: (any PraticBackend)? = nil
    private weak var world: MetroWorld?

    private init() {}

    /// Called once from bootstrap(). The VAL backend is already running
    /// (world.start()); nothing else to do until the operator switches.
    func attach(world: MetroWorld) {
        self.world = world
    }

    /// Switch backends: stop the current engine, replace the locally-
    /// owned fleet, start the new engine. Returns false when no world is
    /// attached yet.
    @discardableResult
    func select(_ newKind: BackendKind) -> Bool {
        guard let world else { return false }
        guard newKind != kind else { return true }

        pratic?.stop()
        pratic = nil
        world.stop()
        for train in world.locallyOwned() {
            world.removeTrain(id: train.id)
        }

        switch newKind {
        case .val:
            world.seedTrains()
            world.start()
        case .praticSim:
            let engine = PraticSimBackend(world: world)
            pratic = engine
            engine.start()
        case .praticHardware:
            let engine = PraticHardwareBackend(world: world)
            pratic = engine
            engine.start()
        }
        kind = newKind
        return true
    }
}

// MARK: -- MetroWorld mirroring (shared by both PRATIC backends)

extension PraticNetwork {
    /// Read the operator's intents off a train's MetroWorld mirror (the
    /// PCC buttons, DCL verbs and Modbus writes all mutate the mirror).
    func syncIntents(into train: inout PraticTrain, world: MetroWorld) {
        guard let mirror = world.trains.first(where: { $0.id == train.id }) else { return }
        train.emergencyStopped = mirror.isEmergencyBrakeApplied || world.isEmergencyStopped
        train.modeAuto = mirror.mode == .auto
        train.manualSpeedRequest = mirror.manualSpeedRequest
    }

    /// Write a PRATIC train's state onto its MetroWorld mirror so every
    /// existing surface renders it. Direct writes, not `mutate` -- this
    /// runs every scan for every train, and `mutate`'s immediate peer
    /// push would flood the wire (the 10 Hz rebroadcast carries it), the
    /// same reasoning as the ZC pass's direct MA write. Operator-input
    /// fields (FU latch, mode, manual setpoint, doors) are deliberately
    /// NOT touched: they flow the other way, via syncIntents.
    func project(_ train: PraticTrain, into world: MetroWorld) {
        if let idx = world.trains.firstIndex(where: { $0.id == train.id }) {
            fill(&world.trains[idx], from: train)
        } else {
            var mirror = Train(id: train.id, label: train.label,
                               ownerPeerId: world.localPeerId,
                               position: train.position)
            mirror.passengerCount = 0
            fill(&mirror, from: train)
            world.upsert(mirror)
        }
    }

    private func fill(_ mirror: inout Train, from train: PraticTrain) {
        mirror.position = train.position
        mirror.speed = train.speed
        mirror.travelDirection = train.direction
        mirror.targetSpeed = train.targetSpeed
        mirror.movementAuthority = train.maLimit
        mirror.distanceToMA = distanceAhead(from: train, to: train.maLimit)
        mirror.consigneVitesse = train.consigne
        mirror.speedError = train.consigne - train.speed
        if train.emergencyStopped {
            mirror.status = .emergency
        } else {
            mirror.status = train.speed > 0.05 ? .moving : .stopped
        }
    }

    /// Direction-aware distance from the train to an absolute loop
    /// coordinate, wrapped to [0, trackLength).
    func distanceAhead(from train: PraticTrain, to target: Double) -> Double {
        var d = train.direction == .forward
            ? target - train.position
            : train.position - target
        if d < 0 { d += Sim.trackLength }
        return d
    }
}
