import Foundation
import Combine

// CBTC DISPATCH SIMULATOR, NOT A SAFETY CONTROLLER.
//
// `MetroWorld.tick()` runs at Sim.tickHz (60 Hz) and walks every trainset
// through one step of station dwell, asservissement speed regulation and
// alarm sampling, then recomputes each train's movement authority the way
// a wayside zone controller (ZC) would. The structure mirrors a PLC's
// cyclic scan: read inputs -> execute logic -> update outputs -> repeat.
// Real CBTC installations (IEEE 1474.1 / EN 62290) run vital, redundant
// processors with hardware voting; THIS code models the behaviour so the
// PCC panels and SCADA log read like the real thing, but nothing here is
// approved to move a train.
//
// MULTI-NODE: every rame carries an `ownerPeerId`. This node's OBCU logic
// advances only the rames it owns; rames owned by a peer (another app, or
// a ClusterDaemon node) arrive over the wire as `.state` snapshots and are
// dead-reckoned between snapshots. The ZC pass considers ALL rames as
// obstacles but assigns movement authority only to locally-owned ones --
// each node protects its own trains against the whole picture, exactly one
// authority per train.

/// Line-wide operating mode, derived from the world's switches.
enum LineMode: String {
    case stopped            // service not started
    case normal             // conduite automatique intégrale
    case serviceProvisoire  // temporary shuttle between two stations
    case emergency          // arrêt d'urgence général (FU on every rame)
}

enum AlarmSeverity: Int, Codable, CaseIterable, Comparable {
    case advisory = 0
    case minor = 1
    case major = 2
    case critical = 3

    static func < (lhs: AlarmSeverity, rhs: AlarmSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .advisory: return "ADVISORY"
        case .minor: return "MINOR"
        case .major: return "MAJOR"
        case .critical: return "CRITICAL"
        }
    }
}

struct SCADAAlarm: Identifiable, Codable, Hashable {
    let id: UUID
    let sequence: Int
    let raisedAt: Date
    var acknowledgedAt: Date?
    var clearedAt: Date?
    let source: String
    let point: String
    let severity: AlarmSeverity
    let message: String
    /// True when the alarm is backed by a live field condition that the
    /// tick sampler auto-manages (OVERSPEED, DOOR_OPEN, ...). Such alarms
    /// return to normal on their own when the condition clears and are NOT
    /// operator-clearable -- pressing CLEAR on an in-condition alarm would
    /// be alarm suppression (ISA-18.2), so the panel skips them. Latched
    /// faults (manual fault-injection, the injector) leave this false and
    /// must be cleared by the operator.
    var processDriven: Bool = false
    /// Operator has shelved this alarm (ISA-18.2 SHLVD): removed from the
    /// primary annunciator but kept in the log so the action is auditable.
    var shelvedAt: Date? = nil

    var isActive: Bool { clearedAt == nil }
    var isAcknowledged: Bool { acknowledgedAt != nil }
    var isShelved: Bool { shelvedAt != nil && isActive }
    var isOperatorClearable: Bool { isActive && !processDriven }
    var statusLabel: String {
        if isShelved { return "SHLVD" }
        if clearedAt != nil {
            return acknowledgedAt == nil ? "RTN" : "CLEARED"
        }
        return acknowledgedAt == nil ? "UNACK" : "ACK"
    }
}

@MainActor
final class MetroWorld: ObservableObject {
    @Published var trains: [Train] = []
    @Published var isRunning: Bool = false          // line service on/off
    @Published var isEmergencyStopped: Bool = false // arrêt d'urgence général
    @Published var activeSP: ServiceProvisoire? = nil
    @Published private(set) var alarmLog: [SCADAAlarm] = []

    @Published var localPeerId: String
    @Published var localPeerLabel: String

    let cantons: [Canton]
    let stations: [Station]

    private var timer: Timer?
    private var lastTickAt: Date = .init()
    private var nextAlarmSequence: Int = 1
    private var nextTrainNumber: Int = Sim.firstTrainNumber
    private var doorOpenSince: [UUID: Date] = [:]
    /// SP interval pacing: last departure timestamp per terminus station.
    private var lastTerminusDeparture: [Int: Date] = [:]

    /// Fired after every locally-owned mutation (operator action) so the
    /// peer link can push the fresh `.state` immediately. The 10 Hz
    /// periodic rebroadcast in PeerNetwork covers physics motion.
    var onLocalChange: ((Train) -> Void)?
    /// Fired when a locally-owned rame is withdrawn, so peers drop it too.
    var onLocalRemove: ((UUID) -> Void)?

    var lineMode: LineMode {
        if isEmergencyStopped { return .emergency }
        if activeSP != nil { return .serviceProvisoire }
        return isRunning ? .normal : .stopped
    }

    init(localPeerId: String = UUID().uuidString,
         localPeerLabel: String = Host.current().localizedName ?? "PCC") {
        self.localPeerId = localPeerId
        self.localPeerLabel = localPeerLabel
        self.cantons = (0..<Sim.cantonCount).map { i in
            Canton(id: i + 1,
                   name: "Canton \(i + 1)",
                   startPosition: Double(i) * Sim.cantonLength,
                   length: Sim.cantonLength)
        }
        self.stations = Sim.stationLayout.enumerated().map { (i, s) in
            Station(id: i + 1, name: s.name, position: s.position)
        }
    }

    func start() {
        guard timer == nil else { return }
        lastTickAt = Date()
        let t = Timer(timeInterval: Sim.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: -- fleet management

    func seedTrains() {
        for _ in 0..<Sim.seedTrainCount { addTrain() }
    }

    @discardableResult
    func addTrain() -> Train? {
        guard locallyOwned().count < Sim.maxTrainCount else { return nil }
        // Spawn docked at the station farthest from every existing train
        // (local or remote) so a new rame never materialises inside
        // another's MA envelope.
        let candidates = activeStations()
        let spawn = candidates.max { a, b in
            nearestTrainDistance(to: a.position) < nearestTrainDistance(to: b.position)
        } ?? stations[0]
        var t = Train(id: UUID(), label: String(nextTrainNumber),
                      ownerPeerId: localPeerId, position: spawn.position)
        nextTrainNumber += 1
        t.status = .docked
        t.isDwelling = true
        t.dwellRemaining = 3.0
        t.doorsOpen = true
        t.lastServicedStationId = spawn.id
        t.movementAuthority = spawn.position
        t.passengerCount = Int.random(in: 10...40)
        trains.append(t)
        sortTrains()
        onLocalChange?(t)
        return t
    }

    func removeTrain(id: UUID) {
        guard let train = trains.first(where: { $0.id == id }), canControl(train) else { return }
        trains.removeAll { $0.id == id }
        doorOpenSince.removeValue(forKey: id)
        onLocalRemove?(id)
    }

    private func nearestTrainDistance(to position: Double) -> Double {
        guard !trains.isEmpty else { return .greatestFiniteMagnitude }
        return trains.map { t in
            let d = abs(t.position - position)
            return min(d, Sim.trackLength - d)
        }.min() ?? .greatestFiniteMagnitude
    }

    private func sortTrains() {
        trains.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    // MARK: -- peer plumbing

    func locallyOwned() -> [Train] {
        trains.filter { $0.ownerPeerId == localPeerId }
    }

    func canControl(_ train: Train) -> Bool {
        train.ownerPeerId == localPeerId
    }

    /// Adopt or refresh a peer-owned rame from a `.state` snapshot.
    func upsert(_ train: Train) {
        if let idx = trains.firstIndex(where: { $0.id == train.id }) {
            trains[idx] = train
        } else {
            trains.append(train)
            sortTrains()
        }
    }

    func removeAll(ownedBy peerId: String) {
        trains.removeAll { $0.ownerPeerId == peerId }
    }

    func remove(id: UUID, ownedBy peerId: String) {
        trains.removeAll { $0.id == id && $0.ownerPeerId == peerId }
    }

    /// Single mutation choke point for LOCALLY-OWNED rames, mirroring a PLC
    /// output-image write. A mutation request against a peer-owned rame is
    /// silently ignored (returns nil) -- this node never rewrites state it
    /// doesn't own, no matter who asked. Fires `onLocalChange` so the fresh
    /// state reaches peers immediately.
    @discardableResult
    func mutate(_ id: UUID, _ block: (inout Train) -> Void) -> Train? {
        guard let idx = trains.firstIndex(where: { $0.id == id }) else { return nil }
        guard trains[idx].ownerPeerId == localPeerId else { return nil }
        block(&trains[idx])
        let snap = trains[idx]
        onLocalChange?(snap)
        return snap
    }

    /// Apply a train-control action to a LOCALLY-OWNED rame. This is the
    /// single choke point the local operator path, the DCL verbs, the
    /// Modbus coil/register writes, and the inbound peer `.command`
    /// handler all funnel through.
    @discardableResult
    func applyControl(trainId: UUID, kind: TrainCommandKind, value: Double? = nil) -> Train? {
        mutate(trainId) { t in
            switch kind {
            case .openDoors:
                guard t.speed < 0.1 else { return }
                t.doorsOpen = true
                t.isDwelling = true
                t.dwellRemaining = max(t.dwellRemaining, 5.0)
                t.status = .docked
            case .closeDoors:
                t.doorsOpen = false
                t.isDwelling = false
                t.dwellRemaining = 0
                t.paxRemaining = 0
            case .fuSet:
                if !t.isEmergencyBrakeApplied { t.emergencyBrakeCounter += 1 }
                t.isEmergencyBrakeApplied = true
            case .fuRelease:
                t.isEmergencyBrakeApplied = false
                if t.status == .emergency { t.status = .stopped }
            case .modeAuto:
                t.mode = .auto
                t.manualSpeedRequest = 0
            case .modeManual:
                t.mode = .manual
                t.manualSpeedRequest = 0
            case .setSpeed:
                guard t.mode == .manual else { return }
                t.manualSpeedRequest = max(0, min(Sim.manualSpeedMax, value ?? 0))
            }
        }
    }

    /// Find a rame by operator-supplied label: "101", "R101", "RAME 101".
    func findTrain(label raw: String) -> Train? {
        var needle = raw.uppercased()
        for prefix in ["RAME", "R"] where needle.hasPrefix(prefix) {
            let stripped = needle.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty, Int(stripped) != nil { needle = stripped }
        }
        if let exact = trains.first(where: { $0.label.uppercased() == needle }) { return exact }
        if let n = Int(needle) { return trains.first(where: { Int($0.label) == n }) }
        return nil
    }

    func displayLabel(for train: Train) -> String { train.label }

    var sortedTrains: [Train] {
        trains.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func canton(at position: Double) -> Canton? {
        cantons.first { $0.contains(position) }
    }

    func stationName(id: Int?) -> String {
        guard let id, let s = stations.first(where: { $0.id == id }) else { return "--" }
        return s.name
    }

    // MARK: -- line-level commands

    func startService() {
        isRunning = true
    }

    func stopService() {
        isRunning = false
    }

    func emergencyStopAll(_ on: Bool) {
        isEmergencyStopped = on
        if on {
            for t in locallyOwned() { mutate(t.id) { $0.isEmergencyBrakeApplied = true } }
        } else {
            for t in locallyOwned() {
                mutate(t.id) { tr in
                    tr.isEmergencyBrakeApplied = false
                    if tr.status == .emergency { tr.status = .stopped }
                }
            }
        }
    }

    /// Engage / clear a service provisoire. A local exploitation overlay:
    /// only this node's rames observe the barriers and shuttle pattern.
    /// Setting one teleports any locally-owned rame stranded outside the
    /// active section to the nearest served station; clearing it returns
    /// every local rame to forward running.
    func setServiceProvisoire(_ sp: ServiceProvisoire?) {
        if sp == nil, activeSP != nil {
            for t in locallyOwned() {
                mutate(t.id) { $0.travelDirection = .forward }
            }
            lastTerminusDeparture.removeAll()
        } else if let sp {
            let served = activeStations(sp: sp)
            for t in locallyOwned() where isStranded(t, sp: sp) {
                guard let nearest = served.min(by: { loopDistance(from: t.position, to: $0.position) < loopDistance(from: t.position, to: $1.position) }) else { continue }
                mutate(t.id) { tr in
                    tr.position = nearest.position
                    tr.movementAuthority = nearest.position
                    tr.speed = 0
                    tr.status = .docked
                    tr.travelDirection = .forward
                    tr.lastServicedStationId = nearest.id
                    tr.isDwelling = true
                    tr.dwellRemaining = 5.0
                    tr.doorsOpen = true
                }
            }
        }
        activeSP = sp
    }

    /// Stations inside the active section (the whole line when no SP).
    func activeStations(sp: ServiceProvisoire? = nil) -> [Station] {
        guard let sp = sp ?? activeSP,
              let s1 = stations.first(where: { $0.id == sp.startStationId }),
              let s2 = stations.first(where: { $0.id == sp.endStationId }) else { return stations }
        let (lo, hi) = (min(s1.position, s2.position), max(s1.position, s2.position))
        if s1.position <= s2.position {
            return stations.filter { $0.position >= lo && $0.position <= hi }
        } else {
            return stations.filter { $0.position >= s1.position || $0.position <= s2.position }
        }
    }

    private func isStranded(_ train: Train, sp: ServiceProvisoire) -> Bool {
        guard let s1 = stations.first(where: { $0.id == sp.startStationId }),
              let s2 = stations.first(where: { $0.id == sp.endStationId }) else { return false }
        let tolerance = 5.0
        if s1.position <= s2.position {
            return train.position < s1.position - tolerance || train.position > s2.position + tolerance
        } else {
            return train.position > s2.position + tolerance && train.position < s1.position - tolerance
        }
    }

    private func loopDistance(from a: Double, to b: Double) -> Double {
        let d = abs(a - b)
        return min(d, Sim.trackLength - d)
    }

    // MARK: -- scan loop

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTickAt))
        lastTickAt = now

        computeMovementAuthorities()
        enforceServiceProvisoire(now: now)

        for index in trains.indices {
            if trains[index].ownerPeerId == localPeerId {
                advance(&trains[index], dt: dt)
            } else {
                deadReckon(&trains[index], dt: dt)
            }
        }

        sampleSystemAlarms()
        sampleTrainAlarms(at: now)
    }

    /// Dead-reckon a peer-owned rame between `.state` snapshots: integrate
    /// the last reported speed along its running direction. At the daemon's
    /// default 60 Hz broadcast the snapshots dominate; at lower rates this
    /// keeps motion smooth instead of stepping.
    private func deadReckon(_ train: inout Train, dt: Double) {
        guard train.speed > 0.01 else { return }
        train.position += train.speed * train.travelDirection.rawValue * dt
        train.position = train.position.truncatingRemainder(dividingBy: Sim.trackLength)
        if train.position < 0 { train.position += Sim.trackLength }
    }

    /// Zone-controller pass: each locally-owned train's LMA is the tail of
    /// the train ahead (local OR remote) minus the safety margin, or an SP
    /// virtual barrier when one is closer. Direction-aware so reversed
    /// shuttles brake toward the correct barrier. Peer-owned trains are
    /// obstacles only -- their own node computes their authority.
    private func computeMovementAuthorities() {
        let trackLength = Sim.trackLength
        let snapshot = trains

        for me in snapshot where me.ownerPeerId == localPeerId {
            var minDist = Double.greatestFiniteMagnitude
            var obstaclePos: Double? = nil
            var isSPBarrier = false

            for other in snapshot where other.id != me.id {
                var d: Double = me.travelDirection == .forward
                    ? other.position - me.position
                    : me.position - other.position
                if d <= 0 { d += trackLength }
                if d < minDist {
                    minDist = d
                    obstaclePos = other.position
                }
            }

            var stranded = false
            if let sp = activeSP {
                stranded = isStranded(me, sp: sp)
                if !stranded {
                    let barriers = [sp.startStationId, sp.endStationId]
                        .compactMap { sid in stations.first(where: { $0.id == sid })?.position }
                    for barrier in barriers {
                        var d: Double = me.travelDirection == .forward
                            ? barrier - me.position
                            : me.position - barrier
                        if d <= 0 { d += trackLength }
                        if d <= minDist + 0.1 {
                            minDist = d
                            obstaclePos = barrier
                            isSPBarrier = true
                        }
                    }
                }
            }

            var ma: Double
            if stranded {
                ma = me.position                       // vital stop in place
            } else if let leaderPos = obstaclePos {
                let margin = isSPBarrier ? 0.0 : Sim.safetyMargin
                if me.travelDirection == .forward {
                    ma = leaderPos - margin
                    if ma < 0 { ma += trackLength }
                } else {
                    ma = (leaderPos + margin).truncatingRemainder(dividingBy: trackLength)
                }
            } else {
                // Line to itself all the way around.
                if me.travelDirection == .forward {
                    ma = (me.position + trackLength - Sim.safetyMargin)
                        .truncatingRemainder(dividingBy: trackLength)
                } else {
                    ma = me.position - trackLength + Sim.safetyMargin
                    if ma < 0 { ma += trackLength }
                }
            }

            // Direct write (not mutate): the MA refresh happens every scan
            // for every local train; broadcasting it as an operator event
            // would flood the wire. The periodic state rebroadcast carries it.
            if let idx = trains.firstIndex(where: { $0.id == me.id }) {
                trains[idx].movementAuthority = ma
                trains[idx].targetSpeed = Sim.lineSpeed
            }
        }
    }

    /// SP shuttle behaviour: reverse a rame docked at a terminus pointing
    /// at the barrier, and pace departures from the termini to the
    /// configured headway. Locally-owned rames only.
    private func enforceServiceProvisoire(now: Date) {
        guard let sp = activeSP else {
            for t in locallyOwned() where t.isDepartureHold {
                mutate(t.id) { $0.isDepartureHold = false }
            }
            return
        }
        for t in locallyOwned() {
            if t.status == .docked, t.speed == 0, t.paxRemaining == 0, !isStranded(t, sp: sp) {
                if (t.lastServicedStationId == sp.startStationId && t.travelDirection == .reverse) ||
                   (t.lastServicedStationId == sp.endStationId && t.travelDirection == .forward) {
                    mutate(t.id) { tr in
                        tr.travelDirection = tr.travelDirection == .forward ? .reverse : .forward
                        tr.speed = 0
                        tr.movementAuthority = tr.position
                    }
                }
            }
            let atTerminus = t.status == .docked &&
                (t.lastServicedStationId == sp.startStationId || t.lastServicedStationId == sp.endStationId)
            if atTerminus, let stationId = t.lastServicedStationId {
                let lastDep = lastTerminusDeparture[stationId] ?? .distantPast
                if now.timeIntervalSince(lastDep) < sp.intervalle && lastDep != .distantPast {
                    if !t.isDepartureHold { mutate(t.id) { $0.isDepartureHold = true } }
                } else {
                    if t.dwellRemaining <= 0 { lastTerminusDeparture[stationId] = now }
                    if t.isDepartureHold { mutate(t.id) { $0.isDepartureHold = false } }
                }
            } else if t.isDepartureHold {
                mutate(t.id) { $0.isDepartureHold = false }
            }
        }
    }

    // MARK: -- per-train scan (OBCU logic)

    private func advance(_ train: inout Train, dt: Double) {
        let trackLength = Sim.trackLength

        var effectiveDistToMA = directedDistance(to: train.movementAuthority, train: train)
        if effectiveDistToMA < 0 { effectiveDistToMA += trackLength }

        // Vital overrides: FU, door fault, brake fault, controller-freeze
        // alarm, line-wide emergency -- maximum-rate brake to a stand.
        if train.isDoorFault || train.isBrakeFault || train.isEmergencyBrakeApplied ||
           isEmergencyStopped || motionInhibitedByAlarm(for: train) {
            train.status = .emergency
            train.distanceToMA = effectiveDistToMA
            applyPhysics(&train, acceleration: -Sim.emergencyBraking, trackLength: trackLength)
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Line service off: brake to a stand and hold.
        if !isRunning {
            if train.speed > 0 {
                applyPhysics(&train, acceleration: -Sim.nominalBraking, trackLength: trackLength)
            } else {
                train.acceleration = 0
                train.status = train.isDwelling ? .docked : .stopped
            }
            train.distanceToMA = effectiveDistToMA
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Manual driving (conduite manuelle limitée).
        if train.mode == .manual {
            if train.doorsOpen {
                train.status = train.speed > 0 ? .moving : .docked
                applyPhysics(&train, acceleration: train.speed > 0 ? -Sim.emergencyBraking : 0, trackLength: trackLength)
            } else {
                let target = min(train.manualSpeedRequest, Sim.manualSpeedMax)
                var desiredAcc: Double = 0
                if train.speed < target { desiredAcc = Sim.maxAcceleration }
                else if train.speed > target { desiredAcc = -Sim.emergencyBraking }
                if train.isEngineFault {
                    desiredAcc = train.speed > 0 ? -0.1 : 0
                }
                train.status = train.speed > 0 ? .moving : .stopped
                applyPhysics(&train, acceleration: applyAdhesion(desiredAcc, train: train), trackLength: trackLength)
            }
            train.distanceToMA = effectiveDistToMA
            updateAuxiliaries(&train, dt: dt)
            return
        }

        // Station dwell (à quai, doors open, passenger exchange).
        if train.isDwelling {
            train.dwellRemaining -= dt
            if train.dwellRemaining <= 0 {
                train.passengerCount = max(0, train.passengerCount + train.paxRemaining)
                train.paxRemaining = 0
                train.dwellRemaining = 0
                if !train.isDepartureHold {
                    train.isDwelling = false
                    train.doorsOpen = false
                    train.status = .moving
                    train.lastPaxChange = 0
                }
            } else {
                if train.paxRemaining != 0 {
                    train.paxExchangeTimer -= dt
                    if train.paxExchangeTimer <= 0 {
                        if train.paxRemaining > 0 {
                            train.passengerCount += 1
                            train.paxRemaining -= 1
                        } else {
                            train.passengerCount = max(0, train.passengerCount - 1)
                            train.paxRemaining += 1
                        }
                        train.paxExchangeTimer = train.paxExchangeInterval
                    }
                }
                train.status = .docked
                train.speed = 0
                train.acceleration = 0
                train.distanceToMA = effectiveDistToMA
                updateAuxiliaries(&train, dt: dt)
                return
            }
        }

        // Target-station resolution: nearest unserviced stop marker within
        // the approach window becomes the stopping target if it's closer
        // than the ZC's authority.
        let servedStations = activeStations()
        var distToStop: Double? = nil
        var targetStationId: Int? = nil
        for station in servedStations where train.lastServicedStationId != station.id {
            let d = directedDistance(to: station.position, train: train)
            if d >= -5.0 && d < Sim.stationApproachWindow {
                if distToStop == nil || d < distToStop! {
                    distToStop = d
                    targetStationId = station.id
                }
            }
        }

        if let nextId = targetStationId {
            train.nextStationName = stationName(id: nextId)
        }

        if let dist = distToStop, let stationId = targetStationId {
            if dist < effectiveDistToMA { effectiveDistToMA = dist }
            if dist <= Sim.stationStopTolerance && abs(train.speed) < 0.1 {
                beginDwell(&train, stationId: stationId)
                train.distanceToMA = effectiveDistToMA
                updateAuxiliaries(&train, dt: dt)
                return
            }
        } else if let lastId = train.lastServicedStationId,
                  let lastStation = stations.first(where: { $0.id == lastId }) {
            let d = directedDistance(to: lastStation.position, train: train)
            if d > 200 { train.lastServicedStationId = nil }
        }

        // Signal fault: the rame loses its radio MA -- ATP collapses the
        // authority to zero and the braking curve stops the train.
        if train.isSignalFault { effectiveDistToMA = 0 }

        // Asservissement (speed regulation): braking-curve target speed,
        // proportional control, vital FU envelope, adhesion model.
        var consigne: Double = 0
        if effectiveDistToMA > Sim.maDistanceMargin {
            let curve = (2 * Sim.nominalBraking * (effectiveDistToMA - Sim.maDistanceMargin)).squareRoot()
            consigne = min(train.targetSpeed, curve)
        }
        let speedError = consigne - train.speed
        var desiredAcc = speedError * 1.0          // Kp = 1.0

        let safeBrakingDistance = (train.speed * train.speed) / (2 * Sim.emergencyBraking)
        if effectiveDistToMA <= safeBrakingDistance + 0.5 {
            desiredAcc = -Sim.emergencyBraking
        }
        if train.isEngineFault {
            desiredAcc = min(desiredAcc, train.speed > 0 ? -0.1 : 0)
        }
        desiredAcc = max(-Sim.emergencyBraking, min(Sim.maxAcceleration, desiredAcc))

        if abs(train.speed) < 0.05 && consigne < 0.1 {
            train.status = .stopped
            train.speed = 0
            desiredAcc = 0
        } else {
            train.status = .moving
        }

        train.consigneVitesse = consigne
        train.speedError = speedError
        train.distanceToMA = effectiveDistToMA

        applyPhysics(&train, acceleration: applyAdhesion(desiredAcc, train: train), trackLength: trackLength)
        updateAuxiliaries(&train, dt: dt)
    }

    private func beginDwell(_ train: inout Train, stationId: Int) {
        train.isDwelling = true
        let dwell = Double.random(in: Sim.dwellMin...Sim.dwellMax)
        train.dwellRemaining = dwell
        train.doorsOpen = true
        train.status = .docked
        train.speed = 0
        train.acceleration = 0
        train.lastServicedStationId = stationId
        let headroom = max(0, Sim.paxCapacity - train.passengerCount)
        let change = Int.random(in: -min(Sim.paxAlightMax, train.passengerCount)...min(Sim.paxBoardMax, headroom))
        train.lastPaxChange = change
        train.paxRemaining = change
        train.paxExchangeInterval = abs(change) > 0 ? (dwell * 0.6) / Double(abs(change)) : 1.0
        train.paxExchangeTimer = 0
    }

    /// Tire-adhesion and patinage / enrayage model applied to the traction
    /// or braking command (port of the CBTC AsservissementModule).
    private func applyAdhesion(_ desiredAcc: Double, train: Train) -> Double {
        var final = desiredAcc
        var adhesion = 0.0
        var drag = 0.0
        for tire in train.tires {
            switch tire.status {
            case .ok:          adhesion += 1.0
            case .lowPressure: adhesion += 0.9; drag += 0.05
            case .puncture:    adhesion += 0.5; drag += 0.2
            case .burst:       adhesion += 0.1; drag += 0.5
            }
        }
        let avg = adhesion / Double(max(1, train.tires.count))
        final *= avg
        if train.isPatinage && final > 0 { final *= 0.2 }
        if train.isEnrayage && final < 0 { final *= 0.3 }
        if train.speed > 0 {
            final -= drag
        } else if train.speed == 0 && final < drag {
            final = max(final, 0) == 0 ? 0 : final - drag
        }
        return final
    }

    private func applyPhysics(_ train: inout Train, acceleration: Double, trackLength: Double) {
        train.acceleration = acceleration
        train.speed += acceleration * Sim.tickInterval
        if train.speed < 0 { train.speed = 0 }
        train.position += train.speed * train.travelDirection.rawValue * Sim.tickInterval
        train.position = train.position.truncatingRemainder(dividingBy: trackLength)
        if train.position < 0 { train.position += trackLength }
    }

    /// Direction-aware distance from the train to an absolute track point,
    /// normalised to (-L/2, L/2].
    private func directedDistance(to target: Double, train: Train) -> Double {
        var d = target - train.position
        if train.travelDirection == .reverse { d = train.position - target }
        if d < -Sim.trackLength / 2 { d += Sim.trackLength }
        else if d > Sim.trackLength / 2 { d -= Sim.trackLength }
        return d
    }

    /// Synthetic-but-plausible auxiliary telemetry so the synoptic and DCL
    /// SHOW RAME sheets read like a live TCMS.
    private func updateAuxiliaries(_ train: inout Train, dt: Double) {
        let motoring = train.acceleration > 0.05
        let braking = train.acceleration < -0.05
        train.tractionCurrent = motoring ? min(1500, 400 + train.speed * 60) : (braking ? 120 : 40)
        train.tractionTorque = max(-100, min(100, train.acceleration / Sim.maxAcceleration * 100))
        train.mainVoltage = 750 - train.tractionCurrent * 0.02
        train.compressorPressure += (train.isCompressorRunning ? 0.08 : -0.01) * dt * 10
        if train.compressorPressure < 7.4 { train.isCompressorRunning = true }
        if train.compressorPressure > 9.0 { train.isCompressorRunning = false }
        train.compressorPressure = max(6.0, min(9.5, train.compressorPressure))

        // Static converter (CVS): ~112 V DC low-voltage bus while the 750 V
        // line is up; it sags if third-rail pickup collapses.
        train.cvsOutputVoltage = train.mainVoltage > 400
            ? 112.0 - (750 - train.mainVoltage) * 0.01
            : max(0, train.cvsOutputVoltage - 40 * dt)
        // Lighting circuit draw follows the lamps and DELESTAGE BT shedding.
        train.lightingCurrent = train.areLightsOn
            ? (train.isLoadSheddingActive ? 5.0 : 15.0)
            : 0.0
        // Friction-brake box heats under service/emergency braking, cools
        // otherwise (bounded to a plausible TCMS range).
        let brakeHeat = (braking || train.isEmergencyBrakeApplied) ? 14.0 : -6.0
        train.brakeBoxTemperature = max(30, min(140, train.brakeBoxTemperature + brakeHeat * dt))
        // Cabin temperature drifts toward the HVAC setpoint; load shedding
        // parks ventilation so it drifts a few degrees warm.
        let comfortTarget = train.targetTemperature + (train.isLoadSheddingActive ? 3.0 : 0.0)
        train.interiorTemperature += (comfortTarget - train.interiorTemperature) * 0.02
        // RAZ MULTIMEDIA is momentary: the reset self-clears once acknowledged.
        if train.isMultimediaResetting { train.isMultimediaResetting = false }
    }

    // MARK: -- safety chain (shared by Modbus DI and the alarm samplers)

    /// Assembles a rame's safety-chain contact states for the Modbus
    /// discrete-input block (each `true` = contact closed / healthy). The
    /// overall loop is additionally gated on the line not being under a
    /// general emergency stop, so an arrêt d'urgence reads as a chain
    /// interrupt.
    func safetyChain(for train: Train) -> SafetyChain {
        let doorInterlock = train.doorInterlockLocked || train.status == .docked
        let overspeedOK   = !train.isOverspeed
        let maOK          = !train.isMAEncroached
        let brakeOK       = !train.isBrakeFault
        let adhesionOK    = train.worstTire != .burst
        let intact = doorInterlock && overspeedOK && maOK && brakeOK && adhesionOK
            && !isEmergencyStopped
        return SafetyChain(doorInterlock: doorInterlock,
                           overspeedOK: overspeedOK,
                           maMarginOK: maOK,
                           brakeOK: brakeOK,
                           adhesionOK: adhesionOK,
                           intact: intact)
    }

    // MARK: -- alarm sampling

    private func sampleSystemAlarms() {
        switch lineMode {
        case .emergency:
            raiseAlarm(source: "SYS", point: "SAFETY_MODE", severity: .critical,
                       message: Strings.lookup("alarm.msg.emergency", lang: .en),
                       processDriven: true)
        case .serviceProvisoire:
            raiseAlarm(source: "SYS", point: "SAFETY_MODE", severity: .major,
                       message: Strings.lookup("alarm.msg.sp", lang: .en),
                       processDriven: true)
        case .normal, .stopped:
            clearAlarm(source: "SYS", point: "SAFETY_MODE")
        }
    }

    private func sampleTrainAlarms(at now: Date) {
        // A node's SCADA only monitors the rames it OWNS. Remote rames are
        // the owning node's responsibility -- sampling their broadcast
        // state here would raise faults this node can't remediate.
        let localTrains = locallyOwned()
        let currentIds = Set(localTrains.map(\.id))
        doorOpenSince = doorOpenSince.filter { currentIds.contains($0.key) }

        for train in localTrains {
            let source = "RAME \(train.label)"

            sample(source, "OVERSPEED", train.isOverspeed, .critical, "alarm.msg.overspeed")
            sample(source, "MA_LIMIT", train.isMAEncroached, .critical, "alarm.msg.malimit")
            sample(source, "FU", train.isEmergencyBrakeApplied, .major, "alarm.msg.fu")
            sample(source, "PORTES", train.isDoorFault, .critical, "alarm.msg.doorfault")
            sample(source, "TRACTION", train.isEngineFault, .major, "alarm.msg.enginefault")
            sample(source, "FREIN", train.isBrakeFault, .critical, "alarm.msg.brakefault")
            sample(source, "CTC_RADIO", train.isSignalFault, .major, "alarm.msg.signalfault")
            sample(source, "PATINAGE", train.isPatinage, .advisory, "alarm.msg.patinage")
            sample(source, "ENRAYAGE", train.isEnrayage, .advisory, "alarm.msg.enrayage")

            switch train.worstTire {
            case .ok:
                clearAlarm(source: source, point: "PNEU")
            case .lowPressure:
                raiseAlarm(source: source, point: "PNEU", severity: .minor,
                           message: Strings.lookup("alarm.msg.tirelow", lang: .en), processDriven: true)
            case .puncture:
                raiseAlarm(source: source, point: "PNEU", severity: .major,
                           message: Strings.lookup("alarm.msg.tirepuncture", lang: .en), processDriven: true)
            case .burst:
                raiseAlarm(source: source, point: "PNEU", severity: .critical,
                           message: Strings.lookup("alarm.msg.tireburst", lang: .en), processDriven: true)
            }

            let full = Double(train.passengerCount) >= Double(Sim.paxCapacity) * 0.8
            sample(source, "PAX_LOAD", full, .advisory, "alarm.msg.paxfull")

            // Doors held open past the dwell in normal running -- a platform
            // obstruction or a stuck door leaf.
            let shouldTrack = train.doorsOpen && lineMode != .emergency
            if shouldTrack {
                let since = doorOpenSince[train.id] ?? now
                doorOpenSince[train.id] = since
                if now.timeIntervalSince(since) > Sim.dwellMax + 6.0 && !train.isDepartureHold {
                    raiseAlarm(source: source, point: "DOOR_OPEN", severity: .minor,
                               message: Strings.lookup("alarm.msg.doorheld", lang: .en), processDriven: true)
                } else {
                    clearAlarm(source: source, point: "DOOR_OPEN")
                }
            } else {
                doorOpenSince.removeValue(forKey: train.id)
                clearAlarm(source: source, point: "DOOR_OPEN")
            }
        }
    }

    /// Sample one process-driven point: raise while the condition holds,
    /// return-to-normal when it clears.
    private func sample(_ source: String, _ point: String, _ condition: Bool,
                        _ severity: AlarmSeverity, _ messageKey: String) {
        if condition {
            raiseAlarm(source: source, point: point, severity: severity,
                       message: Strings.lookup(messageKey, lang: .en), processDriven: true)
        } else {
            clearAlarm(source: source, point: point)
        }
    }

    /// A latched SYS/CONTROLLER fault (PCC watchdog) freezes every local
    /// rame, like a controller-fault interlock in a real DCS.
    private func motionInhibitedByAlarm(for train: Train) -> Bool {
        alarmLog.contains { $0.isActive && $0.source == "SYS" && $0.point == "CONTROLLER" }
    }

    // MARK: -- alarm log API (shared by the SCADA panel and DCL verbs)

    var activeAlarms: [SCADAAlarm] {
        alarmLog
            .filter { $0.isActive && !$0.isShelved }
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.raisedAt > $1.raisedAt
            }
    }

    var unacknowledgedAlarmCount: Int {
        alarmLog.filter { $0.isActive && !$0.isAcknowledged && !$0.isShelved }.count
    }

    var shelvedAlarms: [SCADAAlarm] {
        alarmLog.filter(\.isShelved)
    }

    var returnedToNormalUnackedCount: Int {
        alarmLog.filter { $0.clearedAt != nil && $0.acknowledgedAt == nil }.count
    }

    var highestActiveSeverity: AlarmSeverity? {
        activeAlarms.map(\.severity).max()
    }

    @discardableResult
    func raiseAlarm(source: String, point: String, severity: AlarmSeverity, message: String, processDriven: Bool = false) -> SCADAAlarm {
        if let index = alarmLog.firstIndex(where: { $0.isActive && $0.source == source && $0.point == point }) {
            return alarmLog[index]
        }
        let alarm = SCADAAlarm(id: UUID(),
                               sequence: nextAlarmSequence,
                               raisedAt: Date(),
                               acknowledgedAt: nil,
                               clearedAt: nil,
                               source: source,
                               point: point,
                               severity: severity,
                               message: message,
                               processDriven: processDriven)
        nextAlarmSequence += 1
        alarmLog.insert(alarm, at: 0)
        if alarmLog.count > 200 {
            alarmLog.removeLast(alarmLog.count - 200)
        }
        return alarm
    }

    @discardableResult
    func acknowledgeAlarm(sequence: Int) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.sequence == sequence && $0.isActive }) else { return false }
        guard alarmLog[index].acknowledgedAt == nil else { return true }
        alarmLog[index].acknowledgedAt = Date()
        return true
    }

    func acknowledgeAllAlarms() -> Int {
        var count = 0
        for index in alarmLog.indices where alarmLog[index].isActive && alarmLog[index].acknowledgedAt == nil {
            alarmLog[index].acknowledgedAt = Date()
            count += 1
        }
        return count
    }

    @discardableResult
    func clearAllActiveAlarms() -> Int {
        let now = Date()
        var count = 0
        for index in alarmLog.indices where alarmLog[index].isOperatorClearable {
            alarmLog[index].clearedAt = now
            count += 1
        }
        return count
    }

    @discardableResult
    func clearAcknowledgedActiveAlarms() -> Int {
        let now = Date()
        var count = 0
        for index in alarmLog.indices
        where alarmLog[index].isOperatorClearable && alarmLog[index].isAcknowledged {
            alarmLog[index].clearedAt = now
            count += 1
        }
        return count
    }

    var hasClearableAlarms: Bool {
        alarmLog.contains { $0.isOperatorClearable }
    }

    var hasClearableAcknowledgedAlarms: Bool {
        alarmLog.contains { $0.isOperatorClearable && $0.isAcknowledged }
    }

    @discardableResult
    func clearAlarm(sequence: Int) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.sequence == sequence && $0.isActive }) else { return false }
        alarmLog[index].clearedAt = Date()
        return true
    }

    @discardableResult
    func clearAlarm(source: String, point: String) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.isActive && $0.source == source && $0.point == point }) else { return false }
        alarmLog[index].clearedAt = Date()
        return true
    }

    @discardableResult
    func shelveAlarm(sequence: Int) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.sequence == sequence && $0.isActive }) else { return false }
        if alarmLog[index].shelvedAt == nil { alarmLog[index].shelvedAt = Date() }
        return true
    }

    @discardableResult
    func unshelveAlarm(sequence: Int) -> Bool {
        guard let index = alarmLog.firstIndex(where: { $0.sequence == sequence }) else { return false }
        alarmLog[index].shelvedAt = nil
        return true
    }
}
