import Foundation
import Combine

/// The hardware output stage: samples the simulation at
/// `Sim.hardwareOutputHz` and mirrors every LOCALLY-OWNED rame onto a
/// physical model layout through the selected RameHardwareDriver.
/// Structurally it is the same shape as `MetroWorld.tick()`'s output pass
/// -- read the process image, write the output image -- just pointed at a
/// command station instead of the on-screen panels.
///
/// One bridge per process (like the telnet port and the Modbus slave), so
/// it is a main-actor singleton: the DCL verbs, the bootstrap wiring and
/// any future panel indicator all talk to `HardwareBridge.shared`.
///
/// Safety posture (hobby-grade, but taken seriously):
///  * The output is DISABLED at every launch; the driver/endpoint/mapping
///    persist, the arming does not. SET HARDWARE /ENABLE re-arms.
///  * DISABLE, disconnect and driver swap all send the driver's stopAll.
///  * A rame under FU / arret d'urgence produces an emergencyStop frame,
///    which drivers map to their protocol's vital stop.
///  * A failed link while the output is armed raises a SYS/HW_LINK SCADA
///    alarm (process-driven: it returns to normal when the link does).
@MainActor
final class HardwareBridge: ObservableObject {
    static let shared = HardwareBridge()

    @Published private(set) var config: HardwareConfig
    /// Output gate: frames flow only while this is on AND the link is
    /// ready. Never persisted -- see the safety posture above.
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var linkState: HardwareLinkState = .disconnected
    @Published private(set) var framesSent: Int = 0
    /// Newest-first ring of recent layout sensor events, for SHOW HARDWARE.
    @Published private(set) var sensorLog: [HardwareSensorEvent] = []

    private(set) var driver: RameHardwareDriver?
    private weak var world: MetroWorld?
    private var timer: Timer?
    /// Last frame sent per hardware unit -- the change detector. A full
    /// refresh goes out every `Sim.hardwareRefreshInterval` regardless, so
    /// a command station that missed a frame converges anyway.
    private var lastSent: [Int: RameActuation] = [:]
    private var lastFullRefresh: Date = .distantPast

    private init() {
        config = Self.loadConfig() ?? HardwareConfig()
        instantiateDriver(id: config.driverId)
    }

    /// Wire the world and start the output scan. Called once from
    /// bootstrap(), after the world itself has started.
    func attach(world: MetroWorld) {
        self.world = world
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / Sim.hardwareOutputHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.outputScan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: -- operator surface (the SET HARDWARE verb calls these)

    var registry: HardwareDriverRegistry { HardwareDriverRegistry.shared }

    /// Descriptor of the currently selected driver (for display).
    var selectedDescriptor: HardwareDriverDescriptor? {
        registry.descriptor(for: config.driverId)
    }

    @discardableResult
    func selectDriver(id: String) -> Bool {
        guard registry.descriptor(for: id) != nil else { return false }
        instantiateDriver(id: id)
        config.driverId = registry.descriptor(for: id)?.id ?? id.uppercased()
        persistConfig()
        return true
    }

    func setEndpoint(host: String?, port: UInt16?) {
        if let host { config.host = host }
        if let port { config.port = port }
        persistConfig()
    }

    @discardableResult
    func setSpeedScale(_ scale: Double) -> Bool {
        guard scale >= 0.05, scale <= 2.0 else { return false }
        config.speedScale = scale
        persistConfig()
        return true
    }

    func setResync(_ on: Bool) {
        config.resyncEnabled = on
        persistConfig()
    }

    /// Map a rame label to a hardware unit; nil clears the mapping (the
    /// rame falls back to its numeric label).
    func setUnitMapping(label: String, unit: Int?) {
        if let unit {
            config.unitMap[label] = unit
        } else {
            config.unitMap.removeValue(forKey: label)
        }
        persistConfig()
    }

    @discardableResult
    func connect() -> Bool {
        guard let driver else { return false }
        lastSent.removeAll()
        driver.connect(config: config)
        return true
    }

    func disconnect() {
        guard let driver else { return }
        if driver.state.isReady { driver.stopAll() }
        driver.disconnect()
        lastSent.removeAll()
    }

    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        guard driver != nil else { return false }
        if isEnabled == on { return true }
        isEnabled = on
        if on {
            // Force a full frame set on the first armed scan.
            lastSent.removeAll()
            lastFullRefresh = .distantPast
        } else if let driver, driver.state.isReady {
            driver.stopAll()
        }
        refreshLinkAlarm()
        return true
    }

    @discardableResult
    func setTrackPower(_ on: Bool) -> Bool {
        guard let driver, driver.state.isReady else { return false }
        return driver.setTrackPower(on)
    }

    // MARK: -- driver lifecycle

    private func instantiateDriver(id: String) {
        if let old = driver {
            if old.state.isReady { old.stopAll() }
            old.disconnect()
            old.onStateChange = nil
            old.onSensorEvent = nil
        }
        lastSent.removeAll()
        guard let descriptor = registry.descriptor(for: id) else {
            driver = nil
            linkState = .disconnected
            return
        }
        let fresh = descriptor.makeDriver()
        fresh.onStateChange = { [weak self] st in self?.linkStateChanged(st) }
        fresh.onSensorEvent = { [weak self] ev in self?.handleSensor(ev) }
        driver = fresh
        linkState = fresh.state
    }

    private func linkStateChanged(_ state: HardwareLinkState) {
        linkState = state
        if state.isReady {
            // Fresh link: resend the whole picture on the next scan.
            lastSent.removeAll()
            lastFullRefresh = .distantPast
        }
        refreshLinkAlarm()
    }

    /// SYS/HW_LINK: raised while the output is armed but the link is
    /// down/failed, returned-to-normal when the link is healthy or the
    /// output is stood down (ISA-18.2 process-driven semantics).
    private func refreshLinkAlarm() {
        guard let world else { return }
        let unhealthy = isEnabled && !linkState.isReady
        if unhealthy {
            world.raiseAlarm(source: "SYS", point: "HW_LINK", severity: .major,
                             message: Strings.lookup("alarm.msg.hwlink", lang: .en),
                             processDriven: true)
        } else {
            world.clearAlarm(source: "SYS", point: "HW_LINK")
        }
    }

    // MARK: -- output scan

    private func outputScan() {
        guard let world, let driver, isEnabled, driver.state.isReady else { return }
        // Under the PRATIC hardware backend the physical trains drive
        // themselves -- mirroring the supervision picture back onto the
        // track would fight the real autopilot.
        guard BackendManager.shared.kind != .praticHardware else { return }
        let now = Date()
        let fullRefresh = now.timeIntervalSince(lastFullRefresh) >= Sim.hardwareRefreshInterval

        var frames: [RameActuation] = []
        var liveUnits = Set<Int>()
        for train in world.locallyOwned() {
            guard let frame = actuation(for: train, world: world) else { continue }
            liveUnits.insert(frame.unit)
            if fullRefresh || lastSent[frame.unit] != frame {
                frames.append(frame)
                lastSent[frame.unit] = frame
            }
        }
        // A withdrawn rame must not keep rolling: stop any unit we drove
        // before that no longer has a rame behind it.
        for (unit, previous) in lastSent where !liveUnits.contains(unit) {
            var stop = previous
            stop.speedSteps = 0
            stop.emergencyStop = true
            frames.append(stop)
            lastSent.removeValue(forKey: unit)
        }
        if fullRefresh { lastFullRefresh = now }

        guard !frames.isEmpty else { return }
        driver.apply(frames)
        framesSent += frames.count
    }

    /// Translate one rame's simulated state into its output frame, or nil
    /// when the rame resolves to no usable hardware unit.
    private func actuation(for train: Train, world: MetroWorld) -> RameActuation? {
        guard let unit = config.unit(forLabel: train.label) else { return nil }
        let emergency = train.isEmergencyBrakeApplied
            || world.isEmergencyStopped
            || train.status == .emergency
        var steps = 0
        if !emergency && !train.doorsOpen {
            let throttle = (train.speed / Sim.lineSpeed) * config.speedScale
            steps = Int((min(1.0, max(0.0, throttle)) * Double(Sim.hardwareSpeedSteps)).rounded())
        }
        return RameActuation(unit: unit,
                             label: train.label,
                             speedSteps: steps,
                             forward: train.travelDirection == .forward,
                             emergencyStop: emergency,
                             doorsOpen: train.doorsOpen,
                             lightsOn: train.areLightsOn)
    }

    // MARK: -- layout feedback

    private func handleSensor(_ event: HardwareSensorEvent) {
        sensorLog.insert(event, at: 0)
        if sensorLog.count > Sim.hardwareSensorLogDepth {
            sensorLog.removeLast(sensorLog.count - Sim.hardwareSensorLogDepth)
        }
        guard config.resyncEnabled, event.active, let world,
              (1...Sim.cantonCount).contains(event.sensorId) else { return }
        // Sensor n marks canton n's entry boundary. Snap the nearest
        // locally-owned rame -- if one is within a canton's length -- so the
        // simulated position tracks where the physical train actually is.
        let boundary = Double(event.sensorId - 1) * Sim.cantonLength
        let candidates = world.locallyOwned()
        guard let nearest = candidates.min(by: {
            loopDistance($0.position, boundary) < loopDistance($1.position, boundary)
        }), loopDistance(nearest.position, boundary) <= Sim.cantonLength else { return }
        world.mutate(nearest.id) { $0.position = boundary }
    }

    private func loopDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, Sim.trackLength - d)
    }

    // MARK: -- config persistence

    /// JSON sidecar next to the COM store:
    /// ~/Library/Application Support/MetroSystem/HARDWARE.JSON
    private static func configURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MetroSystem", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("HARDWARE.JSON")
    }

    private static func loadConfig() -> HardwareConfig? {
        guard let data = try? Data(contentsOf: configURL()) else { return nil }
        return try? JSONDecoder().decode(HardwareConfig.self, from: data)
    }

    private func persistConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: Self.configURL(), options: .atomic)
    }
}
