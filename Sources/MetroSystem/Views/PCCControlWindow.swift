import SwiftUI
import AppKit

/// The PCC (poste de commande centralisé) dispatcher panel: line-wide
/// controls, the SCADA alarm annunciator, and one control panel per rame.
/// Remote rames (owned by another node or a ClusterDaemon peer) render
/// with a REMOTE tag: exploitation controls (doors, FU, mode, manual
/// speed) forward over the peer link; physical-condition controls (fault
/// injection, tires, withdraw) stay owner-only and are hidden.
struct PCCControlWindow: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var telnet: DCLTelnetServer
    @EnvironmentObject var modbus: ModbusTCPServer
    @Environment(\.openWindow) private var openWindow

    @State private var focusedTrainId: UUID?
    @State private var showHelp: Bool = false
    @State private var showCredits: Bool = false
    @State private var showModbusLegend: Bool = false

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()
            KeyboardHost(onKey: handleKey)
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)
            VStack(spacing: 14) {
                BannerHeader()
                StatusStrip()
                LineControlPanel()
                SCADAAlarmPanel()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(world.sortedTrains) { train in
                            TrainPanel(train: train,
                                       focused: focusedTrainId == train.id)
                        }
                    }
                    .padding(.top, 8)
                }
                FooterBar(showCredits: $showCredits)
            }
            .padding(20)
            if showHelp {
                HelpOverlay(onDismiss: { showHelp = false })
                    .transition(.opacity)
            }
            if showCredits {
                CreditsOverlay(onDismiss: { showCredits = false })
                    .transition(.opacity)
            }
            if showModbusLegend {
                ModbusLegendOverlay(onDismiss: { showModbusLegend = false })
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .id(language.themeKind)
        .environment(\.colorScheme, language.themeKind == .retro ? .dark : .light)
        .navigationTitle(language.t("window.control"))
        .onAppear {
            ensureFocus()
            // Demo / screenshot affordances: `-openDetail` auto-pops the
            // first train's detail window shortly after launch; `-openScene`
            // does the same for the 3D line synoptic.
            if ProcessInfo.processInfo.arguments.contains("-openDetail") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if let first = world.sortedTrains.first {
                        openWindow(id: "train-detail", value: first.id)
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-openScene") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    openWindow(id: "scene")
                }
            }
        }
        .onChange(of: world.trains.map(\.id)) { ensureFocus() }
    }

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdShift: NSEvent.ModifierFlags = [.command, .option, .control]
        guard mods.intersection(cmdShift).isEmpty else { return ev }

        if ev.keyCode == KeyCode.escape {
            if showHelp { showHelp = false; return nil }
            if showCredits { showCredits = false; return nil }
            if showModbusLegend { showModbusLegend = false; return nil }
            return ev
        }
        if ev.keyCode == KeyCode.f1 {
            showHelp.toggle()
            return nil
        }
        if ev.keyCode == KeyCode.tab {
            cycleFocus()
            return nil
        }

        let chars = (ev.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "?":
            showHelp.toggle()
            return nil
        case "l":
            language.cycle()
            return nil
        case "q":
            NSApp.terminate(nil)
            return nil
        case "d":
            openWindow(id: "dcl", value: DCLSessionID())
            return nil
        case "s":
            openWindow(id: "scene")
            return nil
        case "y":
            openWindow(id: "dynamics")
            return nil
        case "m":
            showModbusLegend.toggle()
            return nil
        case "a":
            toggleFocusedMode()
            return nil
        case "o":
            controlFocused(.openDoors)
            return nil
        case "c":
            controlFocused(.closeDoors)
            return nil
        case "f":
            toggleFocusedFU()
            return nil
        case "e":
            world.emergencyStopAll(!world.isEmergencyStopped)
            return nil
        default:
            break
        }
        return ev
    }

    /// Rames the keyboard focus ring walks: anything we can drive --
    /// locally owned, or remote with a live link to its owner. Same order
    /// the panels render in, so TAB advances visually.
    private func controllableTrains() -> [Train] {
        world.sortedTrains.filter { network.canControl($0) }
    }

    private func ensureFocus() {
        let trains = controllableTrains()
        if let id = focusedTrainId, trains.contains(where: { $0.id == id }) { return }
        focusedTrainId = trains.first?.id
    }

    private func cycleFocus() {
        let trains = controllableTrains()
        guard !trains.isEmpty else { focusedTrainId = nil; return }
        if let id = focusedTrainId, let idx = trains.firstIndex(where: { $0.id == id }) {
            focusedTrainId = trains[(idx + 1) % trains.count].id
        } else {
            focusedTrainId = trains.first?.id
        }
    }

    private func controlFocused(_ kind: TrainCommandKind, value: Double? = nil) {
        guard let id = focusedTrainId,
              let train = world.trains.first(where: { $0.id == id }) else { return }
        _ = network.control(train, kind, value: value)
    }

    private func toggleFocusedMode() {
        guard let id = focusedTrainId,
              let train = world.trains.first(where: { $0.id == id }) else { return }
        _ = network.control(train, train.mode == .auto ? .modeManual : .modeAuto)
    }

    private func toggleFocusedFU() {
        guard let id = focusedTrainId,
              let train = world.trains.first(where: { $0.id == id }) else { return }
        _ = network.control(train, train.isEmergencyBrakeApplied ? .fuRelease : .fuSet)
    }
}

private struct BannerHeader: View {
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        VStack(spacing: 2) {
            Text("*** \(language.t("banner.title")) ***")
                .font(RetroTheme.monoXl)
                .foregroundColor(RetroTheme.amber)
                .retroGlow()
            Text(language.t("banner.subtitle"))
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberDim)
            Text(language.t("banner.copyright"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .overlay(Rectangle().stroke(RetroTheme.amber, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            RetroButton("\(language.t("theme.label")): \(language.t(language.themeKind == .retro ? "theme.retro" : "theme.iso"))",
                        highlighted: language.themeKind == .iso101) {
                language.toggleTheme()
            }
            .padding(6)
        }
    }
}

private struct StatusStrip: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var telnet: DCLTelnetServer
    @EnvironmentObject var modbus: ModbusTCPServer

    var body: some View {
        // A wrapping FlowLayout keeps the strip on one line when there's room
        // but wraps onto additional lines when the window is narrow — so every
        // field stays visible even at the minimum window size.
        FlowLayout(horizontalSpacing: 18, verticalSpacing: 4) {
            StatusLine(label: language.t("status.node"),
                       value: world.localPeerLabel,
                       valueColor: RetroTheme.cyan)
            StatusLine(label: language.t("status.peers"),
                       value: peersValue,
                       valueColor: network.peers.isEmpty ? RetroTheme.amberDim : RetroTheme.green)
            StatusLine(label: language.t("status.rames"),
                       value: "\(world.trains.count)",
                       valueColor: RetroTheme.amberBright)
            StatusLine(label: language.t("status.telnet"),
                       value: telnetValue,
                       valueColor: telnet.sessionCount == 0 ? RetroTheme.amberDim : RetroTheme.green)
            StatusLine(label: language.t("status.modbus"),
                       value: modbusValue,
                       valueColor: modbus.displayedClientCount == 0 ? RetroTheme.amberDim : RetroTheme.green)
            StatusLine(label: language.t("status.mode"),
                       value: modeValue,
                       valueColor: modeColor)
            StatusLine(label: language.t("status.alarms"),
                       value: alarmValue,
                       valueColor: alarmColor)
            StatusLine(label: "STAT",
                       value: language.t("status.ready"),
                       valueColor: RetroTheme.green)
            BlinkingCursor()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var peersValue: String {
        let count = network.peers.count
        switch count {
        case 0:  return language.t("status.peers.none")
        case 1:  return "1 \(language.t("status.peers.node"))"
        default: return "\(count) \(language.t("status.peers.nodes"))"
        }
    }

    private var telnetValue: String {
        let count = telnet.sessionCount
        switch count {
        case 0:  return language.t("status.telnet.none")
        case 1:  return language.t("status.telnet.one")
        default: return String(format: language.t("status.telnet.many"), count)
        }
    }

    private var modbusValue: String {
        let count = modbus.displayedClientCount
        switch count {
        case 0:  return language.t("status.modbus.none")
        case 1:  return language.t("status.modbus.one")
        default: return String(format: language.t("status.modbus.many"), count)
        }
    }

    private var modeValue: String {
        switch world.lineMode {
        case .stopped:           return language.t("status.mode.stopped")
        case .normal:            return language.t("status.mode.normal")
        case .serviceProvisoire: return language.t("status.mode.sp")
        case .emergency:         return language.t("status.mode.emergency")
        }
    }

    private var modeColor: Color {
        switch world.lineMode {
        case .normal:            return RetroTheme.green
        case .stopped:           return RetroTheme.amberDim
        case .serviceProvisoire: return RetroTheme.cyan
        case .emergency:         return .red
        }
    }

    private var alarmValue: String {
        let active = world.activeAlarms.count
        let unack = world.unacknowledgedAlarmCount
        return active == 0
            ? language.t("status.alarms.normal")
            : String(format: language.t("status.alarms.summary"), active, unack)
    }

    private var alarmColor: Color {
        guard let severity = world.highestActiveSeverity else { return RetroTheme.green }
        switch severity {
        case .advisory: return RetroTheme.cyan
        case .minor: return RetroTheme.amber
        case .major: return RetroTheme.amberBright
        case .critical: return .red
        }
    }
}

/// Line-wide exploitation controls: service on/off, arrêt d'urgence
/// général, fleet management and the service provisoire configurator.
private struct LineControlPanel: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    @State private var spFrom: Int = 1
    @State private var spTo: Int = 3
    @State private var spInterval: Double = 60

    var body: some View {
        BoxPanel(title: language.t("line.panel.title"), accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RetroButton(language.t("line.service.start"),
                                enabled: !world.isRunning || world.isEmergencyStopped,
                                highlighted: world.isRunning && !world.isEmergencyStopped) {
                        if world.isEmergencyStopped { world.emergencyStopAll(false) }
                        world.startService()
                    }
                    RetroButton(language.t("line.service.stop"),
                                enabled: world.isRunning) {
                        world.stopService()
                    }
                    RetroButton(language.t("line.emergency"),
                                highlighted: world.isEmergencyStopped) {
                        world.emergencyStopAll(!world.isEmergencyStopped)
                    }
                    Spacer()
                    RetroButton(language.t("line.addtrain"),
                                enabled: world.locallyOwned().count < Sim.maxTrainCount) {
                        _ = world.addTrain()
                    }
                }
                HStack(spacing: 8) {
                    Text("\(language.t("line.sp.label")):")
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                        .lineLimit(1)
                        .fixedSize()
                    stationPicker(language.t("line.sp.from"), selection: $spFrom)
                    stationPicker(language.t("line.sp.to"), selection: $spTo)
                    HStack(spacing: 4) {
                        Text("\(language.t("line.sp.interval")):")
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                            .lineLimit(1)
                            .fixedSize()
                        ForEach([30.0, 60.0, 120.0], id: \.self) { value in
                            RetroButton("\(Int(value))s", highlighted: spInterval == value) {
                                spInterval = value
                            }
                        }
                    }
                    RetroButton(language.t("line.sp.engage"),
                                enabled: spFrom != spTo,
                                highlighted: world.activeSP != nil) {
                        world.setServiceProvisoire(ServiceProvisoire(
                            startStationId: spFrom,
                            endStationId: spTo,
                            intervalle: spInterval))
                    }
                    RetroButton(language.t("line.sp.clear"),
                                enabled: world.activeSP != nil) {
                        world.setServiceProvisoire(nil)
                    }
                    Spacer()
                }
                if let sp = world.activeSP {
                    Text(String(format: language.t("line.sp.active"),
                                world.stationName(id: sp.startStationId),
                                world.stationName(id: sp.endStationId),
                                Int(sp.intervalle)))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.cyan)
                }
            }
        }
    }

    private func stationPicker(_ label: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
                .lineLimit(1)
                .fixedSize()
            Menu {
                ForEach(world.stations) { station in
                    Button("\(station.id)  \(station.name)") {
                        selection.wrappedValue = station.id
                    }
                }
            } label: {
                Text(world.stationName(id: selection.wrappedValue))
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(Rectangle().stroke(RetroTheme.amber, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var accent: Color {
        switch world.lineMode {
        case .normal:            return RetroTheme.green
        case .stopped:           return RetroTheme.amberDim
        case .serviceProvisoire: return RetroTheme.cyan
        case .emergency:         return .red
        }
    }
}

private struct SCADAAlarmPanel: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage
    @State private var injectorTask: Task<Void, Never>? = nil

    var body: some View {
        BoxPanel(title: language.t("alarm.panel.title"), accent: panelAccent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    StatusLine(label: language.t("alarm.active"),
                               value: "\(world.activeAlarms.count)",
                               valueColor: panelAccent)
                    StatusLine(label: language.t("alarm.unack"),
                               value: "\(world.unacknowledgedAlarmCount)",
                               valueColor: world.unacknowledgedAlarmCount == 0 ? RetroTheme.green : RetroTheme.amberBright)
                    Spacer()
                    RetroButton(language.t("alarm.inject"), highlighted: isInjecting) {
                        toggleInjector()
                    }
                    RetroButton(language.t("alarm.ack.all"), enabled: world.unacknowledgedAlarmCount > 0) {
                        _ = world.acknowledgeAllAlarms()
                    }
                    RetroButton(language.t("alarm.clear.all"), enabled: world.hasClearableAlarms) {
                        _ = world.clearAllActiveAlarms()
                    }
                }
                HStack(spacing: 8) {
                    failureButton("CTRL", source: "SYS", point: "CONTROLLER", severity: .major, messageKey: "alarm.msg.controller")
                    failureButton("PWR", source: "PWR", point: "TRACTION_750V", severity: .critical, messageKey: "alarm.msg.power")
                    failureButton("TRACK", source: "TRACK", point: "TRACK_CIRCUIT", severity: .major, messageKey: "alarm.msg.track")
                    failureButton("PLATFORM", source: "PLATFORM", point: "PLATFORM_DOOR", severity: .minor, messageKey: "alarm.msg.platform")
                    RetroButton(language.t("alarm.clear.ack"), enabled: world.hasClearableAcknowledgedAlarms) {
                        _ = world.clearAcknowledgedActiveAlarms()
                    }
                }
                alarmTable
            }
        }
        .onDisappear {
            injectorTask?.cancel()
            injectorTask = nil
        }
    }

    private var isInjecting: Bool { injectorTask != nil }

    private func toggleInjector() {
        if let t = injectorTask {
            t.cancel()
            injectorTask = nil
            return
        }
        injectorTask = Task { @MainActor in
            // Brief grace period so a quick toggle doesn't fire instantly.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !Task.isCancelled {
                injectRandomAlarm()
                let delaySec = Double.random(in: 4.0...10.0)
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
    }

    private struct InjectorPick {
        let source: String
        let point: String
        let severity: AlarmSeverity
        let messageKey: String
        let weight: Int
    }

    // Weighted pool: advisory + minor entries dominate so the SCADA log
    // reads like a routine day; major/critical picks are rare so the
    // operator spends most of their time working ack/clear muscle memory
    // and only occasionally has to think about a service-affecting page.
    // Nothing auto-resolves -- the operator drives every raise -> ACK ->
    // CLEAR cycle, which is the whole point of the panel.
    private static let injectorPool: [InjectorPick] = [
        .init(source: "SYS",  point: "CONTROLLER",    severity: .major,    messageKey: "alarm.msg.controller", weight: 1),
        .init(source: "PWR",  point: "TRACTION_750V", severity: .critical, messageKey: "alarm.msg.power",      weight: 1),
        .init(source: "TRACK",    point: "TRACK_CIRCUIT",    severity: .major,    messageKey: "alarm.msg.track",       weight: 2),
        .init(source: "PLATFORM", point: "PLATFORM_DOOR",    severity: .minor,    messageKey: "alarm.msg.platform",    weight: 5),
        .init(source: "RAME",     point: "CTC_RADIO",        severity: .major,    messageKey: "alarm.msg.signalfault", weight: 2),
        .init(source: "PLATFORM", point: "PLATFORM_DISPLAY", severity: .advisory, messageKey: "alarm.msg.display",     weight: 6),
        .init(source: "TRACK",    point: "TRACK_SWITCH",     severity: .minor,    messageKey: "alarm.msg.switch",      weight: 4),
    ]

    private static let weightedPool: [InjectorPick] = injectorPool.flatMap {
        Array(repeating: $0, count: max(1, $0.weight))
    }

    private func injectRandomAlarm() {
        guard let pick = Self.weightedPool.randomElement() else { return }
        let resolvedSource: String
        if pick.source == "RAME" {
            // Bind rame faults to a locally-owned rame -- remote rames are
            // the owning node's SCADA responsibility.
            if let train = world.locallyOwned().randomElement() {
                resolvedSource = "RAME \(train.label)"
            } else {
                resolvedSource = "RAME FLEET"
            }
        } else if pick.source == "PLATFORM" || pick.source == "TRACK" {
            // Bind platform / track faults to a real station or canton so
            // the row reads like a located field fault.
            if pick.source == "PLATFORM", let station = world.stations.randomElement() {
                resolvedSource = "PLATFORM \(station.id)"
            } else if let canton = world.cantons.randomElement() {
                resolvedSource = "TRACK C\(canton.id)"
            } else {
                resolvedSource = pick.source
            }
        } else {
            resolvedSource = pick.source
        }
        // Skip if an identical alarm is already active so the injector
        // creates new rows instead of stacking duplicates on one point.
        let dup = world.activeAlarms.contains {
            $0.source == resolvedSource && $0.point == pick.point
        }
        if dup { return }
        _ = world.raiseAlarm(source: resolvedSource,
                             point: pick.point,
                             severity: pick.severity,
                             message: Strings.lookup(pick.messageKey, lang: .en))
    }

    private var alarmTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                header(language.t("alarm.col.id"), width: 42)
                header(language.t("alarm.col.sev"), width: 84)
                header(language.t("alarm.col.state"), width: 88)
                header(language.t("alarm.col.source"), width: 96)
                header(language.t("alarm.col.point"), width: 130)
                header(language.t("alarm.col.message"), width: nil)
            }
            HRule(RetroTheme.amberDim)
            if world.activeAlarms.isEmpty {
                Text(language.t("alarm.none.active"))
                    .font(RetroTheme.mono)
                    .foregroundColor(RetroTheme.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(world.activeAlarms.prefix(5))) { alarm in
                    AlarmRow(alarm: alarm)
                }
            }
        }
    }

    private func failureButton(_ label: String, source: String, point: String, severity: AlarmSeverity, messageKey: String) -> some View {
        let active = world.activeAlarms.contains { $0.source == source && $0.point == point }
        return RetroButton(label, highlighted: active) {
            if active {
                _ = world.clearAlarm(source: source, point: point)
            } else {
                _ = world.raiseAlarm(source: source, point: point, severity: severity, message: Strings.lookup(messageKey, lang: .en))
            }
        }
    }

    private func header(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(RetroTheme.monoSm)
            .foregroundColor(RetroTheme.amberDim)
            .frame(width: width, alignment: .leading)
    }

    private var panelAccent: Color {
        guard let severity = world.highestActiveSeverity else { return RetroTheme.green }
        switch severity {
        case .advisory: return RetroTheme.cyan
        case .minor: return RetroTheme.amber
        case .major: return RetroTheme.amberBright
        case .critical: return .red
        }
    }
}

private struct AlarmRow: View {
    let alarm: SCADAAlarm
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 0) {
            cell(String(format: "%04d", alarm.sequence), width: 42, color: RetroTheme.amberBright)
            cell(localizedSeverity, width: 84, color: severityColor)
            cell(localizedStatus, width: 88, color: alarm.isAcknowledged ? RetroTheme.green : RetroTheme.amberBright)
            cell(alarm.source, width: 96, color: RetroTheme.cyan)
            cell(alarm.point, width: 130, color: RetroTheme.amber)
            Text(localizedMessage)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
                .lineLimit(1)
            Spacer(minLength: 8)
            RetroButton(language.t("alarm.ack"), enabled: !alarm.isAcknowledged) {
                _ = world.acknowledgeAlarm(sequence: alarm.sequence)
            }
        }
    }

    private func cell(_ text: String, width: CGFloat, color: Color) -> some View {
        Text(text)
            .font(RetroTheme.monoSm)
            .foregroundColor(color)
            .frame(width: width, alignment: .leading)
    }

    private var severityColor: Color {
        switch alarm.severity {
        case .advisory: return RetroTheme.cyan
        case .minor: return RetroTheme.amber
        case .major: return RetroTheme.amberBright
        case .critical: return .red
        }
    }

    private var localizedSeverity: String {
        switch alarm.severity {
        case .advisory: return language.t("alarm.sev.advisory")
        case .minor: return language.t("alarm.sev.minor")
        case .major: return language.t("alarm.sev.major")
        case .critical: return language.t("alarm.sev.critical")
        }
    }

    private var localizedStatus: String {
        if alarm.clearedAt != nil { return language.t("alarm.status.cleared") }
        return alarm.isAcknowledged ? language.t("alarm.status.ack") : language.t("alarm.status.unack")
    }

    private var localizedMessage: String {
        for key in Strings.alarmMessageKeys {
            if alarm.message == Strings.lookup(key, lang: .en) { return language.t(key) }
        }
        return alarm.message
    }
}

private struct TrainPanel: View {
    let train: Train
    let focused: Bool
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage
    @Environment(\.openWindow) private var openWindow

    private var isLocal: Bool { world.canControl(train) }

    var body: some View {
        BoxPanel(title: titleLine, accent: titleAccent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    StatusLine(label: language.t("train.canton"),
                               value: world.canton(at: train.position).map { language.t("block.name", $0.id) } ?? "--",
                               valueColor: RetroTheme.amberBright)
                    StatusLine(label: language.t("train.speed"),
                               value: String(format: "%5.1f m/s", train.speed),
                               valueColor: speedColor)
                    StatusLine(label: language.t("train.ma"),
                               value: String(format: "%5.0f m", train.distanceToMA),
                               valueColor: train.distanceToMA < Sim.safetyMargin ? .red : RetroTheme.green)
                    StatusLine(label: language.t("train.doors"),
                               value: train.doorsOpen ? language.t("door.open") : language.t("door.closed"),
                               valueColor: train.doorsOpen ? RetroTheme.green : RetroTheme.amberDim)
                    StatusLine(label: language.t("train.pax"),
                               value: "\(train.passengerCount)/\(Sim.paxCapacity)",
                               valueColor: paxColor)
                    Spacer()
                    if focused {
                        Text("◀ \(language.t("help.focus.hint"))")
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.green)
                            .retroGlow()
                    }
                }
                HStack(spacing: 24) {
                    StatusLine(label: language.t("train.next"),
                               value: train.nextStationName,
                               valueColor: RetroTheme.cyan)
                    StatusLine(label: language.t("train.status"),
                               value: statusString,
                               valueColor: statusColor)
                    // VAL fixed-block telemetry: received speed program,
                    // and the trip cause while the FU is in. Mnemonics are
                    // firmware identifiers, shared across both languages.
                    if let program = VALSpeedProgram(rawValue: train.speedProgram) {
                        StatusLine(label: language.t("train.program"),
                                   value: program.mnemonic,
                                   valueColor: program == .perturbed ? RetroTheme.amberBright : RetroTheme.green)
                        if train.isEmergencyBrakeApplied,
                           let cause = VALTripCause(rawValue: train.ebCause), cause != .none {
                            StatusLine(label: language.t("train.ebcause"),
                                       value: cause.mnemonic,
                                       valueColor: .red)
                        }
                    }
                    if !faultString.isEmpty {
                        StatusLine(label: language.t("train.faults"),
                                   value: faultString,
                                   valueColor: .red)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    DoorControls(train: train)
                    ModeControls(train: train)
                    Spacer()
                    RetroButton(language.t("btn.detail")) {
                        openWindow(id: "train-detail", value: train.id)
                    }
                    RetroButton(language.t("btn.fu"),
                                enabled: network.canControl(train),
                                highlighted: train.isEmergencyBrakeApplied) {
                        _ = network.control(train, train.isEmergencyBrakeApplied ? .fuRelease : .fuSet)
                    }
                    if isLocal {
                        RetroButton(language.t("btn.remove")) {
                            world.removeTrain(id: train.id)
                        }
                    }
                }
                if train.mode == .manual && network.canControl(train) {
                    // Under the VAL backend, manual driving is the full
                    // console-A22 pupitre; the CBTC/PRATIC backends keep
                    // the plain speed-setpoint chips.
                    if train.speedProgram.isEmpty {
                        ManualSpeedControls(train: train)
                    } else {
                        PupitreControls(train: train)
                    }
                }
                // Physical-condition controls model the owning node's
                // rolling stock; they stay owner-only (the wire carries no
                // fault-injection commands, by design).
                if isLocal {
                    FaultControls(train: train)
                    TireStrip(train: train)
                }
            }
        }
        // Dim only a rame we genuinely can't drive (remote with no live
        // link to its owner).
        .opacity(network.canControl(train) ? 1.0 : 0.78)
    }

    private var titleLine: String {
        let mode = train.mode == .auto ? language.t("train.mode.cai") : language.t("train.mode.cml")
        let owner = isLocal ? language.t("train.tag.local") : language.t("train.tag.remote")
        return "\(language.t("train.rame")) \(train.label) [\(mode)] [\(owner)]"
    }

    private var titleAccent: Color {
        if train.isEmergencyBrakeApplied || train.status == .emergency { return .red }
        if !isLocal {
            return network.canControl(train) ? RetroTheme.green : RetroTheme.greenDim
        }
        return train.mode == .manual ? RetroTheme.cyan : RetroTheme.amber
    }

    private var speedColor: Color {
        train.speed > 0.5 ? RetroTheme.green : RetroTheme.amberDim
    }

    private var paxColor: Color {
        let ratio = Double(train.passengerCount) / Double(Sim.paxCapacity)
        if ratio >= 1.0 { return .red }
        if ratio >= 0.8 { return RetroTheme.amberBright }
        return RetroTheme.green
    }

    private var statusString: String {
        switch train.status {
        case .stopped:   return language.t("train.status.stopped")
        case .moving:    return language.t("train.status.moving")
        case .emergency: return language.t("train.status.emergency")
        case .docked:    return language.t("train.status.docked")
        }
    }

    private var statusColor: Color {
        switch train.status {
        case .moving:    return RetroTheme.green
        case .docked:    return RetroTheme.amber
        case .stopped:   return RetroTheme.amberDim
        case .emergency: return .red
        }
    }

    private var faultString: String {
        var faults: [String] = []
        if train.isDoorFault   { faults.append(language.t("fault.portes")) }
        if train.isEngineFault { faults.append(language.t("fault.traction")) }
        if train.isBrakeFault  { faults.append(language.t("fault.frein")) }
        if train.isSignalFault { faults.append(language.t("fault.ctc")) }
        if train.isPatinage    { faults.append(language.t("fault.patinage")) }
        if train.isEnrayage    { faults.append(language.t("fault.enrayage")) }
        return faults.joined(separator: " ")
    }
}

private struct DoorControls: View {
    let train: Train
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 10) {
            RetroButton(language.t("btn.door.open"),
                        enabled: network.canControl(train) && train.speed < 0.1 && !train.doorsOpen) {
                _ = network.control(train, .openDoors)
            }
            RetroButton(language.t("btn.door.close"),
                        enabled: network.canControl(train) && train.doorsOpen) {
                _ = network.control(train, .closeDoors)
            }
        }
    }
}

private struct ModeControls: View {
    let train: Train
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Text("\(language.t("btn.mode.label")):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            RetroButton(language.t("btn.mode.auto"),
                        enabled: network.canControl(train),
                        highlighted: train.mode == .auto) {
                guard train.mode != .auto else { return }
                _ = network.control(train, .modeAuto)
            }
            RetroButton(language.t("btn.mode.manual"),
                        enabled: network.canControl(train),
                        highlighted: train.mode == .manual) {
                guard train.mode != .manual else { return }
                _ = network.control(train, .modeManual)
            }
        }
    }
}

/// Manual-mode driver desk: speed setpoint chips 0..20 m/s. Routed through
/// the peer link so a remote rame's setpoint lands on its owning node.
private struct ManualSpeedControls: View {
    let train: Train
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Text("\(language.t("train.manual.speed")):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            ForEach([0.0, 3.0, 5.0, 8.0, 12.0, 16.0, 20.0], id: \.self) { value in
                RetroButton(String(format: "%.0f", value),
                            highlighted: abs(train.manualSpeedRequest - value) < 0.1) {
                    _ = network.control(train, .setSpeed, value: value)
                }
            }
            Text("m/s")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
        }
    }
}

/// Console A22 -- the pupitre de conduite manuelle, shown when a rame
/// under the VAL backend is in manual mode. KG / reverser / traction-
/// brake lever / KACOP route through the peer link like every other
/// exploitation control; the speed chips set the CML ceiling. Labels
/// KG, KACOP, AV/0/AR are real cab markings -- identical in both
/// languages.
private struct PupitreControls: View {
    let train: Train
    @EnvironmentObject var network: PeerNetwork
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(language.t("pupitre.title")):")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.cyan)
                RetroButton("KG", highlighted: train.pupitreKG) {
                    _ = network.control(train, .pupitreKG, value: train.pupitreKG ? 0 : 1)
                }
                Text("\(language.t("pupitre.reverser")):")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach([(1, "AV"), (0, "0"), (-1, "AR")], id: \.0) { value, label in
                    RetroButton(label, highlighted: train.pupitreReverser == value) {
                        _ = network.control(train, .pupitreReverser, value: Double(value))
                    }
                }
                RetroButton(kacopLabel, highlighted: train.kacopWarning) {
                    _ = network.control(train, .kacopAck)
                }
                if train.kacopWarning {
                    Text(language.t("pupitre.kacop.warning"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(.red)
                        .retroGlow()
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text("\(language.t("pupitre.lever")):")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach([(-100, "-100"), (-50, "-50"), (0, "0"), (25, "+25"),
                         (50, "+50"), (100, "+100")], id: \.0) { pct, label in
                    RetroButton(label,
                                highlighted: abs(train.pupitreLever * 100 - Double(pct)) < 5) {
                        _ = network.control(train, .pupitreLever, value: Double(pct) / 100.0)
                    }
                }
                Text("%")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                Text("\(language.t("train.manual.speed")):")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach([8.0, 12.0, 20.0], id: \.self) { value in
                    RetroButton(String(format: "%.0f", value),
                                highlighted: abs(train.manualSpeedRequest - value) < 0.1) {
                        _ = network.control(train, .setSpeed, value: value)
                    }
                }
                Spacer()
            }
        }
    }

    /// KACOP chip label with the vigilance countdown while it runs.
    private var kacopLabel: String {
        guard train.pupitreKG else { return "KACOP" }
        let remaining = max(0, Sim.kacopTripDelay - train.kacopSecondsSinceAck)
        return String(format: "KACOP %2.0f", remaining)
    }
}

/// Latched fault injection per rame -- each chip toggles one Train flag,
/// the physics reacts on the next scan, and the SCADA sampler raises the
/// matching alarm point. Owner-only (shown for local rames).
private struct FaultControls: View {
    let train: Train
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Text("\(language.t("train.faults.label")):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            faultChip(language.t("fault.portes"), isOn: train.isDoorFault)     { $0.isDoorFault.toggle() }
            faultChip(language.t("fault.traction"), isOn: train.isEngineFault) { $0.isEngineFault.toggle() }
            faultChip(language.t("fault.frein"), isOn: train.isBrakeFault)     { $0.isBrakeFault.toggle() }
            faultChip(language.t("fault.ctc"), isOn: train.isSignalFault)      { $0.isSignalFault.toggle() }
            faultChip(language.t("fault.patinage"), isOn: train.isPatinage)    { $0.isPatinage.toggle() }
            faultChip(language.t("fault.enrayage"), isOn: train.isEnrayage)    { $0.isEnrayage.toggle() }
            Spacer()
        }
    }

    private func faultChip(_ label: String, isOn: Bool, _ mutate: @escaping (inout Train) -> Void) -> some View {
        RetroButton(label, highlighted: isOn) {
            world.mutate(train.id, mutate)
        }
    }
}

/// The eight VAL tires; each chip cycles OK -> low pressure -> puncture ->
/// burst -> OK, and colors by severity. Owner-only.
private struct TireStrip: View {
    let train: Train
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Text("\(language.t("train.tires.label")):")
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            ForEach(Array(train.tires.enumerated()), id: \.element.id) { idx, tire in
                Button {
                    world.mutate(train.id) { $0.cycleTireStatus(at: idx) }
                } label: {
                    Text("\(tire.id)")
                        .font(RetroTheme.monoSm)
                        .foregroundColor(tireColor(tire.status))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(Rectangle().stroke(tireColor(tire.status), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("\(String(format: "%.1f", tire.pressure)) bar — \(tireName(tire.status))")
            }
            Text(language.t("train.tires.hint"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
        }
    }

    private func tireName(_ status: Train.Tire.TireStatus) -> String {
        switch status {
        case .ok:          return language.t("train.tire.ok")
        case .lowPressure: return language.t("train.tire.low")
        case .puncture:    return language.t("train.tire.puncture")
        case .burst:       return language.t("train.tire.burst")
        }
    }

    private func tireColor(_ status: Train.Tire.TireStatus) -> Color {
        switch status {
        case .ok:          return RetroTheme.green
        case .lowPressure: return RetroTheme.amber
        case .puncture:    return RetroTheme.amberBright
        case .burst:       return .red
        }
    }
}

private struct FooterBar: View {
    @Binding var showCredits: Bool
    @EnvironmentObject var language: AppLanguage
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Text(language.t("hint.line"))
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
            RetroButton(language.t("credits.title")) {
                showCredits = true
            }
            RetroButton(language.t("window.dcl")) {
                openWindow(id: "dcl", value: DCLSessionID())
            }
            RetroButton(language.t("window.scene")) {
                openWindow(id: "scene")
            }
            RetroButton(language.t("window.dynamics")) {
                openWindow(id: "dynamics")
            }
            HStack(spacing: 6) {
                Text("\(language.t("hint.lang")):")
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach(Lang.allCases) { lang in
                    RetroButton(lang.code,
                                highlighted: language.current == lang) {
                        language.current = lang
                    }
                }
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            HRule(RetroTheme.amber)
        }
    }
}

private struct HelpOverlay: View {
    let onDismiss: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        ZStack {
            RetroTheme.bg.opacity(0.85).ignoresSafeArea()
            BoxPanel(title: language.t("help.title"), accent: RetroTheme.green) {
                VStack(alignment: .leading, spacing: 8) {
                    row("F1  /  ?",  language.t("help.k.help"))
                    row("TAB",       language.t("help.k.tab"))
                    row("L",         language.t("help.k.lang"))
                    row("O  /  C",   language.t("help.k.doors"))
                    row("A",         language.t("help.k.mode"))
                    row("F",         language.t("help.k.fu"))
                    row("E",         language.t("help.k.emergency"))
                    row("M",         language.t("help.k.modbus"))
                    row("D",         language.t("help.k.dcl"))
                    row("S",         language.t("help.k.scene"))
                    row("Y",         language.t("help.k.dynamics"))
                    row("Q",         language.t("help.k.quit"))
                    row("ESC",       language.t("help.k.esc"))
                    Spacer().frame(height: 6)
                    Text(language.t("help.dismiss"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(width: 460)
            }
            .onTapGesture { onDismiss() }
        }
    }

    private func row(_ key: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberBright)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amber)
        }
    }
}

private struct CreditsOverlay: View {
    let onDismiss: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        ZStack {
            RetroTheme.bg.opacity(0.85).ignoresSafeArea()
            BoxPanel(title: language.t("credits.title"), accent: RetroTheme.cyan) {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        HRule(RetroTheme.cyan)
                        Text("MetroSystem")
                            .font(RetroTheme.monoXl)
                            .foregroundColor(RetroTheme.amberBright)
                            .retroGlow()
                        HRule(RetroTheme.cyan)
                    }

                    HRule(RetroTheme.amberDim)

                    VStack(alignment: .leading, spacing: 14) {
                        creditBlock(
                            role: language.t("credits.role.metro"),
                            name: "Douglas Carmichael",
                            email: "dcarmich@dcarmichael.net",
                            url: "github.com/douglas-carmichael/metroSystem"
                        )
                        creditBlock(
                            role: language.t("credits.role.retro"),
                            name: "elevatorSystem",
                            email: "Amaury Crocquefer / Douglas Carmichael",
                            url: "github.com/lapatatedouce59/elevatorSystem"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HRule(RetroTheme.amberDim)

                    Text(language.t("credits.dismiss"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                }
                .frame(width: 500)
            }
            .onTapGesture { onDismiss() }
        }
    }

    private func creditBlock(role: String, name: String, email: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.cyan)
            Text(name)
                .font(RetroTheme.monoLg)
                .foregroundColor(RetroTheme.amberBright)
                .retroGlow()
            Text(email)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amber)
            Text(url)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
        }
    }
}

/// Reference card for the Modbus TCP register map. Toggled with M --
/// designed so a viewer following along with `mbpoll` or QModMaster
/// can read what each register / coil offset means without diving
/// into the source. ESC, M again, or tap-anywhere dismisses.
private struct ModbusLegendOverlay: View {
    let onDismiss: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RetroTheme.bg.opacity(0.9).ignoresSafeArea()
                BoxPanel(title: language.t("modbus.legend.title"), accent: RetroTheme.cyan) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(language.t("modbus.legend.endpoint"))
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                        Spacer().frame(height: 4)

                        // Two columns: telemetry/setpoints on the left,
                        // command + status/safety-chain bits on the right.
                        // Scrolls if the window is too short to show it all.
                        ScrollView {
                            HStack(alignment: .top, spacing: 28) {
                                inputAndHoldingColumn
                                coilAndDiscreteColumn
                            }
                        }

                        Spacer().frame(height: 8)
                        Text(language.t("help.dismiss"))
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(width: min(828, geo.size.width - 80))
                }
                .frame(maxHeight: geo.size.height - 48)
                .onTapGesture { onDismiss() }
            }
        }
    }

    private func grp(_ g: Int) -> String {
        let n = ModbusTCPServer.maxTrains
        return "\(g * n)..\(g * n + n - 1)"
    }

    /// Left column: input registers (telemetry) + holding registers (setpoints).
    private var inputAndHoldingColumn: some View {
        let sb = ModbusTCPServer.scalarBase
        return VStack(alignment: .leading, spacing: 6) {
            section(language.t("modbus.legend.ir"))
            row(grp(0),  language.t("modbus.reg.position"))
            row(grp(1),  language.t("modbus.reg.speed"))
            row(grp(2),  language.t("modbus.reg.consigne"))
            row(grp(3),  language.t("modbus.reg.ma"))
            row(grp(4),  language.t("modbus.reg.pax"))
            row(grp(5),  language.t("modbus.reg.status"))
            row(grp(6),  language.t("modbus.reg.canton"))
            row(grp(7),  language.t("modbus.reg.tire"))
            row("\(sb+0)",  language.t("modbus.reg.traincount"))
            row("\(sb+1)",  language.t("modbus.reg.peers"))
            row("\(sb+2)",  language.t("modbus.reg.cantoncount"))
            row("\(sb+3)",  language.t("modbus.reg.telnet"))
            row("\(sb+4)",  language.t("modbus.reg.clients"))
            row("\(sb+5)",  language.t("modbus.reg.linemode"))
            row("\(sb+6)",  language.t("modbus.reg.spfrom"))
            row("\(sb+7)",  language.t("modbus.reg.spto"))
            row("\(sb+8)",  language.t("modbus.reg.spheadway"))
            row("\(sb+9)",  language.t("modbus.reg.alarms"))
            row("\(sb+10)", language.t("modbus.reg.severity"))
            row("\(sb+11)", language.t("modbus.reg.unack"))
            row("\(sb+12)", language.t("modbus.reg.shelved"))
            row("\(sb+13)", language.t("modbus.reg.rtn"))
            row("\(sb+14)", language.t("modbus.reg.tracklen"))

            Spacer().frame(height: 4)
            section(language.t("modbus.legend.hr"))
            row(grp(0), language.t("modbus.reg.mode"))
            row(grp(1), language.t("modbus.reg.setspeed"))
        }
        .frame(width: 400, alignment: .leading)
    }

    /// Right column: coils (commands) + discrete inputs (status + safety chain).
    private var coilAndDiscreteColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(language.t("modbus.legend.coil"))
            row(grp(0), language.t("modbus.reg.dooropen"))
            row(grp(1), language.t("modbus.reg.doorclose"))
            row(grp(2), language.t("modbus.reg.fuset"))
            row(grp(3), language.t("modbus.reg.furelease"))

            Spacer().frame(height: 4)
            section(language.t("modbus.legend.di"))
            row(grp(0), language.t("modbus.reg.local"))
            row(grp(1), language.t("modbus.reg.moving"))
            row(grp(2), language.t("modbus.reg.doorsopen"))
            row(grp(3), language.t("modbus.reg.fuapplied"))
            row(grp(4), language.t("modbus.reg.faultdoor"))
            row(grp(5), language.t("modbus.reg.faulttraction"))
            row(grp(6), language.t("modbus.reg.faultbrake"))
            row(grp(7), language.t("modbus.reg.faultctc"))
            row(grp(8), language.t("modbus.reg.faultslip"))
            row(grp(9), language.t("modbus.reg.faultslide"))
            // Chaîne de sécurité (1 = contact closed / healthy).
            section(language.t("modbus.legend.chain"))
            row(grp(10), language.t("modbus.chain.doorinterlock"))
            row(grp(11), language.t("modbus.chain.overspeed"))
            row(grp(12), language.t("modbus.chain.ma"))
            row(grp(13), language.t("modbus.chain.brake"))
            row(grp(14), language.t("modbus.chain.adhesion"))
            row(grp(15), language.t("modbus.chain.intact"))
        }
        .frame(width: 400, alignment: .leading)
    }

    private func section(_ text: String) -> some View {
        Text(text)
            .font(RetroTheme.mono)
            .foregroundColor(RetroTheme.cyan)
            .retroGlow()
    }

    private func row(_ addr: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(addr)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberBright)
                .frame(width: 88, alignment: .leading)
            Text(desc)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
        }
    }
}
