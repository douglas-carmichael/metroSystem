import SwiftUI

/// Standalone VT320-style window that mirrors `MONITOR DYNAMICS` from the
/// DCL shell so a viewer can watch the asservissement speed regulation
/// without dropping into the terminal. Samples every 500 ms; tracks the
/// prior-tick speed per rame so the displayed acceleration follows the
/// traction command between refreshes.
struct DynamicsMonitorWindow: View {
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    @State private var rows: [Row] = []
    @State private var lastVelocity: [UUID: Double] = [:]
    @State private var lastSample: Date = Date()
    @State private var lastUpdate: Date = Date()
    @State private var velocityHistory: [UUID: [Double]] = [:]

    // Per-rame checklist: we track the rames the user has explicitly
    // HIDDEN rather than shown, so a newly added rame appears by default
    // instead of staying invisible until manually enabled.
    @State private var hidden: Set<UUID> = []

    // 60-second rolling window at 500 ms sample rate -> 120 slots; the
    // trace anchors the newest sample to the right edge so it reads
    // like a commissioning-tool scope rather than a left-to-right
    // history that wanders off the screen as the buffer fills.
    private static let traceCapacity: Int = 120

    // Window-local fonts: the global RetroTheme.mono/monoSm are tuned
    // for dense panels (control panel, alarm table); this window is
    // viewed from further back during a demo, so the table and labels
    // get bumped up a tier without affecting the rest of the app. Like
    // RetroTheme they follow the active skin: the VT323 bitmap face under
    // retro, the system monospace (at slightly smaller sizes) under ISA-101.
    private static var bodyFont: Font {
        switch RetroTheme.kind {
        case .retro:  return Font.custom(RetroTheme.retroFontName, size: 19, relativeTo: .body)
        case .iso101: return Font.system(size: 15, design: .monospaced)
        }
    }
    private static var smallFont: Font {
        switch RetroTheme.kind {
        case .retro:  return Font.custom(RetroTheme.retroFontName, size: 16, relativeTo: .footnote)
        case .iso101: return Font.system(size: 12.5, design: .monospaced)
        }
    }
    private static var titleFont: Font {
        switch RetroTheme.kind {
        case .retro:  return Font.custom(RetroTheme.retroFontName, size: 26, relativeTo: .title3)
        case .iso101: return Font.system(size: 20, weight: .semibold, design: .monospaced)
        }
    }

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                header
                selectionControls
                tableHeader
                Rectangle()
                    .fill(RetroTheme.amberDim)
                    .frame(height: 1)
                if rows.isEmpty {
                    Text(language.t("dynamics.empty"))
                        .font(Self.bodyFont)
                        .foregroundColor(RetroTheme.greenDim)
                    Spacer(minLength: 0)
                } else {
                    // Scroll the rame table so a full fleet doesn't crush
                    // the speed trace below it; the table takes whatever
                    // vertical space is left after the fixed trace + footers.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                }
                Spacer().frame(height: 8)
                velocityTrace
                Spacer().frame(height: 8)
                profileFooter
                statusBar
            }
            .padding(20)
        }
        // Minimum matches the window's default size (see .defaultSize in the
        // app): the table columns and trace stop being legible below this, so
        // the window opens at its minimum and only grows.
        .frame(minWidth: 900, minHeight: 900)
        .id(language.themeKind)
        .environment(\.colorScheme, language.themeKind == .retro ? .dark : .light)
        .navigationTitle(language.t("window.dynamics"))
        .onAppear { sample() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                sample()
            }
        }
    }

    // MARK: - Sampling

    private struct Row: Identifiable {
        let id: UUID
        let label: String
        let position: Double
        let velocity: Double        // signed: + forward, - reverse
        let consigne: Double
        let accel: Double
        let ma: Double
        let state: String
        let isManual: Bool
    }

    /// Rames the user hasn't hidden -- the ones actually plotted.
    private func visibleTrains() -> [Train] {
        world.sortedTrains.filter { !hidden.contains($0.id) }
    }

    private func sample() {
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastSample))
        let trains = visibleTrains()
        let computed: [Row] = trains.map { train in
            let prev = lastVelocity[train.id] ?? train.signedSpeed
            return Row(id: train.id,
                       label: train.label,
                       position: train.position,
                       velocity: train.signedSpeed,
                       consigne: train.consigneVitesse,
                       accel: (train.signedSpeed - prev) / dt,
                       ma: train.distanceToMA,
                       state: Self.state(for: train),
                       isManual: train.mode == .manual)
        }
        rows = computed
        lastVelocity = Dictionary(uniqueKeysWithValues:
                                    trains.map { ($0.id, $0.signedSpeed) })
        lastSample = now
        lastUpdate = now

        for train in trains {
            var buf = velocityHistory[train.id, default: []]
            buf.append(train.signedSpeed)
            if buf.count > Self.traceCapacity {
                buf.removeFirst(buf.count - Self.traceCapacity)
            }
            velocityHistory[train.id] = buf
        }
        let currentIds = Set(trains.map(\.id))
        velocityHistory = velocityHistory.filter { currentIds.contains($0.key) }
    }

    // MARK: - Subviews

    private var header: some View {
        Text(language.t("dynamics.title"))
            .font(Self.titleFont)
            .foregroundColor(RetroTheme.amber)
            .retroGlow()
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // Per-rame checklist chips; each highlights when the rame is plotted.
    private var selectionControls: some View {
        let candidates = world.sortedTrains
        return HStack(alignment: .top, spacing: 8) {
            Text(language.t("dynamics.select.label"))
                .font(Self.smallFont)
                .foregroundColor(RetroTheme.amberDim)
                .padding(.top, 4)
            if candidates.isEmpty {
                Text(language.t("dynamics.select.empty"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.greenDim)
                    .padding(.top, 4)
            } else {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    RetroButton(language.t("dynamics.select.all")) {
                        hidden.subtract(candidates.map(\.id))
                        sample()
                    }
                    RetroButton(language.t("dynamics.select.none")) {
                        hidden.formUnion(candidates.map(\.id))
                        sample()
                    }
                    ForEach(candidates) { train in
                        let visible = !hidden.contains(train.id)
                        RetroButton(train.label,
                                    highlighted: visible) {
                            if visible { hidden.insert(train.id) } else { hidden.remove(train.id) }
                            sample()
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            headerCell(language.t("dynamics.col.rame"),     width: 80)
            headerCell(language.t("dynamics.col.pos"),      width: 130)
            headerCell(language.t("dynamics.col.vel"),      width: 150)
            headerCell(language.t("dynamics.col.consigne"), width: 120)
            headerCell(language.t("dynamics.col.acc"),      width: 110)
            headerCell(language.t("dynamics.col.ma"),       width: 110)
            headerCell(language.t("dynamics.col.state"), width: nil)
        }
    }

    private func headerCell(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(Self.bodyFont)
            .foregroundColor(RetroTheme.amberDim)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            cell(row.label, width: 80,
                 color: row.isManual ? RetroTheme.cyan : RetroTheme.green)
            cell(String(format: "%6.1f m", row.position), width: 130,
                 color: RetroTheme.amberBright)
            cell(String(format: "%+6.2f m/s", row.velocity), width: 150,
                 color: velocityColor(row.velocity))
            cell(String(format: "%5.2f", row.consigne), width: 120,
                 color: RetroTheme.amber)
            cell(String(format: "%+5.2f", row.accel), width: 110,
                 color: accelColor(row.accel))
            cell(String(format: "%6.0f m", row.ma), width: 110,
                 color: row.ma < Sim.safetyMargin ? RetroTheme.red : RetroTheme.amber)
            cell(language.t("dynamics.state.\(row.state)"), width: nil,
                 color: stateColor(row.state))
        }
    }

    private func cell(_ text: String, width: CGFloat?, color: Color) -> some View {
        Text(text)
            .font(Self.bodyFont)
            .foregroundColor(color)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private var velocityTrace: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text(language.t("dynamics.trace.title"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.amberDim)
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(traceColor(for: idx))
                            .frame(width: 8, height: 8)
                        Text(row.label)
                            .font(Self.smallFont)
                            .foregroundColor(RetroTheme.amberDim)
                    }
                }
                Spacer()
                Text(language.t("dynamics.trace.axis"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.amberDim)
            }
            Canvas { context, size in
                drawTrace(context: context, size: size)
            }
            .frame(height: 140)
            .background(RetroTheme.bg)
            .overlay(
                Rectangle()
                    .stroke(RetroTheme.amberDim, lineWidth: 1)
            )
            if velocityHistory.values.allSatisfy({ $0.count < 2 }) {
                Text(language.t("dynamics.trace.empty"))
                    .font(Self.smallFont)
                    .foregroundColor(RetroTheme.greenDim)
            }
        }
    }

    private static let tracePalette: [Color] = [
        RetroTheme.green,
        RetroTheme.cyan,
        RetroTheme.amberBright,
        .red,
        RetroTheme.greenDim,
    ]

    private func traceColor(for index: Int) -> Color {
        Self.tracePalette[index % Self.tracePalette.count]
    }

    // Scope-style speed-vs-time plot. Y-axis is symmetric around zero
    // (reverse running under a service provisoire plots below the axis)
    // with the line speed marked as a dashed limit; X-axis is
    // `traceCapacity` slots, newest sample anchored to the right edge.
    private func drawTrace(context: GraphicsContext, size: CGSize) {
        let maxSpeed = Sim.lineSpeed * 1.15
        let midY = size.height / 2
        let yScale = midY / CGFloat(maxSpeed)

        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: midY))
        zero.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(zero,
                       with: .color(RetroTheme.amberDim),
                       lineWidth: 0.5)

        let dy = CGFloat(Sim.lineSpeed) * yScale
        for y in [midY - dy, midY + dy] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(p,
                           with: .color(RetroTheme.amberDim.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }

        let totalSlots = max(1, Self.traceCapacity - 1)
        let xStep = size.width / CGFloat(totalSlots)

        for (idx, row) in rows.enumerated() {
            guard let history = velocityHistory[row.id], history.count > 1 else { continue }
            let startSlot = Self.traceCapacity - history.count
            var path = Path()
            for (i, v) in history.enumerated() {
                let x = CGFloat(startSlot + i) * xStep
                let y = midY - CGFloat(v) * yScale
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path,
                           with: .color(traceColor(for: idx)),
                           lineWidth: 1.2)
        }
    }

    private var profileFooter: some View {
        Text(String(format: language.t("dynamics.profile.fmt"),
                    Sim.lineSpeed, Sim.maxAcceleration,
                    Sim.nominalBraking, Sim.emergencyBraking))
            .font(Self.smallFont)
            .foregroundColor(RetroTheme.amberDim)
    }

    private var statusBar: some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return HStack {
            Text(language.t("dynamics.refresh"))
                .font(Self.smallFont)
                .foregroundColor(RetroTheme.amberDim)
            Spacer()
            Text(fmt.string(from: lastUpdate))
                .font(Self.smallFont)
                .foregroundColor(RetroTheme.green)
        }
    }

    // MARK: - Coloring

    private func velocityColor(_ v: Double) -> Color {
        if abs(v) < 0.05 { return RetroTheme.amberDim }
        return v > 0 ? RetroTheme.green : RetroTheme.cyan
    }

    private func accelColor(_ a: Double) -> Color {
        if abs(a) < 0.05 { return RetroTheme.amberDim }
        return a > 0 ? RetroTheme.amberBright : RetroTheme.amber
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "accel":             return RetroTheme.amberBright
        case "cruise":            return RetroTheme.green
        case "decel":             return RetroTheme.amber
        case "stopping", "dwell": return RetroTheme.amberDim
        case "hold":              return RetroTheme.cyan
        case "manual":            return RetroTheme.cyan
        case "eb":                return RetroTheme.red
        case "idle":              return RetroTheme.greenDim
        default:                  return RetroTheme.amber
        }
    }

    // Mirror of DCLEngine.dynamicsState(for:) so the panel reads the same
    // regimes as MONITOR DYNAMICS in the shell. Returns a key suffix; the
    // row localizes it via "dynamics.state.<key>".
    private static func state(for train: Train) -> String {
        if train.isEmergencyBrakeApplied || train.status == .emergency { return "eb" }
        if train.doorsOpen { return "dwell" }
        if train.isDepartureHold { return "hold" }
        if train.mode == .manual { return "manual" }
        if train.status == .stopped { return train.speed > 0.05 ? "stopping" : "idle" }
        let cruising = train.speed >= train.consigneVitesse * 0.95 && train.consigneVitesse > 0.5
        if train.speedError < -0.3 { return "decel" }
        if cruising                { return "cruise" }
        return "accel"
    }
}
