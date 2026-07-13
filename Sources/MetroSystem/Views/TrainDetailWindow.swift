import SwiftUI

/// A dedicated per-rame status screen, opened from the PCC dispatcher
/// (double-click a train card's DETAIL button). A "train detail" TCMS
/// synoptic in the retro VT320 phosphor aesthetic: a
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
        // Rebuild the whole subtree on a skin switch so every element — even
        // leaf gauges that don't observe AppLanguage — picks up the palette.
        .id(language.themeKind)
        .environment(\.colorScheme, language.themeKind == .retro ? .dark : .light)
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
                // Live bench strip (VAL backend): the chopper quantities
                // as meters, so the launch reads like an instrumented
                // run -- II pinned while MHI ramps, IL = MHI x II, the
                // line current swinging negative under regeneration.
                if !train.speedProgram.isEmpty {
                    TractionBenchSection(train: train)
                }
                // Two rows of diagnostic sections.
                HStack(alignment: .top, spacing: 14) {
                    AsservissementSection(train: train)
                    TractionSection(train: train)
                    ExploitationSection(train: train)
                }
                HStack(alignment: .top, spacing: 14) {
                    ATPSection(train: train)
                    AuxiliarySection(train: train)
                    // Console A22 -- present only under the VAL backend
                    // (the fixed-block engine stamps `speedProgram`).
                    if !train.speedProgram.isEmpty {
                        PupitreSection(train: train)
                    }
                }
                ElectricalSynopticSection(train: train, editable: isLocal)
                AuxControlsSection(train: train, editable: isLocal)
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
            RetroButton("\(language.t("theme.label")): \(language.t(language.themeKind == .retro ? "theme.retro" : "theme.iso"))",
                        highlighted: language.themeKind == .iso101) {
                language.toggleTheme()
            }
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

/// The traction-chain bench strip: the four chopper quantities as live
/// meters (thesis notation II / IL / IEX / MHI). The line-current bar is
/// zero-centred so regeneration visibly swings it the other way.
private struct TractionBenchSection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        BoxPanel(title: language.t("detail.sec.bench"), accent: RetroTheme.cyan) {
            HStack(alignment: .top, spacing: 10) {
                BarMeter(value: train.armatureCurrent,
                         maxValue: Sim.armatureCurrentMax,
                         caption: "II",
                         readout: String(format: "%.0f A", train.armatureCurrent),
                         color: RetroTheme.green)
                SignedBarMeter(value: train.lineCurrent,
                               maxMagnitude: 2 * Sim.armatureCurrentMax,
                               caption: "IL",
                               readout: String(format: "%+.0f A", train.lineCurrent))
                BarMeter(value: train.excitationCurrent,
                         maxValue: 40,
                         caption: "IEX",
                         readout: String(format: "%.1f A", train.excitationCurrent),
                         color: RetroTheme.green)
                BarMeter(value: train.modulationRatio,
                         maxValue: 1.0,
                         caption: "MHI",
                         readout: String(format: "%.0f %%", train.modulationRatio * 100),
                         color: train.modulationRatio >= 0.99 ? RetroTheme.amberBright : RetroTheme.amber)
            }
        }
    }
}

/// A zero-centred horizontal bar: positive fills right (drawing from the
/// line), negative fills left in cyan (regenerating into it).
private struct SignedBarMeter: View {
    let value: Double
    let maxMagnitude: Double
    let caption: String
    let readout: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(caption)
                    .font(RetroTheme.monoSm)
                    .foregroundColor(RetroTheme.amberDim)
                Spacer()
                Text(readout)
                    .font(RetroTheme.mono)
                    .foregroundColor(value < -1 ? RetroTheme.cyan : RetroTheme.amberBright)
                    .retroGlow()
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                let frac = CGFloat(max(-1, min(1, value / maxMagnitude)))
                ZStack(alignment: .leading) {
                    Rectangle().fill(RetroTheme.amberDim.opacity(0.25))
                    // Centre line.
                    Rectangle()
                        .fill(RetroTheme.amberDim)
                        .frame(width: 1)
                        .offset(x: half)
                    Rectangle()
                        .fill(frac >= 0 ? RetroTheme.amberBright : RetroTheme.cyan)
                        .frame(width: abs(frac) * half)
                        .offset(x: frac >= 0 ? half : half - abs(frac) * half)
                }
            }
            .frame(height: 12)
            .overlay(Rectangle().stroke(RetroTheme.amber.opacity(0.5), lineWidth: 1))
        }
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
                // Bench view of the chain (VAL backend): the chopper
                // relationship il = mhi x ii, and the image-série field
                // ratio -- what a maintenance bench verifies. II/IL/IEX/
                // MHI are the thesis symbols, identical in both languages.
                if !train.speedProgram.isEmpty {
                    ValueRow(label: language.t("detail.traction.armature"),
                             value: String(format: "%.0f A", train.armatureCurrent))
                    ValueRow(label: language.t("detail.traction.line"),
                             value: String(format: "%+.0f A", train.lineCurrent),
                             color: train.lineCurrent < -1 ? RetroTheme.cyan : RetroTheme.amberBright)
                    ValueRow(label: language.t("detail.traction.field"),
                             value: String(format: "%.1f A", train.excitationCurrent))
                    ValueRow(label: language.t("detail.traction.duty"),
                             value: String(format: "%.0f %%", train.modulationRatio * 100),
                             color: train.modulationRatio >= 0.99 ? RetroTheme.amberBright : RetroTheme.amber)
                }
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
                ValueRow(label: language.t("detail.exploit.boarding"),
                         value: "+\(train.paxBoarding)",
                         color: train.paxBoarding > 0 ? RetroTheme.green : RetroTheme.amberDim)
                ValueRow(label: language.t("detail.exploit.alighting"),
                         value: "-\(train.paxAlighting)",
                         color: train.paxAlighting > 0 ? RetroTheme.cyan : RetroTheme.amberDim)
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
                // VAL fixed-block program telemetry (mnemonics are
                // firmware identifiers, shared across languages).
                if let program = VALSpeedProgram(rawValue: train.speedProgram) {
                    HRule(RetroTheme.amberDim)
                    ValueRow(label: language.t("detail.atp.program"),
                             value: program.mnemonic,
                             color: program == .perturbed ? RetroTheme.amberBright : RetroTheme.green)
                    if train.isEmergencyBrakeApplied,
                       let cause = VALTripCause(rawValue: train.ebCause), cause != .none {
                        ValueRow(label: language.t("detail.atp.ebcause"),
                                 value: cause.mnemonic, color: .red)
                        // Maintenance pointer: the suspect boards for
                        // this trip, in the STS rack nomenclature.
                        if !cause.suspectLRU.isEmpty {
                            ValueRow(label: language.t("detail.atp.lru"),
                                     value: cause.suspectLRU,
                                     color: RetroTheme.cyan)
                        }
                    }
                }
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

/// Console A22 -- the manual-driving pupitre, live under the VAL
/// backend. Displays the cab state for any rame; the controls engage
/// when the rame is controllable and in manual mode (the cab cover is
/// locked under automatic driving). Every control routes through the
/// peer link like the PCC panel's. KG / KACOP / AV / 0 / AR are real cab
/// markings -- language-neutral.
private struct PupitreSection: View {
    let train: Train
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var network: PeerNetwork

    private var driving: Bool { train.mode == .manual && network.canControl(train) }

    var body: some View {
        BoxPanel(title: language.t("detail.sec.pupitre"),
                 accent: train.mode == .manual ? RetroTheme.cyan : RetroTheme.amberDim) {
            VStack(alignment: .leading, spacing: 6) {
                // Voyants (per the cab lamp panel). TRAC and KACOP read
                // the same in both languages; the others follow the
                // domain-acronym convention (FREIN/PM/URG <-> BRAKE/MAN/EB).
                HStack(spacing: 10) {
                    voyant("TRAC", train.pupitreLever > 0.02 && driving, RetroTheme.green)
                    voyant(language.t("fault.frein"), train.pupitreLever < -0.02, RetroTheme.amber)
                    voyant(language.t("pupitre.voyant.pm"),
                           train.mode == .manual && train.pupitreKG && train.pupitreReverser != 0,
                           RetroTheme.cyan)
                    voyant(language.t("pupitre.voyant.urg"), train.isEmergencyBrakeApplied, .red)
                    voyant("KACOP", train.kacopWarning, .red)
                }
                HRule(RetroTheme.amberDim)
                HStack(spacing: 8) {
                    RetroButton("KG", enabled: driving, highlighted: train.pupitreKG) {
                        _ = network.control(train, .pupitreKG, value: train.pupitreKG ? 0 : 1)
                    }
                    Text(language.t("pupitre.reverser"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amber)
                    ForEach([(1, "AV"), (0, "0"), (-1, "AR")], id: \.0) { value, label in
                        RetroButton(label, enabled: driving,
                                    highlighted: train.pupitreReverser == value) {
                            _ = network.control(train, .pupitreReverser, value: Double(value))
                        }
                    }
                }
                // Manipulateur traction/freinage: chips over the throw.
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.t("pupitre.lever"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amber)
                    HStack(spacing: 6) {
                        ForEach([(-100, "F100"), (-50, "F50"), (-25, "F25"), (0, "0"),
                                 (25, "T25"), (50, "T50"), (100, "T100")], id: \.0) { pct, label in
                            RetroButton(label, enabled: driving && (pct <= 0 || tractionPermitted),
                                        highlighted: abs(train.pupitreLever * 100 - Double(pct)) < 5) {
                                _ = network.control(train, .pupitreLever, value: Double(pct) / 100.0)
                            }
                        }
                    }
                }
                HRule(RetroTheme.amberDim)
                HStack(spacing: 8) {
                    RetroButton(kacopLabel, enabled: driving, highlighted: train.kacopWarning) {
                        _ = network.control(train, .kacopAck)
                    }
                    ValueRow(label: language.t("pupitre.vigilance"),
                             value: train.mode == .manual && train.pupitreKG
                                 ? String(format: "%4.1f s", train.kacopSecondsSinceAck)
                                 : "--",
                             color: train.kacopWarning ? .red : RetroTheme.amberBright)
                }
                if train.mode == .manual && !tractionPermitted {
                    Text(language.t("pupitre.traction.inhibited"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberBright)
                }
                if !driving {
                    Text(language.t(train.mode == .manual
                                    ? "detail.controls.remote" : "pupitre.covered"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The cab's traction interlocks (KG, reverser, doors) -- braking is
    /// always available, so only positive lever chips grey out.
    private var tractionPermitted: Bool {
        train.pupitreKG && train.pupitreReverser != 0 && !train.doorsOpen
            && !train.isEmergencyBrakeApplied
    }

    private var kacopLabel: String {
        guard train.mode == .manual && train.pupitreKG else { return "KACOP" }
        let remaining = max(0, Sim.kacopTripDelay - train.kacopSecondsSinceAck)
        return String(format: "KACOP %2.0f", remaining)
    }

    private func voyant(_ label: String, _ lit: Bool, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(lit ? color : Color.clear)
                .overlay(Rectangle().stroke(color, lineWidth: 1))
                .frame(width: 22, height: 10)
            Text(label)
                .font(RetroTheme.monoSm)
                .foregroundColor(lit ? color : RetroTheme.amberDim)
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
                ValueRow(label: language.t("detail.aux.cvs"),
                         value: String(format: "%.0f V", train.cvsOutputVoltage))
                ValueRow(label: language.t("detail.aux.battery"),
                         value: String(format: "%.1f V", train.batteryVoltage))
                ValueRow(label: language.t("detail.aux.lighting"),
                         value: String(format: "%.1f A", train.lightingCurrent),
                         color: train.areLightsOn ? RetroTheme.amberBright : RetroTheme.amberDim)
                ValueRow(label: language.t("detail.aux.compressor"),
                         value: String(format: "%.1f bar", train.compressorPressure))
                ValueRow(label: language.t("detail.aux.brakebox"),
                         value: String(format: "%.0f °C", train.brakeBoxTemperature),
                         color: train.brakeBoxTemperature > 110 ? .red : RetroTheme.amberBright)
                ValueRow(label: language.t("detail.aux.temp"),
                         value: String(format: "%.0f °C  (SP %.0f)", train.interiorTemperature, train.targetTemperature))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Auxiliary controls (owner-driven telecommands)

/// The train-detail auxiliary controls: DELESTAGE BT and the other
/// subsystem toggles plus the momentary telecommands (RAZ MULTIMEDIA, ACQUIT
/// COMPTEUR FU, …). Every action routes through `MetroWorld.mutate`, so the
/// block is live only for a locally-owned rame; on a REMOTE rame the controls
/// render disabled with a read-only banner.
private struct AuxControlsSection: View {
    let train: Train
    let editable: Bool
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        BoxPanel(title: language.t("detail.sec.controls"), accent: RetroTheme.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                // Subsystem toggles.
                FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    AuxControlButton(label: language.t("ctl.delestage"),
                                     active: train.isLoadSheddingActive,
                                     enabled: editable, onColor: RetroTheme.red) {
                        world.mutate(train.id) { $0.setLoadShedding(!$0.isLoadSheddingActive) }
                    }
                    AuxControlButton(label: language.t("ctl.eclairage"),
                                     active: train.areLightsOn,
                                     enabled: editable, onColor: RetroTheme.green) {
                        world.mutate(train.id) { $0.areLightsOn.toggle() }
                    }
                    AuxControlButton(label: language.t("ctl.ventilation"),
                                     active: train.areVentilated,
                                     enabled: editable, onColor: RetroTheme.green) {
                        world.mutate(train.id) { $0.areVentilated.toggle() }
                    }
                    AuxControlButton(label: language.t("ctl.chauffage"),
                                     active: train.isHeating,
                                     enabled: editable, onColor: RetroTheme.amber) {
                        world.mutate(train.id) { $0.isHeating.toggle() }
                    }
                    AuxControlButton(label: language.t("ctl.suspension"),
                                     active: train.isSuspensionActive,
                                     enabled: editable, onColor: RetroTheme.green) {
                        world.mutate(train.id) { $0.isSuspensionActive.toggle() }
                    }
                    AuxControlButton(label: language.t("ctl.compresseur"),
                                     active: train.isCompressorRunning,
                                     enabled: editable, onColor: RetroTheme.green) {
                        world.mutate(train.id) { $0.isCompressorRunning.toggle() }
                    }
                }
                HRule(RetroTheme.amberDim)
                // Momentary telecommands.
                FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    RetroButton(language.t("ctl.razmultimedia"), enabled: editable) {
                        world.mutate(train.id) { $0.isMultimediaResetting = true }
                    }
                    RetroButton("\(language.t("ctl.acquitfu")) [\(train.emergencyBrakeCounter)]",
                                enabled: editable) {
                        world.mutate(train.id) { $0.emergencyBrakeCounter = 0 }
                    }
                    RetroButton(language.t("ctl.sonorisation"),
                                enabled: editable, highlighted: train.isSoundSystemActive) {
                        world.mutate(train.id) { $0.isSoundSystemActive.toggle() }
                    }
                    RetroButton(language.t("ctl.videoinit"),
                                enabled: editable, highlighted: !train.isVideoSystemInitialized) {
                        world.mutate(train.id) { $0.isVideoSystemInitialized.toggle() }
                    }
                    RetroButton(language.t("ctl.archivage"),
                                enabled: editable, highlighted: train.isArchiving) {
                        world.mutate(train.id) { $0.isArchiving.toggle() }
                    }
                }
                if !editable {
                    Text(language.t("detail.controls.remote"))
                        .font(RetroTheme.monoSm)
                        .foregroundColor(RetroTheme.amberDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A latching subsystem toggle: an indicator lamp (lit in `onColor` when the
/// system is engaged) beside its label, framed as a pressable cell.
private struct AuxControlButton: View {
    let label: String
    let active: Bool
    let enabled: Bool
    let onColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(active ? onColor : Color.clear)
                    .overlay(Rectangle().stroke(active ? onColor : RetroTheme.amberDim, lineWidth: 1))
                    .frame(width: 10, height: 10)
                Text(label)
                    .font(RetroTheme.monoSm)
                    .foregroundColor(enabled ? RetroTheme.amber : RetroTheme.amberDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(
                Rectangle().stroke(
                    enabled ? (active ? onColor.opacity(0.8) : RetroTheme.amber.opacity(0.7))
                            : RetroTheme.amberDim.opacity(0.5),
                    lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Electrical system diagram (synoptic)

/// The rame's low-voltage electrical synoptic: the two 750 V third-rail
/// shoes feeding the bus, the static
/// converter (CVS) and motor-alternator/compressor group, the battery, and
/// the DELESTAGE BT contact that visibly opens when load shedding is engaged,
/// dropping the lighting and ventilation loads. Node labels localise EN / FR.
private struct ElectricalSynopticSection: View {
    let train: Train
    let editable: Bool
    @EnvironmentObject var language: AppLanguage
    @EnvironmentObject var world: MetroWorld
    @State private var selected: Subsystem?

    var body: some View {
        BoxPanel(title: language.t("detail.sec.diagram"), accent: RetroTheme.green) {
            GeometryReader { proxy in
                let s = proxy.size
                ZStack {
                    wiring(size: s)
                    // 750 V line pickup shoes (both open the pickup screen).
                    DiagNode(title: language.t("detail.node.shoel"),
                             value: String(format: "%.0f V", train.mainVoltage),
                             color: RetroTheme.red, x: 0.06, y: 0.80, size: s,
                             selected: selected == .pickup) { selected = .pickup }
                    DiagNode(title: language.t("detail.node.shoer"),
                             value: String(format: "%.0f V", train.mainVoltage),
                             color: RetroTheme.red, x: 0.94, y: 0.80, size: s,
                             selected: selected == .pickup) { selected = .pickup }
                    // Static converter and motor-alternator/compressor group.
                    DiagNode(title: language.t("detail.node.cvs"),
                             value: String(format: "%.0f V", train.cvsOutputVoltage),
                             color: RetroTheme.cyan, x: 0.30, y: 0.40, size: s,
                             selected: selected == .cvs) { selected = .cvs }
                    DiagNode(title: language.t("detail.node.compressor"),
                             value: train.isCompressorRunning ? language.t("sub.val.run") : language.t("sub.val.stop"),
                             color: train.isCompressorRunning ? RetroTheme.green : RetroTheme.amberDim,
                             x: 0.70, y: 0.40, size: s,
                             selected: selected == .compressor) { selected = .compressor }
                    // Battery and main reservoir.
                    DiagNode(title: language.t("detail.node.battery"),
                             value: String(format: "%.1f V", train.batteryVoltage),
                             color: RetroTheme.cyan, x: 0.50, y: 0.62, size: s,
                             selected: selected == .battery) { selected = .battery }
                    DiagNode(title: language.t("detail.node.reservoir"),
                             value: String(format: "%.1f bar", train.compressorPressure),
                             color: RetroTheme.cyan, x: 0.70, y: 0.62, size: s,
                             selected: selected == .compressor) { selected = .compressor }
                    // DELESTAGE BT contact state.
                    DiagNode(title: language.t("detail.node.delestage"),
                             value: train.isLoadSheddingActive ? language.t("sub.val.active") : "—",
                             color: train.isLoadSheddingActive ? RetroTheme.red : RetroTheme.greenDim,
                             x: 0.30, y: 0.75, size: s,
                             selected: selected == .delestage) { selected = .delestage }
                    // Shed loads.
                    DiagLamp(title: language.t("detail.node.lighting"),
                             active: train.areLightsOn, x: 0.10, y: 0.90, size: s,
                             selected: selected == .lighting) { selected = .lighting }
                    DiagLamp(title: language.t("detail.node.ventilation"),
                             active: train.areVentilated, x: 0.24, y: 0.90, size: s,
                             selected: selected == .ventilation) { selected = .ventilation }
                }
                // Prompt when idle; the drill-down screen when a node is picked.
                .overlay(alignment: .topTrailing) {
                    if selected == nil {
                        Text(language.t("sub.hint"))
                            .font(RetroTheme.monoSm)
                            .foregroundColor(RetroTheme.amberDim)
                            .padding(6)
                    }
                }
                .overlay(alignment: .trailing) {
                    if let sel = selected {
                        SubsystemPanel(subsystem: sel, train: train, editable: editable) {
                            selected = nil
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: 250)
            .frame(maxWidth: .infinity)
        }
    }

    /// The wiring net drawn in phosphor green, with the DELESTAGE BT contact
    /// rendered closed (green segment) or open (red swung blade).
    private func wiring(size: CGSize) -> some View {
        let shed = train.isLoadSheddingActive
        return Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
            var net = Path()
            // Third-rail shoes up to the 750 V bus.
            net.move(to: p(0.06, 0.86)); net.addLine(to: p(0.12, 0.86)); net.addLine(to: p(0.12, 0.18))
            net.move(to: p(0.94, 0.86)); net.addLine(to: p(0.88, 0.86)); net.addLine(to: p(0.88, 0.18))
            // 750 V bus.
            net.move(to: p(0.12, 0.18)); net.addLine(to: p(0.88, 0.18))
            // Drops to CVS and compressor group.
            net.move(to: p(0.30, 0.18)); net.addLine(to: p(0.30, 0.33))
            net.move(to: p(0.70, 0.18)); net.addLine(to: p(0.70, 0.33))
            // CVS output to battery and LV bus.
            net.move(to: p(0.30, 0.47)); net.addLine(to: p(0.30, 0.62)); net.addLine(to: p(0.44, 0.62))
            net.move(to: p(0.30, 0.62)); net.addLine(to: p(0.18, 0.62)); net.addLine(to: p(0.18, 0.72))
            // Compressor group to reservoir.
            net.move(to: p(0.70, 0.47)); net.addLine(to: p(0.70, 0.56))
            // Below the DELESTAGE contact: LV loads.
            net.move(to: p(0.18, 0.79)); net.addLine(to: p(0.18, 0.86))
            net.addLine(to: p(0.10, 0.86))
            net.move(to: p(0.18, 0.86)); net.addLine(to: p(0.24, 0.86))
            ctx.stroke(net, with: .color(RetroTheme.green.opacity(0.85)), lineWidth: 1.5)
            // DELESTAGE BT contact.
            let top = p(0.18, 0.72), bot = p(0.18, 0.79)
            var contact = Path()
            if shed {
                contact.move(to: top)
                contact.addLine(to: CGPoint(x: top.x + w * 0.05, y: (top.y + bot.y) / 2))
                ctx.stroke(contact, with: .color(RetroTheme.red), lineWidth: 2)
            } else {
                contact.move(to: top); contact.addLine(to: bot)
                ctx.stroke(contact, with: .color(RetroTheme.green), lineWidth: 2)
            }
            // Contact pads.
            for pt in [top, bot] {
                let r = CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: r), with: .color(RetroTheme.amber))
            }
        }
    }
}

/// A labelled box on the electrical synoptic, positioned by fractional
/// coordinates within the diagram canvas.
private struct DiagNode: View {
    let title: String
    let value: String
    let color: Color
    let x: CGFloat
    let y: CGFloat
    let size: CGSize
    var selected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(RetroTheme.monoSm)
                .foregroundColor(RetroTheme.amber)
            Text(value)
                .font(RetroTheme.monoSm)
                .foregroundColor(color)
        }
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RetroTheme.bg)
        .overlay(Rectangle().stroke(selected ? RetroTheme.cyan : color.opacity(0.8),
                                    lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .position(x: size.width * x, y: size.height * y)
    }
}

/// A load lamp on the electrical synoptic: filled when the load is energised.
private struct DiagLamp: View {
    let title: String
    let active: Bool
    let x: CGFloat
    let y: CGFloat
    let size: CGSize
    var selected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(active ? RetroTheme.amber : Color.clear)
                .overlay(Circle().stroke(selected ? RetroTheme.cyan : (active ? RetroTheme.amber : RetroTheme.amberDim),
                                         lineWidth: selected ? 2 : 1))
                .frame(width: 16, height: 16)
            Text(title)
                .font(RetroTheme.monoSm)
                .foregroundColor(active ? RetroTheme.amber : RetroTheme.amberDim)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .position(x: size.width * x, y: size.height * y)
    }
}

// MARK: - Subsystem drill-down

/// The subsystems reachable by clicking a node on the electrical synoptic.
/// Each produces its own screen of readouts.
private enum Subsystem: String, Identifiable {
    case pickup, cvs, compressor, battery, delestage, lighting, ventilation
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .pickup:      return "sub.title.pickup"
        case .cvs:         return "sub.title.cvs"
        case .compressor:  return "sub.title.compressor"
        case .battery:     return "sub.title.battery"
        case .delestage:   return "sub.title.delestage"
        case .lighting:    return "sub.title.lighting"
        case .ventilation: return "sub.title.ventilation"
        }
    }

    /// The readout rows for this subsystem: (label, value, value colour).
    @MainActor func rows(train: Train, language: AppLanguage) -> [(String, String, Color)] {
        func t(_ k: String) -> String { language.t(k) }
        let val = RetroTheme.amberBright, on = RetroTheme.green, info = RetroTheme.cyan
        let dim = RetroTheme.amberDim
        switch self {
        case .pickup:
            return [(t("sub.row.linev"), String(format: "%.0f V", train.mainVoltage), val),
                    (t("sub.row.current"), "120 A", val),
                    (t("sub.row.shoel"), t("sub.val.active"), on),
                    (t("sub.row.shoer"), t("sub.val.active"), on)]
        case .cvs:
            return [(t("sub.row.input"), String(format: "%.0f V", train.mainVoltage), val),
                    (t("sub.row.output"), String(format: "%.0f V", train.cvsOutputVoltage), info),
                    (t("sub.row.temp"), "45 °C", val),
                    (t("sub.row.load"), "65 %", val)]
        case .compressor:
            return [(t("sub.row.state"), train.isCompressorRunning ? t("sub.val.run") : t("sub.val.stop"),
                     train.isCompressorRunning ? on : dim),
                    (t("sub.row.pressure"), String(format: "%.1f bar", train.compressorPressure), val),
                    (t("sub.row.oil"), t("sub.val.ok"), on),
                    (t("sub.row.vibration"), t("sub.val.normal"), on)]
        case .battery:
            return [(t("sub.row.voltage"), String(format: "%.1f V", train.batteryVoltage), info),
                    (t("sub.row.current"), "+12 A", on),
                    (t("sub.row.charge"), "92 %", val),
                    (t("sub.row.temp"), "22 °C", val)]
        case .delestage:
            return [(t("sub.row.state"), train.isLoadSheddingActive ? t("sub.val.active") : t("sub.val.inactive"),
                     train.isLoadSheddingActive ? RetroTheme.red : RetroTheme.greenDim),
                    (t("sub.row.lighting"), train.isLoadSheddingActive ? t("sub.val.reduced") : t("sub.val.normal"), val),
                    (t("sub.row.ventilation"), train.areVentilated ? t("sub.val.on") : t("sub.val.off"),
                     train.areVentilated ? on : dim)]
        case .lighting:
            return [(t("sub.row.voltage"), String(format: "%.0f V", train.cvsOutputVoltage), info),
                    (t("sub.row.current"), String(format: "%.1f A", train.lightingCurrent), val),
                    (t("sub.row.circa"), t("sub.val.ok"), on),
                    (t("sub.row.circb"), t("sub.val.ok"), on)]
        case .ventilation:
            return [(t("sub.row.mode"), t("sub.val.ac"), info),
                    (t("sub.row.setpoint"), String(format: "%.0f °C", train.targetTemperature), val),
                    (t("sub.row.interior"), String(format: "%.0f °C", train.interiorTemperature), val),
                    (t("sub.row.fans"), train.areVentilated ? t("sub.val.run") : t("sub.val.stop"),
                     train.areVentilated ? on : dim)]
        }
    }
}

/// The floating drill-down screen for one subsystem, opened from the
/// synoptic. Read-only readouts plus, on DELESTAGE BT, an owner-only toggle.
private struct SubsystemPanel: View {
    let subsystem: Subsystem
    let train: Train
    let editable: Bool
    let onClose: () -> Void
    @EnvironmentObject var world: MetroWorld
    @EnvironmentObject var language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(language.t(subsystem.titleKey))
                    .font(RetroTheme.mono)
                    .foregroundColor(RetroTheme.cyan)
                    .retroGlow()
                Spacer()
                Button(action: onClose) {
                    Text("✕").font(RetroTheme.mono).foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            HRule(RetroTheme.amberDim)
            ForEach(Array(subsystem.rows(train: train, language: language).enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).font(RetroTheme.monoSm).foregroundColor(RetroTheme.amber)
                    Spacer(minLength: 16)
                    Text(row.1).font(RetroTheme.monoSm).foregroundColor(row.2)
                }
            }
            if subsystem == .delestage {
                RetroButton(train.isLoadSheddingActive ? language.t("sub.val.inactive") : language.t("sub.val.active"),
                            enabled: editable,
                            highlighted: train.isLoadSheddingActive) {
                    world.mutate(train.id) { $0.setLoadShedding(!$0.isLoadSheddingActive) }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(width: 236, alignment: .leading)
        .background(RetroTheme.bgPanel)
        .overlay(Rectangle().stroke(RetroTheme.cyan, lineWidth: 1))
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
