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

    let cantons: [Canton]
    let stations: [Station]

    private var timer: Timer?
    private var lastTickAt: Date = .init()
    private var nextAlarmSequence: Int = 1
    private var nextTrainNumber: Int = Sim.firstTrainNumber
    private var doorOpenSince: [UUID: Date] = [:]
    /// SP interval pacing: last departure timestamp per terminus station.
    private var lastTerminusDeparture: [Int: Date] = [:]

    var lineMode: LineMode {
        if isEmergencyStopped { return .emergency }
        if activeSP != nil { return .serviceProvisoire }
        return isRunning ? .normal : .stopped
    }

    init() {
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
        guard trains.count < Sim.maxTrainCount else { return nil }
        // Spawn docked at the station farthest from every existing train
        // so a new rame never materialises inside another's MA envelope.
        let candidates = activeStations()
        let spawn = candidates.max { a, b in
            nearestTrainDistance(to: a.position) < nearestTrainDistance(to: b.position)
        } ?? stations[0]
        var t = Train(id: UUID(), label: String(nextTrainNumber), position: spawn.position)
        nextTrainNumber += 1
        t.status = .docked
        t.isDwelling = true
        t.dwellRemaining = 3.0
        t.doorsOpen = true
        t.lastServicedStationId = spawn.id
        t.movementAuthority = spawn.position
        t.passengerCount = Int.random(in: 10...40)
        trains.append(t)
        trains.sort { $0.label < $1.label }
        return t
    }

    func removeTrain(id: UUID) {
        trains.removeAll { $0.id == id }
        doorOpenSince.removeValue(forKey: id)
    }

    private func nearestTrainDistance(to position: Double) -> Double {
        guard !trains.isEmpty else { return .greatestFiniteMagnitude }
        return trains.map { t in
            let d = abs(t.position - position)
            return min(d, Sim.trackLength - d)
        }.min() ?? .greatestFiniteMagnitude
    }

    /// Single mutation choke point, mirroring a PLC output-image write.
    @discardableResult
    func mutate(_ id: UUID, _ block: (inout Train) -> Void) -> Train? {
        guard let idx = trains.firstIndex(where: { $0.id == id }) else { return nil }
        block(&trains[idx])
        return trains[idx]
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
            for t in trains { mutate(t.id) { $0.isEmergencyBrakeApplied = true } }
        } else {
            for t in trains {
                mutate(t.id) { tr in
                    tr.isEmergencyBrakeApplied = false
                    if tr.status == .emergency { tr.status = .stopped }
                }
            }
        }
    }

    /// Engage / clear a service provisoire. Setting one teleports any rame
    /// stranded outside the active section to the nearest served station
    /// (mirroring how the exploitation would clear the barred section);
    /// clearing it returns every rame to forward running.
    func setServiceProvisoire(_ sp: ServiceProvisoire?) {
        if sp == nil, activeSP != nil {
            for t in trains {
                mutate(t.id) { $0.travelDirection = .forward }
            }
            lastTerminusDeparture.removeAll()
        } else if let sp {
            let served = activeStations(sp: sp)
            for t in trains where isStranded(t, sp: sp) {
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
            advance(&trains[index], dt: dt)
        }

        sampleSystemAlarms()
        sampleTrainAlarms(at: now)
    }

    /// Zone-controller pass: each train's LMA is the tail of the train
    /// ahead minus the safety margin, or an SP virtual barrier when one is
    /// closer. Direction-aware so reversed shuttles brake toward the
    /// correct barrier.
    private func computeMovementAuthorities() {
        let trackLength = Sim.trackLength
        let snapshot = trains

        for me in snapshot {
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

            mutate(me.id) { t in
                t.movementAuthority = ma
                t.targetSpeed = Sim.lineSpeed
            }
        }
    }

    /// SP shuttle behaviour: reverse a rame docked at a terminus pointing
    /// at the barrier, and pace departures from the termini to the
    /// configured headway.
    private func enforceServiceProvisoire(now: Date) {
        guard let sp = activeSP else {
            for t in trains where t.isDepartureHold {
                mutate(t.id) { $0.isDepartureHold = false }
            }
            return
        }
        for t in trains {
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
            train.status = train.speed > 0.05 ? .emergency : .emergency
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
        let currentIds = Set(trains.map(\.id))
        doorOpenSince = doorOpenSince.filter { currentIds.contains($0.key) }

        for train in trains {
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

    /// A latched SYS/CONTROLLER fault (PCC watchdog) freezes every rame,
    /// like a controller-fault interlock in a real DCS.
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
