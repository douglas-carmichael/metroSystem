import Foundation

/// The VAL backend, rebuilt around the architecture of the real system
/// (UMTA/DOT interim assessment UMTA-MA-06-0069-81-3; Verhille's VAL 206
/// thesis; STS board nomenclature). MetroWorld stays the store every
/// surface renders -- THIS engine puts VAL state into it, one 60 Hz
/// cyclic scan structured like the real equipment split:
///
///   1. VALWayside      the PA fixe: block occupancy detection (PD/ND),
///                      WCU speed-program selection (SF normal / PP
///                      perturbed / SF withdrawn), DOCU dwell + departure
///                      authorization + SP turnback -- one uplink
///                      telegram per locally-owned rame.
///   2. VALOnboard      the PA embarqué per rame: SAFETY rack (AVP trips
///                      holding off the FU), DRIVE rack (jerk-limited
///                      speed regulation, B1/B2/B3 station stops), or
///                      console A22 (manual driving with KACOP).
///   3. VALTractionChain the HR car: image-série chopper/motor model,
///                      brake blending, per-bogie adhesion + anti-skid,
///                      Davis resistance -- integrates the physics.
///   4. Alarm samplers  process-driven SCADA points, plus the vigilance
///                      and program-mnemonic telemetry.
///
/// Remote (peer-owned) rames are dead-reckoned between `.state`
/// snapshots and feed the occupancy picture as obstacles -- exactly one
/// authority per train, computed by its owner.
///
/// DISPATCH SIMULATOR, NOT A SAFETY CONTROLLER: the real AVP runs
/// fail-safe redundant strings with hardware comparison; nothing here is
/// approved to move a train.
@MainActor
final class VALSimBackend: MetroBackendEngine {
    private weak var world: MetroWorld?
    private var timer: Timer?
    private var lastTickAt: Date = .init()
    private var doorOpenSince: [UUID: Date] = [:]
    /// Return-to-normal hold for intermittent adhesion points: a slip or
    /// slide alarm stays raised until its condition has been clear this
    /// long, so a chattering wheel holds ONE row instead of minting a new
    /// sequence number per flicker (ISA-18.2 off-delay).
    private var slipHoldUntil: [UUID: Date] = [:]
    private var slideHoldUntil: [UUID: Date] = [:]
    private static let adhesionAlarmHold: TimeInterval = 4.0

    private let wayside = VALWayside()
    private let onboard = VALOnboard()
    private let traction = VALTractionChain()

    /// Backend-private OBCU/traction state per locally-owned rame.
    private var obcuState: [UUID: VALOnboardState] = [:]
    private var hadActiveSP = false

    init(world: MetroWorld) {
        self.world = world
    }

    // MARK: -- wayside operator surface (switches)

    /// Operator throw from the PCC (DCL SET LINE /SWITCH). Interlocked:
    /// refused while any vehicle occupies the zone.
    func throwSwitch(id: Int, reversed: Bool) -> VALWayside.SwitchThrowResult {
        guard let world else { return .noSuchSwitch }
        return wayside.throwSwitch(id: id, reversed: reversed,
                                   trains: world.trains, now: Date())
    }

    /// Switch table snapshot for SHOW LINE.
    func switchTable() -> [(id: Int, name: String, entry: Double, exit: Double,
                            reversed: Bool, locked: Bool)] {
        wayside.switchTable(now: Date())
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

    // MARK: -- scan loop

    private func tick() {
        guard let world else { return }
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTickAt))
        lastTickAt = now

        // SP cleared since last scan: reset the DOCU departure clocks.
        if hadActiveSP && world.activeSP == nil {
            wayside.clearDepartureClocks()
        }
        hadActiveSP = world.activeSP != nil

        // 1. Vehicle detection: every known rame occupies its blocks.
        let occupancy = wayside.detectOccupancy(trains: world.trains)
        let controllerAlarm = motionInhibitedByAlarm(world: world)

        for index in world.trains.indices {
            if world.trains[index].ownerPeerId == world.localPeerId {
                let id = world.trains[index].id
                var state = obcuState[id] ?? VALOnboardState()

                // 2. Uplink telegram from the wayside.
                let telegram = wayside.telegram(for: world.trains[index],
                                                occupancy: occupancy,
                                                world: world, now: now)

                // 3. OBCU scan (safety + drive/pupitre)...
                let request = onboard.scan(&world.trains[index], state: &state,
                                           telegram: telegram, world: world,
                                           controllerAlarm: controllerAlarm, dt: dt)

                // ...and the traction chain integrates the physics.
                traction.integrate(&world.trains[index], state: &state,
                                   request: request, dt: dt)

                updateAuxiliaries(&world.trains[index], dt: dt)
                obcuState[id] = state
            } else {
                deadReckon(&world.trains[index], dt: dt)
            }
        }

        // Drop OBCU state for withdrawn rames.
        let liveIds = Set(world.trains.map(\.id))
        obcuState = obcuState.filter { liveIds.contains($0.key) }

        sampleSystemAlarms(world: world)
        sampleTrainAlarms(world: world, at: now)
    }

    /// Dead-reckon a peer-owned rame between `.state` snapshots.
    private func deadReckon(_ train: inout Train, dt: Double) {
        guard train.speed > 0.01 else { return }
        train.position += train.speed * train.travelDirection.rawValue * dt
        train.position = train.position.truncatingRemainder(dividingBy: Sim.trackLength)
        if train.position < 0 { train.position += Sim.trackLength }
    }

    /// A latched SYS/CONTROLLER fault (PCC watchdog) freezes every local
    /// rame, like a controller-fault interlock in a real DCS.
    private func motionInhibitedByAlarm(world: MetroWorld) -> Bool {
        world.alarmLog.contains { $0.isActive && $0.source == "SYS" && $0.point == "CONTROLLER" }
    }

    // MARK: -- auxiliary telemetry (unchanged behaviour)

    /// Synthetic-but-plausible auxiliary telemetry so the synoptic and
    /// DCL SHOW RAME sheets read like a live TCMS. Traction electrics
    /// (line current, voltage, torque) are owned by VALTractionChain.
    private func updateAuxiliaries(_ train: inout Train, dt: Double) {
        let braking = train.acceleration < -0.05
        train.compressorPressure += (train.isCompressorRunning ? 0.08 : -0.01) * dt * 10
        if train.compressorPressure < 7.4 { train.isCompressorRunning = true }
        if train.compressorPressure > 9.0 { train.isCompressorRunning = false }
        train.compressorPressure = max(6.0, min(9.5, train.compressorPressure))

        // Static converter (CVS): ~112 V DC low-voltage bus while the
        // 750 V line is up; it sags if third-rail pickup collapses.
        train.cvsOutputVoltage = train.mainVoltage > 400
            ? 112.0 - (750 - train.mainVoltage) * 0.01
            : max(0, train.cvsOutputVoltage - 40 * dt)
        // Lighting circuit draw follows the lamps, DELESTAGE BT shedding,
        // and the KPH headlights.
        train.lightingCurrent = (train.areLightsOn
            ? (train.isLoadSheddingActive ? 5.0 : 15.0)
            : 0.0) + (train.pupitreKPH ? 2.0 : 0.0)
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

    // MARK: -- alarm sampling

    private func sampleSystemAlarms(world: MetroWorld) {
        switch world.lineMode {
        case .emergency:
            world.raiseAlarm(source: "SYS", point: "SAFETY_MODE", severity: .critical,
                             message: Strings.lookup("alarm.msg.emergency", lang: .en),
                             processDriven: true)
        case .serviceProvisoire:
            world.raiseAlarm(source: "SYS", point: "SAFETY_MODE", severity: .major,
                             message: Strings.lookup("alarm.msg.sp", lang: .en),
                             processDriven: true)
        case .normal, .stopped:
            world.clearAlarm(source: "SYS", point: "SAFETY_MODE")
        }

        // Switch routes: a switch off the through route (or cycling) bars
        // its zone -- standing minor alarm until the route is restored.
        for sw in wayside.switchTable(now: Date()) {
            let barred = sw.reversed || !sw.locked
            sample(world, sw.name, "ROUTE", barred, .minor, "alarm.msg.route")
        }
    }

    private func sampleTrainAlarms(world: MetroWorld, at now: Date) {
        // A node's SCADA only monitors the rames it OWNS. Remote rames are
        // the owning node's responsibility -- sampling their broadcast
        // state here would raise faults this node can't remediate.
        let localTrains = world.locallyOwned()
        let currentIds = Set(localTrains.map(\.id))
        doorOpenSince = doorOpenSince.filter { currentIds.contains($0.key) }
        slipHoldUntil = slipHoldUntil.filter { currentIds.contains($0.key) }
        slideHoldUntil = slideHoldUntil.filter { currentIds.contains($0.key) }

        for train in localTrains {
            let source = "RAME \(train.label)"
            let state = obcuState[train.id] ?? VALOnboardState()

            sample(world, source, "OVERSPEED", train.isOverspeed, .critical, "alarm.msg.overspeed")
            sample(world, source, "MA_LIMIT", train.isMAEncroached, .critical, "alarm.msg.malimit")
            sample(world, source, "FU", train.isEmergencyBrakeApplied, .major, "alarm.msg.fu")
            sample(world, source, "PORTES", train.isDoorFault, .critical, "alarm.msg.doorfault")
            sample(world, source, "TRACTION", train.isEngineFault, .major, "alarm.msg.enginefault")
            sample(world, source, "FREIN", train.isBrakeFault, .critical, "alarm.msg.brakefault")
            sample(world, source, "CTC_RADIO", train.isSignalFault, .major, "alarm.msg.signalfault")
            // Wheel slip/slide: the injected wet-patch flags OR the
            // adhesion model actually losing the wheels. Debounced with a
            // return-to-normal hold: slip is intermittent by nature and
            // must not mint a fresh alarm row per flicker.
            sample(world, source, "PATINAGE",
                   held(train.isPatinage || state.traction.slipping,
                        id: train.id, in: &slipHoldUntil, now: now),
                   .advisory, "alarm.msg.patinage")
            sample(world, source, "ENRAYAGE",
                   held(train.isEnrayage || state.traction.sliding,
                        id: train.id, in: &slideHoldUntil, now: now),
                   .advisory, "alarm.msg.enrayage")
            // KACOP vigilance warning (manual driving, dead-man overdue).
            sample(world, source, "VIGILANCE", train.kacopWarning, .minor, "alarm.msg.kacop")
            // KIBS engaged: a vital loop is inhibited -- standing alarm
            // for as long as the bypass is in (ISA-18.2: bypasses alarm).
            sample(world, source, "KIBS", train.pupitreKIBS, .major, "alarm.msg.kibs")
            // AVP string health (DOT §3.5.2.15): each string alarms while
            // faulted; running degraded on one string under OR voting is
            // the discrepancy warning of §4.5.10.
            sample(world, source, "AVP_A", train.avpStringAFault, .major, "alarm.msg.avpfault")
            sample(world, source, "AVP_B", train.avpStringBFault, .major, "alarm.msg.avpfault")
            sample(world, source, "AVP_DISC",
                   train.avpStringAFault != train.avpStringBFault,
                   .minor, "alarm.msg.avpdisc")

            switch train.worstTire {
            case .ok:
                world.clearAlarm(source: source, point: "PNEU")
            case .lowPressure:
                world.raiseAlarm(source: source, point: "PNEU", severity: .minor,
                                 message: Strings.lookup("alarm.msg.tirelow", lang: .en), processDriven: true)
            case .puncture:
                world.raiseAlarm(source: source, point: "PNEU", severity: .major,
                                 message: Strings.lookup("alarm.msg.tirepuncture", lang: .en), processDriven: true)
            case .burst:
                world.raiseAlarm(source: source, point: "PNEU", severity: .critical,
                                 message: Strings.lookup("alarm.msg.tireburst", lang: .en), processDriven: true)
            }

            let full = Double(train.passengerCount) >= Double(Sim.paxCapacity) * 0.8
            sample(world, source, "PAX_LOAD", full, .advisory, "alarm.msg.paxfull")

            // Doors held open past the dwell in normal running -- a platform
            // obstruction or a stuck door leaf.
            let shouldTrack = train.doorsOpen && world.lineMode != .emergency
            if shouldTrack {
                let since = doorOpenSince[train.id] ?? now
                doorOpenSince[train.id] = since
                if now.timeIntervalSince(since) > Sim.dwellMax + 6.0 && !train.isDepartureHold {
                    world.raiseAlarm(source: source, point: "DOOR_OPEN", severity: .minor,
                                     message: Strings.lookup("alarm.msg.doorheld", lang: .en), processDriven: true)
                } else {
                    world.clearAlarm(source: source, point: "DOOR_OPEN")
                }
            } else {
                doorOpenSince.removeValue(forKey: train.id)
                world.clearAlarm(source: source, point: "DOOR_OPEN")
            }
        }
    }

    /// Off-delay a boolean condition: true refreshes the hold; the result
    /// stays true until the hold has fully expired.
    private func held(_ condition: Bool, id: UUID,
                      in holds: inout [UUID: Date], now: Date) -> Bool {
        if condition {
            holds[id] = now.addingTimeInterval(Self.adhesionAlarmHold)
            return true
        }
        if let until = holds[id] {
            if now < until { return true }
            holds.removeValue(forKey: id)
        }
        return false
    }

    /// Sample one process-driven point: raise while the condition holds,
    /// return-to-normal when it clears.
    private func sample(_ world: MetroWorld, _ source: String, _ point: String,
                        _ condition: Bool, _ severity: AlarmSeverity, _ messageKey: String) {
        if condition {
            world.raiseAlarm(source: source, point: point, severity: severity,
                             message: Strings.lookup(messageKey, lang: .en), processDriven: true)
        } else {
            world.clearAlarm(source: source, point: point)
        }
    }
}
