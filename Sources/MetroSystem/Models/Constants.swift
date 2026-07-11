import Foundation

/// All tunable simulation constants for the VAL metro line.
enum Sim {
    // Track geometry -- a circular line of `cantonCount` fixed blocks.
    static let cantonCount: Int = 10
    static let cantonLength: Double = 100.0
    static var trackLength: Double { Double(cantonCount) * cantonLength }

    // Traction / braking profile (VAL 208-style rubber-tyred trainset).
    static let lineSpeed: Double = 15.0          // m/s commanded by the PCC (~54 km/h)
    static let maxAcceleration: Double = 1.0     // m/s²
    static let nominalBraking: Double = 0.8      // m/s² service brake (asservissement curve)
    static let emergencyBraking: Double = 1.2    // m/s² FU (freinage d'urgence)

    // Zone-controller (ZC) movement-authority parameters.
    static let safetyMargin: Double = 50.0       // m kept behind the leading train
    static let maDistanceMargin: Double = 1.0    // m target offset in the braking curve

    // Station / passenger model.
    static let stationApproachWindow: Double = 150.0   // m lookahead for a stop point
    static let stationStopTolerance: Double = 1.5      // m from the stop marker
    static let dwellMin: Double = 5.0                  // s doors-open dwell
    static let dwellMax: Double = 10.0
    static let paxCapacity: Int = 120                  // nominal crush load per trainset
    static let paxBoardMax: Int = 20                   // max boarding per stop
    static let paxAlightMax: Int = 10                  // max alighting per stop

    // Tires (VAL runs on 8 pneumatic tires per trainset).
    static let tireCount: Int = 8
    static let tireNominalBar: Double = 9.0

    // Manual (conduite manuelle) speed ceiling.
    static let manualSpeedMax: Double = 20.0     // m/s

    // Fleet.
    static let seedTrainCount: Int = 3
    static let maxTrainCount: Int = 6
    static let firstTrainNumber: Int = 101

    // Scan loop.
    static let tickHz: Double = 60.0
    static var tickInterval: Double { 1.0 / tickHz }

    // PRATIC backends (Backends/): moving-block CBTC over the same loop.
    static let praticScanHz: Double = 30.0            // sim / watchdog scan rate
    static let praticSeedTrainCount: Int = 3
    static let praticFirstTrainNumber: Int = 201      // labels distinct from VAL's 101+
    static let praticSafetyMargin: Double = 30.0      // m moving-block envelope margin
    static let praticLinkDegraded: Double = 1.0       // s of heartbeat silence -> DEGRADED
    static let praticLinkLost: Double = 3.0           // s -> LOST
    static let praticDelocalized: Double = 6.0        // s -> DELOCALIZED
    static let praticUncertaintyGrowth: Double = 0.05 // m of uncertainty per m travelled
    static let praticDelocThreshold: Double = 40.0    // m of uncertainty -> DELOCALIZED
    static let praticBaliseTolerance: Double = 1.5    // m window for a balise fix
    static let praticDefaultPort: UInt16 = 4800       // JSONL transport default

    // Model-track hardware bridge (Hardware/HardwareBridge.swift).
    static let hardwareOutputHz: Double = 10.0          // output-scan rate
    static let hardwareRefreshInterval: Double = 1.0    // full-frame resend period (s)
    static let hardwareSpeedSteps: Int = 126            // DCC-style throttle quantisation
    static let hardwareSensorLogDepth: Int = 8          // SHOW HARDWARE event ring

    // Peer networking (app <-> app, app <-> ClusterDaemon nodes).
    static let bonjourServiceType: String = "_metrosys._tcp"
    /// Periodic rebroadcast cadence for locally-owned rame state. Operator
    /// actions additionally push a `.state` immediately via onLocalChange.
    static let peerStateBroadcastHz: Double = 10.0

    /// The six stations of the simulated line (Lille VAL Ligne 1 flavour),
    /// as (name, position-in-metres) pairs along the loop.
    static let stationLayout: [(name: String, position: Double)] = [
        ("CHU - Eurasanté",    50.0),
        ("Gambetta",          200.0),
        ("Gare Lille Flandres", 350.0),
        ("Fives",             550.0),
        ("Pont de Bois",      700.0),
        ("4 Cantons",         850.0),
    ]
}
