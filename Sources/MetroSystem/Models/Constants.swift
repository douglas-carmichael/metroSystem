import Foundation

/// All tunable simulation constants for the VAL metro line.
enum Sim {
    // Track geometry -- a circular line of `cantonCount` fixed blocks.
    static let cantonCount: Int = 10
    static let cantonLength: Double = 100.0
    static var trackLength: Double { Double(cantonCount) * cantonLength }

    // Traction / braking profile (VAL 206 trainset). Values from the
    // UMTA/DOT interim assessment (UMTA-MA-06-0069-81-3, Table 3-1 and
    // §3.5.3.1): average acceleration / service deceleration 1.3 m/s²
    // (0.137 g), jerk 0.65 m/s³ (0.068 g/s), emergency braking 1.8-2.4
    // m/s² (2.13-2.18 m/s² in the §4.2 demonstration tests).
    static let lineSpeed: Double = 15.0          // m/s commanded by the PCC (~54 km/h)
    static let maxAcceleration: Double = 1.3     // m/s² AVO comfort ceiling
    static let nominalBraking: Double = 1.3      // m/s² service brake
    static let emergencyBraking: Double = 2.15   // m/s² FU (spring-applied disks, as tested)
    static let jerkMax: Double = 0.65            // m/s³ AVO jerk limit

    // Moving-block CBTC backend (Backends/CBTCSimBackend.swift): the
    // continuous safe-separation envelope behind the leading train.
    static let safetyMargin: Double = 50.0       // m kept behind the leader

    // Fixed-block AVP parameters (DOT assessment §3.5.2).
    /// Service-brake stop margin before an occupied block's boundary --
    /// the "distance margin (d)" of the perturbed stopping program.
    static let perturbedStopMargin: Double = 8.0
    /// AVP overspeed trip ratio over the program speed: the AVO regulates
    /// to 0.30 s per transmission-line crossover, the AVP trips FU below
    /// 0.27 s -- a 10 percent vital margin.
    static let avpOverspeedRatio: Double = 0.30 / 0.27
    /// Manual-mode penetration into an occupied block that removes the SF
    /// and trips FU (10 m in the §4.5.6 demonstration test).
    static let manualPenetrationTrip: Double = 10.0
    /// Rollback penetration into the aft block that trips FU (§4.5.8).
    static let rollbackTrip: Double = 5.0
    /// Speed program encoded in station blocks (arrival approach code).
    static let stationBlockSpeed: Double = 8.0   // m/s (~29 km/h)
    /// ASMD creep / push-recovery ceiling: 0.8 m/s (2 mph) coupling speed.
    static let asmdSpeed: Double = 0.8
    /// Proportional speed-restriction factor selectable from the PCC
    /// (push recovery / overload), DOT §3.5.2.7.
    static let proportionalRestriction: Double = 0.9
    static let maDistanceMargin: Double = 1.0    // m target offset in the stopping curves

    // Station stopping beacons (DOT §3.5.3.1): B1 initiates deceleration,
    // B2 ends it, B3 arms the closed-loop precision stop (+/-30 cm).
    static let beaconB1Distance: Double = 100.0  // m before the stop point
    static let beaconB2Distance: Double = 16.0
    static let beaconB3Distance: Double = 8.0
    static let stopPrecision: Double = 0.30      // m, programmed-stop accuracy

    // VAL 206 vehicle & traction chain (Verhille thesis, Annexe A / Ch.1;
    // DOT assessment §3.2.5-3.2.7). A rame = 2 married cars (PA + HR);
    // per car one GTO armature chopper feeds two series-wired DC motors
    // (one per bogie, differential 4.3 x wheel reducer 2.0); "image
    // série" field control emulates the series-excited first generation.
    static let tareMass: Double = 31_000         // kg, empty rame
    static let passengerMass: Double = 70        // kg per passenger
    static let motorCount: Int = 4               // 2 per car, 1 per bogie
    static let gearRatio: Double = 8.6           // differential 4.3 x reducer 2.0
    static let wheelRadius: Double = 0.445       // m (rubber-tired running gear)
    static let bogieInertia: Double = 30.35      // kg.m² equivalent at the wheel (thesis Annexe D)
    static let imageSerieFullField: Double = 0.059   // iex = 0.059 ii (phase 1)
    static let imageSerieWeakField: Double = 0.034   // iex = 0.034 ii (phase 3, défluxage)
    static let motorTorquePerAmp2: Double = 0.0326   // km*le, N.m/A² (cm = km.le.iex.ii)
    static let armatureResistance: Double = 0.16     // ohms, two series induits + selfs de lissage
    static let armatureCurrentMax: Double = 620      // A, chopper thermal ceiling
    static let lineVoltage: Double = 750             // V DC on the guide bars
    /// Regenerative braking blends out below ~5-6 km/h (friction only).
    static let regenMinSpeed: Double = 1.5           // m/s
    /// Electrical braking is shed when the line rises above 825 V
    /// (fully gone at 1000 V) -- modelled as a receptivity factor.
    static let regenReceptivity: Double = 0.85
    /// Davis resistance Fr = A + B.v + C.v² (rubber tires: high rolling
    /// term -- coasting decel ~0.12 m/s²).
    static let davisA: Double = 0.011 * 9.81         // N per kg of train mass
    static let davisB: Double = 30.0                 // N per (m/s)
    static let davisC: Double = 2.6                  // N per (m/s)²

    // Anti-patinage (thesis §2.4): motor-speed spread threshold beyond
    // which the affected car's effort is cancelled, then ramped back.
    static let patinageDetectSpread: Double = 8.0 / 3.6   // m/s (8 km/h at the wheel)
    static let patinageRampTime: Double = 3.0             // s to restore full effort

    // Pupitre de conduite manuelle (console A22) -- KACOP vigilance.
    static let kacopWarningDelay: Double = 14.0  // s without acknowledgment -> warning
    static let kacopTripDelay: Double = 20.0     // s -> automatic FU

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
