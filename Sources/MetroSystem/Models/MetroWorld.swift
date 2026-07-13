import Foundation
import Combine

// CBTC DISPATCH SIMULATOR, NOT A SAFETY CONTROLLER.
//
// MetroWorld is the STATE STORE every surface renders and every operator
// path mutates: the fleet, the SCADA alarm log, line-wide switches
// (service / arrêt d'urgence / service provisoire), fleet management and
// the mutate/applyControl choke points. It owns no scan of its own --
// which engine puts state INTO it is the selected backend (Backends/):
// VALSimBackend runs the classic 60 Hz VAL physics against this store,
// the PRATIC backends mirror their network picture into it.
//
// MULTI-NODE: every rame carries an `ownerPeerId`. The active backend
// advances only the rames this node owns; rames owned by a peer (another
// app, or a ClusterDaemon node) arrive over the wire as `.state`
// snapshots (upsert) -- each node protects its own trains against the
// whole picture, exactly one authority per train.

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

    private var nextAlarmSequence: Int = 1
    private var nextTrainNumber: Int = Sim.firstTrainNumber

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
                t.ebCause = "operatorFU"
            case .fuRelease:
                // The FU is only releasable at a stand (the AVP re-arms
                // instantly anyway while a vital condition persists).
                guard t.speed < 0.5 else { return }
                t.isEmergencyBrakeApplied = false
                t.ebCause = "none"
                if t.status == .emergency { t.status = .stopped }
            case .modeAuto:
                t.mode = .auto
                t.manualSpeedRequest = 0
                t.pupitreLever = 0
            case .modeManual:
                t.mode = .manual
                t.manualSpeedRequest = 0
            case .setSpeed:
                guard t.mode == .manual else { return }
                t.manualSpeedRequest = max(0, min(Sim.manualSpeedMax, value ?? 0))
            // Console A22 -- honoured in manual mode (the cover is locked
            // under automatic driving). KG may always be switched.
            case .pupitreKG:
                t.pupitreKG = (value ?? 0) > 0.5
                if !t.pupitreKG { t.pupitreLever = min(t.pupitreLever, 0) }
            case .pupitreReverser:
                guard t.mode == .manual else { return }
                let v = Int((value ?? 0).rounded())
                guard (-1...1).contains(v) else { return }
                // Reversing sense only at a stand; releasing to neutral
                // is always allowed.
                if v != 0 && t.speed >= 0.1 && v != t.pupitreReverser { return }
                t.pupitreReverser = v
            case .pupitreLever:
                guard t.mode == .manual else { return }
                t.pupitreLever = max(-1, min(1, value ?? 0))
            case .kacopAck:
                t.kacopSecondsSinceAck = 0
                t.kacopWarning = false
                // Acknowledging the dead-man at a stand releases a
                // vigilance-tripped FU (the reset a dead-man requires).
                if t.ebCause == "vigilance" && t.speed < 0.5 {
                    t.isEmergencyBrakeApplied = false
                    t.ebCause = "none"
                    if t.status == .emergency { t.status = .stopped }
                }
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

    /// Whether a rame sits outside the active SP section. Store-level so
    /// both setServiceProvisoire and the VAL backend's ZC pass share it.
    func isStranded(_ train: Train, sp: ServiceProvisoire) -> Bool {
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
