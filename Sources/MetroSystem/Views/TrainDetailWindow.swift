import SwiftUI

/// A dedicated per-rame status screen, opened from the PCC dispatcher
/// (double-click a train card's DETAIL button). Mirrors the DC CBTC
/// "train detail" TCMS synoptic in the retro VT320 phosphor aesthetic: a
/// live gauge cluster (speed dial with the asservissement setpoint needle,
/// movement-authority bar, passenger and traction meters), the diagnostic
/// status sections, the ATP / chaîne-de-sécurité contact block, the
/// auxiliary readouts, and the eight VAL tires drawn as two bogies of
/// circular pressure gauges. Exploitation controls (doors, FU, mode) route
/// through the peer link so a REMOTE rame is drivable; fault injection and
/// tire cycling stay owner-only.
struct TrainDetailWindow: View {
    let trainId: UUID
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var network: PeerNetwork

    var body: some View {
        ZStack {
            RetroTheme.bg.ignoresSafeArea()
            if let train = world.trains.first(where: { $0.id == trainId }) {
                content(train)
            } else {
                signalLost
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .environment(\.colorScheme, .dark)
        .navigationTitle(language.t("window.traindetail"))
    }

    private var signalLost: some View {
        VStack(spacing: 12) {
            Text("▲")
                .font(.custom(RetroTheme.retroFontName, size: 48))
                .foregroundColor(.red)
            Text(language.t("detail.signallost"))
                .font(RetroTheme.monoLg)
                .foregroundColor(.red)
                .retroGlow()
        }
    }

    private func content(_ train: Train) -> some View {
        let isLocal = world.canControl(train)
        return ScrollView {
            VStack(spacing: 14) {
                DetailBanner(train: train, isLocal: isLocal)
                GaugeCluster(train: train)
                // Two rows of diagnostic sections.
                HStack(alignment: .top, spacing: 14) {
                    AsservissementSection(train: train)
                    TractionSection(train: train)
                    ExploitationSection(train: train)
                }
                HStack(alignment: .top, spacing: 14) {
                    ATPSection(train: train)
                    AuxiliarySection(train: train)
                }
                PneumaticsSection(train: train, editable: isLocal)
                DiagnosticFooter(train: train)
            }
            .padding(18)
        }
    }
}

// MARK: - Banner

private struct DetailBanner: View {
    let train: Train
    let isLocal: Bool
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var world: MetroWorld

    var body: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock.string(from: context.date))
                    .font(RetroTheme.monoLg)
                    .foregroundColor(RetroTheme.green)
                    .retroGlow()
            }
            Spacer()
            VStack(spacing: 0) {
                Text("\(language.t("train.rame")) \(train.label)")
                    .font(RetroTheme.monoXl)
                    .foregroundColor(RetroTheme.amber)
                    .retroGlow()
                Text(language.t("detail.subtitle"))
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
            }
            Spacer()
            Text(isLocal ? language.t("train.tag.local") : language.t("train.tag.remote"))
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.bg)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isLocal ? RetroTheme.amber : RetroTheme.green)
        }
        .padding(10)
        .overlay(Rectangle().stroke(RetroTheme.amber, lineWidth: 1))
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

// MARK: - Gauge cluster

private struct GaugeCluster: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        HStack(spacing: 14) {
            CircularGauge(value: train.speed,
                          maxValue: Sim.lineSpeed * 1.2,
                          needle: train.consigneVitesse,
                          caption: language.t("detail.gauge.speed"),
                          readout: String(format: "%.1f", train.speed),
                          unit: "m/s",
                          subReadout: String(format: "%@ %.1f", language.t("detail.gauge.consigne"), train.consigneVitesse),
                          color: speedColor)
            VStack(spacing: 14) {
                BarMeter(value: train.distanceToMA,
                         maxValue: Sim.trackLength / 2,
                         caption: language.t("detail.gauge.ma"),
                         readout: String(format: "%.0f m", train.distanceToMA),
                         warn: train.distanceToMA < Sim.safetyMargin,
                         color: RetroTheme.cyan)
                BarMeter(value: Double(train.passengerCount),
                         maxValue: Double(Sim.paxCapacity),
                         caption: language.t("detail.gauge.pax"),
                         readout: "\(train.passengerCount) / \(Sim.paxCapacity)",
                         warn: train.passengerCount >= Int(Double(Sim.paxCapacity) * 0.8),
                         color: RetroTheme.green)
            }
            CircularGauge(value: train.tractionCurrent,
                          maxValue: 1500,
                          needle: nil,
                          caption: language.t("detail.gauge.traction"),
                          readout: String(format: "%.0f", train.tractionCurrent),
                          unit: "A",
                          subReadout: String(format: "%.0f V", train.mainVoltage),
                          color: RetroTheme.amberBright)
        }
    }

    private var speedColor: Color {
        if train.isEmergencyBrakeApplied { return .red }
        return train.speed > 0.5 ? RetroTheme.green : RetroTheme.amberDim
    }
}

/// A 270° arc gauge with an optional setpoint needle (used for the
/// speed dial's asservissement consigne).
private struct CircularGauge: View {
    let value: Double
    let maxValue: Double
    let needle: Double?
    let caption: String
    let readout: String
    let unit: String
    var subReadout: String? = nil
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(caption)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amberDim)
            ZStack {
                Canvas { ctx, size in
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let radius = min(rect.width, rect.height) / 2
                    let start = Angle(degrees: 135)
                    let sweep = 270.0
                    // Track.
                    var track = Path()
                    track.addArc(center: center, radius: radius,
                                 startAngle: start,
                                 endAngle: start + Angle(degrees: sweep),
                                 clockwise: false)
                    ctx.stroke(track, with: .color(RetroTheme.amberDim.opacity(0.35)), lineWidth: 6)
                    // Value.
                    let frac = max(0, min(1, value / maxValue))
                    var arc = Path()
                    arc.addArc(center: center, radius: radius,
                               startAngle: start,
                               endAngle: start + Angle(degrees: sweep * frac),
                               clockwise: false)
                    ctx.stroke(arc, with: .color(color), lineWidth: 6)
                    // Setpoint needle.
                    if let needle {
                        let nf = max(0, min(1, needle / maxValue))
                        let a = (start + Angle(degrees: sweep * nf)).radians
                        let p1 = CGPoint(x: center.x + cos(a) * (radius - 10),
                                         y: center.y + sin(a) * (radius - 10))
                        let p2 = CGPoint(x: center.x + cos(a) * (radius + 4),
                                         y: center.y + sin(a) * (radius + 4))
                        var np = Path(); np.move(to: p1); np.addLine(to: p2)
                        ctx.stroke(np, with: .color(RetroTheme.cyan), lineWidth: 2)
                    }
                }
                .frame(width: 132, height: 132)
                VStack(spacing: 0) {
                    Text(readout)
                        .font(RetroTheme.monoLg)
                        .foregroundColor(color)
                        .retroGlow()
                    Text(unit)
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                    if let subReadout {
                        Text(subReadout)
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.cyan)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .overlay(Rectangle().stroke(RetroTheme.amber.opacity(0.5), lineWidth: 1))
    }
}

/// A horizontal bar meter with a caption and numeric readout.
private struct BarMeter: View {
    let value: Double
    let maxValue: Double
    let caption: String
    let readout: String
    var warn: Bool = false
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(caption)
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                Spacer()
                Text(readout)
                    .font(RetroTheme.mono)
                    .foregroundColor(warn ? .red : color)
                    .retroGlow()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(RetroTheme.amberDim.opacity(0.25))
                    Rectangle()
                        .fill(warn ? Color.red : color)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, value / maxValue))))
                }
            }
            .frame(height: 12)
            .overlay(Rectangle().stroke(RetroTheme.amber.opacity(0.5), lineWidth: 1))
        }
        .padding(8)
        .overlay(Rectangle().stroke(RetroTheme.amber.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Diagnostic sections

/// A labelled row: text + a small square indicator lit when `active`.
private struct IndicatorRow: View {
    let label: String
    let active: Bool
    var color: Color = RetroTheme.green

    var body: some View {
        HStack {
            Text(label)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
            Spacer()
            Rectangle()
                .fill(active ? color : Color.clear)
                .overlay(Rectangle().stroke(color, lineWidth: 1))
                .frame(width: 9, height: 9)
        }
    }
}

/// A labelled row: text + a value string.
private struct ValueRow: View {
    let label: String
    let value: String
    var color: Color = RetroTheme.amberBright

    var body: some View {
        HStack {
            Text(label)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
            Spacer()
            Text(value)
                .font(RetroTheme.monoSm)
                .foregroundColor(color)
        }
    }
}

private struct AsservissementSection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        BoxPanel(title: language.t("detail.sec.asserv"), accent: RetroTheme.cyan) {
            VStack(alignment: .leading, spacing: 6) {
                ValueRow(label: language.t("detail.asserv.consigne"),
                         value: String(format: "%.2f m/s", train.consigneVitesse))
                ValueRow(label: language.t("detail.asserv.error"),
                         value: String(format: "%+.2f", train.speedError))
                ValueRow(label: language.t("detail.asserv.accel"),
                         value: String(format: "%+.2f m/s²", train.acceleration))
                ValueRow(label: language.t("detail.asserv.dist"),
                         value: String(format: "%.1f m", train.distanceToMA),
                         color: train.distanceToMA < Sim.safetyMargin ? .red : RetroTheme.amberBright)
                ValueRow(label: language.t("detail.asserv.target"),
                         value: String(format: "%.1f m/s", train.targetSpeed))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct TractionSection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        BoxPanel(title: language.t("detail.sec.traction"), accent: RetroTheme.amber) {
            VStack(alignment: .leading, spacing: 6) {
                ValueRow(label: language.t("detail.traction.current"),
                         value: String(format: "%.0f A", train.tractionCurrent))
                ValueRow(label: language.t("detail.traction.torque"),
                         value: String(format: "%+.0f %%", train.tractionTorque),
                         color: train.tractionTorque >= 0 ? RetroTheme.green : RetroTheme.cyan)
                IndicatorRow(label: language.t("detail.traction.motoring"),
                             active: train.acceleration > 0.05, color: RetroTheme.green)
                IndicatorRow(label: language.t("detail.traction.braking"),
                             active: train.acceleration < -0.05, color: RetroTheme.amber)
                IndicatorRow(label: language.t("detail.traction.fu"),
                             active: train.isEmergencyBrakeApplied, color: .red)
                IndicatorRow(label: language.t("fault.patinage"),
                             active: train.isPatinage, color: .red)
                IndicatorRow(label: language.t("fault.enrayage"),
                             active: train.isEnrayage, color: .red)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ExploitationSection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var world: MetroWorld
    var body: some View {
        BoxPanel(title: language.t("detail.sec.exploit"), accent: RetroTheme.green) {
            VStack(alignment: .leading, spacing: 6) {
                ValueRow(label: language.t("btn.mode.label"),
                         value: train.mode == .auto ? language.t("train.mode.cai") : language.t("train.mode.cml"),
                         color: train.mode == .manual ? RetroTheme.cyan : RetroTheme.green)
                ValueRow(label: language.t("train.doors"),
                         value: train.doorsOpen ? language.t("door.open") : language.t("door.closed"),
                         color: train.doorsOpen ? RetroTheme.green : RetroTheme.amberDim)
                ValueRow(label: language.t("train.canton"),
                         value: world.canton(at: train.position).map { language.t("block.name", $0.id) } ?? "--")
                ValueRow(label: language.t("train.next"),
                         value: train.nextStationName, color: RetroTheme.cyan)
                ValueRow(label: language.t("train.pax"),
                         value: "\(train.passengerCount) / \(Sim.paxCapacity)")
                IndicatorRow(label: language.t("detail.exploit.dwell"),
                             active: train.isDwelling, color: RetroTheme.amber)
                IndicatorRow(label: language.t("detail.exploit.hold"),
                             active: train.isDepartureHold, color: RetroTheme.cyan)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The ATP / chaîne-de-sécurité contact block: each contact lit green when
/// closed / healthy (the same predicates the Modbus DI block exposes).
private struct ATPSection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var world: MetroWorld
    var body: some View {
        let chain = world.safetyChain(for: train)
        return BoxPanel(title: language.t("detail.sec.atp"),
                        accent: chain.intact ? RetroTheme.green : .red) {
            VStack(alignment: .leading, spacing: 6) {
                contact(language.t("detail.atp.doorlock"), chain.doorInterlock)
                contact(language.t("detail.atp.overspeed"), chain.overspeedOK)
                contact(language.t("detail.atp.ma"), chain.maMarginOK)
                contact(language.t("detail.atp.brake"), chain.brakeOK)
                contact(language.t("detail.atp.adhesion"), chain.adhesionOK)
                HRule(RetroTheme.amberDim)
                contact(language.t("detail.atp.chain"), chain.intact)
                IndicatorRow(label: language.t("fault.ctc"),
                             active: train.isSignalFault, color: .red)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // A safety contact reads healthy=green closed square, faulted=red open.
    private func contact(_ label: String, _ healthy: Bool) -> some View {
        HStack {
            Text(label)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
            Spacer()
            Text(healthy ? language.t("detail.atp.ok") : language.t("detail.atp.open"))
                .font(RetroTheme.monoSm)
                .foregroundColor(healthy ? RetroTheme.green : .red)
            Rectangle()
                .fill(healthy ? RetroTheme.green : Color.clear)
                .overlay(Rectangle().stroke(healthy ? RetroTheme.green : .red, lineWidth: 1))
                .frame(width: 9, height: 9)
        }
    }
}

private struct AuxiliarySection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        BoxPanel(title: language.t("detail.sec.aux"), accent: RetroTheme.amber) {
            VStack(alignment: .leading, spacing: 6) {
                ValueRow(label: language.t("detail.aux.mainv"),
                         value: String(format: "%.0f V", train.mainVoltage))
                ValueRow(label: language.t("detail.aux.battery"),
                         value: String(format: "%.1f V", train.batteryVoltage))
                ValueRow(label: language.t("detail.aux.compressor"),
                         value: String(format: "%.1f bar", train.compressorPressure))
                IndicatorRow(label: language.t("detail.aux.comprun"),
                             active: train.isCompressorRunning, color: RetroTheme.green)
                ValueRow(label: language.t("detail.aux.temp"),
                         value: String(format: "%.0f °C", train.interiorTemperature))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Pneumatics graphic

private struct PneumaticsSection: View {
    let train: Train
    let editable: Bool
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var world: MetroWorld

    var body: some View {
        BoxPanel(title: language.t("detail.sec.pneu"), accent: RetroTheme.amber) {
            HStack(spacing: 24) {
                bogie(language.t("detail.bogie1"), tires: train.tires.filter { $0.id <= 4 })
                Rectangle().fill(RetroTheme.amberDim).frame(width: 1)
                bogie(language.t("detail.bogie2"), tires: train.tires.filter { $0.id > 4 })
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func bogie(_ title: String, tires: [Train.Tire]) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(RetroTheme.mono)
                .foregroundColor(RetroTheme.amberDim)
            HStack(spacing: 16) {
                ForEach(tires) { tire in
                    TireGauge(tire: tire, editable: editable) {
                        world.mutate(train.id) { $0.cycleTireStatus(at: tire.id - 1) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single VAL tire as a circular pressure gauge, coloured by status and
/// (when local) clickable to cycle OK → low → puncture → burst.
private struct TireGauge: View {
    let tire: Train.Tire
    let editable: Bool
    let onCycle: () -> Void
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        Button(action: { if editable { onCycle() } }) {
            VStack(spacing: 3) {
                Text(String(format: language.t("detail.tire.n"), tire.id))
                    .font(RetroTheme.monoSm)
                    .foregroundColor(color)
                ZStack {
                    Circle().stroke(color, lineWidth: 3).frame(width: 62, height: 62)
                    // Fill proportion of the ring by pressure (0..9 bar).
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(1, tire.pressure / Sim.tireNominalBar))))
                        .stroke(color.opacity(0.55), lineWidth: 3)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 62, height: 62)
                    VStack(spacing: 0) {
                        Text(String(format: "%.1f", tire.pressure))
                            .font(RetroTheme.mono)
                            .foregroundColor(color)
                        Text("bar")
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                    }
                }
                Text(statusName)
                    .font(RetroTheme.monoSm)
                    .foregroundColor(color)
            }
            .padding(6)
            .overlay(Rectangle().stroke(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!editable)
    }

    private var statusName: String {
        switch tire.status {
        case .ok:          return language.t("train.tire.ok")
        case .lowPressure: return language.t("train.tire.low")
        case .puncture:    return language.t("train.tire.puncture")
        case .burst:       return language.t("train.tire.burst")
        }
    }

    private var color: Color {
        switch tire.status {
        case .ok:          return RetroTheme.green
        case .lowPressure: return RetroTheme.amber
        case .puncture:    return RetroTheme.amberBright
        case .burst:       return .red
        }
    }
}

// MARK: - Diagnostic footer

private struct DiagnosticFooter: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.t("detail.diag.traction.label"))
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                Text(tractionDiag)
                    .font(RetroTheme.mono)
                    .foregroundColor(tractionOK ? RetroTheme.green : .red)
                    .retroGlow()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(language.t("detail.diag.auto.label"))
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                Text(autoDiag)
                    .font(RetroTheme.mono)
                    .foregroundColor(autoOK ? RetroTheme.green : .red)
                    .retroGlow()
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { HRule(RetroTheme.amber) }
    }

    private var tractionOK: Bool {
        !(train.isEngineFault || train.isBrakeFault || train.isEmergencyBrakeApplied)
    }
    private var tractionDiag: String {
        if train.isEngineFault { return language.t("detail.diag.traction.engine") }
        if train.isBrakeFault { return language.t("detail.diag.traction.brake") }
        if train.isEmergencyBrakeApplied { return language.t("detail.diag.traction.fu") }
        return language.t("detail.diag.ras")
    }

    private var autoOK: Bool {
        !(train.mode == .manual || train.isSignalFault || train.isDoorFault || train.status == .emergency)
    }
    private var autoDiag: String {
        if train.mode == .manual { return language.t("detail.diag.auto.manual") }
        if train.isSignalFault { return language.t("detail.diag.auto.signal") }
        if train.isDoorFault { return language.t("detail.diag.auto.door") }
        if train.status == .emergency { return language.t("detail.diag.auto.estop") }
        return language.t("detail.diag.auto.nominal")
    }
}
