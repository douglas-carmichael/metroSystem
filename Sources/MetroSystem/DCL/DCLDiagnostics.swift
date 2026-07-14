import Foundation

// Operator-level RUN diagnostics and the full-screen test-utility engine
// that drives them.
extension DCLEngine {
    func startTestUtility(name: String, header: String, steps: [TestStep]) {
        liveTimer?.invalidate()
        liveMode = .testUtility(name: name, header: header)
        testSteps = steps
        testCurrent = 0
        testResults = []
        testStartedAt = Date()
        enterLiveScreen()
        refreshTestDisplay(complete: false)
        let t = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTestUtility() }
        }
        liveTimer = t
    }

    func tickTestUtility() {
        guard testCurrent < testSteps.count else {
            liveTimer?.invalidate()
            liveTimer = nil
            refreshTestDisplay(complete: true)
            return
        }
        let step = testSteps[testCurrent]
        let result = step.run()
        testResults.append((step.label, result.reading, result.status))
        testCurrent += 1
        refreshTestDisplay(complete: testCurrent >= testSteps.count)
    }

    func refreshTestDisplay(complete: Bool) {
        guard case let .testUtility(name, header) = liveMode else { return }
        let width = 78
        let now = Date()

        // Build each row as a self-contained string with NO trailing newline.
        // Newlines at the end of the last row will scroll the viewport (the
        // cursor stepping off the bottom row pushes the top row into
        // scrollback), which is exactly how the test-name row was vanishing
        // from the screen. Instead, position each row absolutely with
        // CUP (`ESC [ r ; 1 H`) so no \n ever leaves the bottom of the
        // viewport, then `ESC [ J` wipes anything below.
        // `reverse` highlights only the interior (between the vertical
        // borders), so the │ box edges stay plain thin glyphs and the
        // reverse bar sits inside the box instead of overrunning it. Inner
        // text is clamped to the interior width so a long (e.g. French)
        // title can never stretch past the right border.
        func boxLine(_ inner: String, reverse: Bool = false) -> String {
            let clamped = String(inner.prefix(width - 2))
            let pad = max(0, width - 2 - clamped.count)
            let body = clamped + String(repeating: " ", count: pad)
            let painted = reverse ? "\u{1B}[7m" + body + "\u{1B}[27m" : body
            return "│" + painted + "│"
        }
        func sep(left: String, right: String) -> String {
            return left + String(repeating: "─", count: width - 2) + right
        }
        func centered(_ s: String) -> String {
            let pad = max(0, (width - 2 - s.count) / 2)
            return String(repeating: " ", count: pad) + s
        }

        let operatorLbl = tr("diag.operator")
        let elapsedLbl  = tr("diag.elapsed")
        let runningWord = tr("diag.status.running")
        let queuedWord  = tr("diag.status.queued")
        let abortHint   = tr("diag.abort.hint")
        let exitHint    = tr("diag.exit.hint")

        let innerWidth = width - 2

        // Column field widths shared by the header and every data row, so
        // the Reading / Status headings always sit above their columns no
        // matter how wide the localized headings are.
        let labelWidth = 42
        let readingWidth = 18

        var rows: [String] = []
        rows.append(sep(left: "┌", right: "┐"))
        rows.append(boxLine(centered("\(name)    \(operatorLbl): \(username)"), reverse: true))
        rows.append(sep(left: "├", right: "┤"))
        // `header` is the label-field heading ("<column1>  Test"); append the
        // Reading and Status headings at the same offsets the rows use.
        let headerRow = header.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            + tr("diag.col.reading").padding(toLength: readingWidth, withPad: " ", startingAt: 0)
            + " " + tr("diag.col.status")
        rows.append(boxLine("  " + headerRow))

        for (i, step) in testSteps.enumerated() {
            let label = step.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let reading: String
            let status: String
            if i < testResults.count {
                reading = testResults[i].reading.padding(toLength: readingWidth, withPad: " ", startingAt: 0)
                status  = testResults[i].status
            } else if i == testCurrent && !complete {
                reading = "....".padding(toLength: readingWidth, withPad: " ", startingAt: 0)
                status  = runningWord
            } else {
                reading = "".padding(toLength: readingWidth, withPad: " ", startingAt: 0)
                status  = queuedWord
            }
            rows.append(boxLine("  " + label + reading + " " + status))
        }

        rows.append(sep(left: "├", right: "┤"))

        let elapsed = uptimeString(from: testStartedAt, to: now)
        let passWord = tr("diag.status.pass")
        let okWord   = tr("diag.status.ok")
        if complete {
            let allGood = testResults.allSatisfy {
                $0.status == passWord || $0.status == okWord
            }
            let resultLbl = allGood ? tr("diag.allpass") : tr("diag.seeresults")
            let completeLbl = String(format: tr("diag.complete"), testResults.count, testSteps.count)
            rows.append(boxLine("  \(completeLbl)  \(elapsedLbl) \(elapsed)  \(resultLbl)"))
            let hintPad = max(0, innerWidth - exitHint.count)
            rows.append(boxLine(String(repeating: " ", count: hintPad) + exitHint))
        } else {
            let stepLbl = String(format: tr("diag.step.of"), testCurrent + 1, testSteps.count)
            rows.append(boxLine("  \(stepLbl)  \(elapsedLbl) \(elapsed)"))
            let hintPad = max(0, innerWidth - abortHint.count)
            rows.append(boxLine(String(repeating: " ", count: hintPad) + abortHint))
        }
        rows.append(sep(left: "└", right: "┘"))

        // The title row carries its own reverse-video interior (see boxLine
        // above), so the borders stay plain. Reset SGR (CSI 0 m) at the top
        // of the frame so no attribute inherited from a prior screen bleeds
        // in.
        var s = "\u{1B}[0m"
        for (idx, row) in rows.enumerated() {
            s += "\u{1B}[\(idx + 1);1H" + row
        }
        // Park the cursor below the last row before erasing -- erasing from
        // mid-row would leave trailing cells of the hint row visible. Reset
        // SGR first so the erased region isn't painted in reverse video
        // (erase honors the active attribute on many terminals).
        s += "\u{1B}[0m\u{1B}[\(rows.count + 1);1H\u{1B}[J"
        outRaw(s)
    }

    // MARK: -- diagnostic row layout helpers

    /// Width of the entity sub-column (train id / station name) inside the
    /// label field. The test-type text starts at this offset on every row,
    /// and the header places its "Test" heading at the same offset, so the
    /// column lines up regardless of how wide an individual entity is.
    /// Trains ("Train 101") need only a narrow column; station names run
    /// much longer ("Gare Lille Flandres") so they get their own width.
    var diagRameEntityWidth: Int { 13 }
    var diagStationEntityWidth: Int { 22 }

    /// Left-pad an entity into the fixed sub-column so the following
    /// test-type text aligns under the "Test" heading.
    private func diagEntity(_ entity: String, width: Int) -> String {
        entity.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// The two-column heading string a test utility hands to
    /// `startTestUtility`: the entity heading padded into the entity
    /// sub-column, then the shared "Test" heading above the test-type text.
    private func diagHeader(_ entityHeaderKey: String, width: Int) -> String {
        diagEntity(tr(entityHeaderKey), width: width) + tr("diag.col.test")
    }

    /// Deterministic per-position measured tire pressures with a small
    /// sensor spread, seeded by the rame number and tire position so a
    /// "pressure sweep" reports a realistic band instead of a flat
    /// min == max. Faulted tires keep their (lower) stored pressure.
    private func measuredTirePressures(of train: Train, seed: Int) -> [Double] {
        train.tires.map { t in
            let offset = (Double(((t.id + seed) * 37) % 7) - 3) * 0.08
            return max(0, t.pressure + offset)
        }
    }

    // MARK: -- diagnostic step lists

    /// FREIN_TEST -- brake-state audit on every rame: the FU chain must be
    /// released while a rame is moving and the service brake state must be
    /// consistent with the asservissement's command.
    func startFreinTest() {
        let pass = tr("diag.status.pass")
        let fail = tr("diag.status.fail")
        let noRame = tr("diag.reading.noRame")
        let labels = (world?.sortedTrains ?? []).map(\.label)
        let brakeName = tr("diag.step.frein.rame")
        var steps: [TestStep] = []
        for label in labels {
            let rowLabel = diagEntity(String(format: tr("diag.entity.rame"), label), width: diagRameEntityWidth) + brakeName
            steps.append(TestStep(label: rowLabel) { [weak self] in
                guard let self,
                      let train = self.world?.findTrain(label: label)
                else { return (noRame, fail) }
                // Real brake state -- FU commanded means the vital loop is
                // open; a moving rame with FU commanded is the failure
                // condition (the brake would be dragging).
                let moving = train.speed > 0.05
                if train.isEmergencyBrakeApplied && moving {
                    return (tr("diag.frein.reading.dragging"), fail)
                }
                if moving {
                    return (tr("diag.frein.reading.released"), pass)
                }
                let kn = 11.7 + Double((Int(label) ?? 1) % 4) * 0.18
                return (String(format: tr("diag.frein.reading.holding"), kn), pass)
            })
        }
        steps.append(TestStep(label: tr("diag.step.frein.fw")) {
            return ("v3.04 OK", pass)
        })
        startTestUtility(name: tr("diag.test.frein"),
                         header: diagHeader("diag.col.rame", width: diagRameEntityWidth),
                         steps: steps)
    }

    /// PORTES_TEST -- door-cycle test: commands a door cycle on every
    /// docked rame and verifies the traction interlock (doors open must
    /// forbid motion).
    func startPortesTest() {
        let pass = tr("diag.status.pass")
        let noRame = tr("diag.reading.noRame")
        let trains = world?.sortedTrains ?? []
        let labels = trains.map(\.label)
        let cycleName = tr("diag.step.portes.cycle")
        let interlockName = tr("diag.step.portes.interlock")
        var steps: [TestStep] = []
        for label in labels {
            let rowLabel = diagEntity(String(format: tr("diag.entity.rame"), label), width: diagRameEntityWidth) + cycleName
            steps.append(TestStep(label: rowLabel) { [weak self] in
                guard let self,
                      let world = self.world,
                      let train = world.findTrain(label: label)
                else { return (noRame, pass) }
                // Only a stationary rame can be cycled; a moving rame is
                // recorded as observation-only (the interlock is what
                // keeps its doors shut).
                let triggered = train.speed < 0.05 && !train.doorsOpen
                if triggered {
                    world.mutate(train.id) { t in
                        t.doorsOpen = true
                        t.isDwelling = true
                        t.dwellRemaining = 3.0
                        t.status = .docked
                    }
                }
                let cycle = 2.4 + Double((Int(label) ?? 0) % 3) * 0.2
                return (String(format: "%.2f s%@", cycle,
                               triggered ? "" : tr("diag.portes.reading.movingSuffix")), pass)
            })
        }
        for label in labels {
            let rowLabel = diagEntity(String(format: tr("diag.entity.rame"), label), width: diagRameEntityWidth) + interlockName
            steps.append(TestStep(label: rowLabel) { [weak self] in
                guard let self,
                      let train = self.world?.findTrain(label: label)
                else { return (noRame, pass) }
                // Door interlock: doors open while moving is the vital
                // failure the chain guards against.
                let healthy = !(train.doorsOpen && train.speed > 0.1)
                return (healthy ? tr("diag.portes.reading.locked")
                                : tr("diag.portes.reading.violated"),
                        healthy ? pass : tr("diag.status.fail"))
            })
        }
        startTestUtility(name: tr("diag.test.portes"),
                         header: diagHeader("diag.col.rame", width: diagRameEntityWidth),
                         steps: steps)
    }

    /// PNEU_CAL -- tire-pressure calibration: reads each rame's worst
    /// tire and reports the pressure spread across the eight positions.
    func startPneuCal() {
        let pass = tr("diag.status.pass")
        let ok   = tr("diag.status.ok")
        let fail = tr("diag.status.fail")
        let noRame = tr("diag.reading.noRame")
        let labels = (world?.sortedTrains ?? []).map(\.label)
        let sweepName = tr("diag.step.pneu.read")
        let spanName  = tr("diag.step.pneu.span")
        let sweepFmt  = tr("diag.pneu.reading.sweep")
        let spanFmt   = tr("diag.pneu.reading.span")
        var steps: [TestStep] = []
        for label in labels {
            let seed = Int(label) ?? 0
            steps.append(TestStep(label: diagEntity(String(format: tr("diag.entity.rame"), label), width: diagRameEntityWidth) + sweepName) { [weak self] in
                guard let self,
                      let train = self.world?.findTrain(label: label)
                else { return (noRame, pass) }
                let measured = self.measuredTirePressures(of: train, seed: seed)
                let minP = measured.min() ?? 0
                let maxP = measured.max() ?? 0
                let healthy = train.worstTire == .ok
                return (String(format: sweepFmt, minP, maxP),
                        healthy ? pass : fail)
            })
            steps.append(TestStep(label: diagEntity(String(format: tr("diag.entity.rame"), label), width: diagRameEntityWidth) + spanName) { [weak self] in
                guard let self,
                      let train = self.world?.findTrain(label: label)
                else { return (noRame, pass) }
                let measured = self.measuredTirePressures(of: train, seed: seed)
                let minP = measured.min() ?? 0
                let maxP = measured.max() ?? 0
                // Spread across the eight positions expressed against the
                // nominal pressure -- a flat set reads a few percent, a
                // faulted tire widens it sharply.
                let spanPct = Sim.tireNominalBar > 0
                    ? (maxP - minP) / Sim.tireNominalBar * 100 : 0
                return (String(format: spanFmt, spanPct), pass)
            })
        }
        let recordsReading = String(format: tr("diag.pneu.reading.records"), labels.count * 2)
        steps.append(TestStep(label: tr("diag.step.pneu.write")) {
            return (recordsReading, ok)
        })
        startTestUtility(name: tr("diag.test.pneu"),
                         header: diagHeader("diag.col.rame", width: diagRameEntityWidth),
                         steps: steps)
    }

    /// QUAI_LAMP_TEST -- platform display / departure-lamp test at every
    /// station of the line.
    func startQuaiLampTest() {
        let pass = tr("diag.status.pass")
        let noWorld = tr("diag.reading.noWorld")
        var steps: [TestStep] = []
        let litFmt = tr("diag.quai.reading.lit")
        let lampName = tr("diag.step.quai.station")
        for station in world?.stations ?? [] {
            // Per-platform departure-lamp array size -- deterministic from
            // the station index so each row reports its own measured count.
            let lampCount = 22 + (station.id % 4) * 2
            steps.append(TestStep(label: diagEntity(station.name, width: diagStationEntityWidth) + lampName) { [weak self] in
                guard self != nil else { return (noWorld, pass) }
                Thread.sleep(forTimeInterval: 0.15)
                return (String(format: litFmt, lampCount), pass)
            })
        }
        steps.append(TestStep(label: tr("diag.step.quai.fw")) {
            return ("v1.18 OK", pass)
        })
        startTestUtility(name: tr("diag.test.quai"),
                         header: diagHeader("diag.col.station", width: diagStationEntityWidth),
                         steps: steps)
    }

    /// LRU_LOOKUP -- walk every locally-owned rame's latched faults and
    /// EB cause and report the suspect board(s) in the STS rack
    /// nomenclature (Attachment A of the O'Hare maintenance contract):
    /// the board-swap maintenance model as a diagnosable exercise. Rames
    /// with nothing latched report clean.
    func startLRULookup() {
        let pass = tr("diag.status.pass")
        let attention = tr("diag.status.attention")
        let clean = tr("diag.lru.clean")
        var steps: [TestStep] = []
        for train in (world?.locallyOwned() ?? []) {
            let entity = String(format: tr("diag.entity.rame"), train.label)
            let suspects = VALFaultLRU.suspects(for: train)
            if suspects.isEmpty {
                steps.append(TestStep(label: diagEntity(entity, width: diagRameEntityWidth) + tr("diag.lru.scan")) {
                    Thread.sleep(forTimeInterval: 0.1)
                    return (clean, pass)
                })
            } else {
                for suspect in suspects {
                    steps.append(TestStep(label: diagEntity(entity, width: diagRameEntityWidth) + suspect.point) {
                        Thread.sleep(forTimeInterval: 0.1)
                        return (suspect.lru, attention)
                    })
                }
            }
        }
        steps.append(TestStep(label: tr("diag.step.lru.reference")) {
            ("STS ATT.A", pass)
        })
        startTestUtility(name: tr("diag.test.lru"),
                         header: diagHeader("diag.col.rame", width: diagRameEntityWidth),
                         steps: steps)
    }

    // MARK: -- diagnostic test selection menu (DECforms-style)

    /// Pop a full-screen menu that lets the operator pick one of the
    /// available diagnostic test utilities and run it. Lives in the
    /// alternate screen buffer so leaving the menu restores whatever
    /// was on the shell screen before.
    func startDiagnosticMenu() {
        liveTimer?.invalidate()
        liveTimer = nil
        // The lpd splash strings include a "RUN <image>" prefix, e.g.
        // "  RUN FREIN_TEST       Brake hold-force test on every rame".
        // Strip it -- the menu already shows the image in its own column.
        func descOf(_ key: String, image: String) -> String {
            let raw = tr(key)
            let needle = "RUN \(image)"
            if let r = raw.range(of: needle) {
                return raw[r.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
            }
            return raw.trimmingCharacters(in: .whitespaces)
        }
        diagMenuItems = [
            DiagMenuItem(image: "FREIN_TEST",
                         description: descOf("login.lpd.frein", image: "FREIN_TEST"),
                         runner: { [weak self] in self?.startFreinTest() }),
            DiagMenuItem(image: "PORTES_TEST",
                         description: descOf("login.lpd.portes", image: "PORTES_TEST"),
                         runner: { [weak self] in self?.startPortesTest() }),
            DiagMenuItem(image: "PNEU_CAL",
                         description: descOf("login.lpd.pneu", image: "PNEU_CAL"),
                         runner: { [weak self] in self?.startPneuCal() }),
            DiagMenuItem(image: "QUAI_LAMP_TEST",
                         description: descOf("login.lpd.quai", image: "QUAI_LAMP_TEST"),
                         runner: { [weak self] in self?.startQuaiLampTest() }),
            DiagMenuItem(image: "LRU_LOOKUP",
                         description: descOf("login.lpd.lru", image: "LRU_LOOKUP"),
                         runner: { [weak self] in self?.startLRULookup() }),
            DiagMenuItem(image: "LRU_DIR",
                         description: descOf("login.lpd.lrudir", image: "LRU_DIR"),
                         runner: { [weak self] in
                             // The browser handles its own exit and pops
                             // back to the menu via diagInvokedFromMenu.
                             self?.startLRUBrowser()
                         })
        ]
        diagMenuSelection = 0
        liveMode = .diagnosticMenu
        enterLiveScreen()
        refreshDiagnosticMenu()
    }

    /// Render the menu into the alternate buffer at known cell
    /// coordinates so no part of it can scroll off the viewport.
    func refreshDiagnosticMenu() {
        guard case .diagnosticMenu = liveMode else { return }
        let width = 78
        let innerWidth = width - 2

        // `reverse` highlights only the interior so the │ borders stay plain
        // and the bar sits inside the box; inner text is clamped so it can't
        // overrun the right border.
        func boxLine(_ inner: String, reverse: Bool = false) -> String {
            let clamped = String(inner.prefix(innerWidth))
            let pad = max(0, innerWidth - clamped.count)
            let body = clamped + String(repeating: " ", count: pad)
            let painted = reverse ? "\u{1B}[7m" + body + "\u{1B}[27m" : body
            return "│" + painted + "│"
        }
        func sep(_ left: String, _ right: String) -> String {
            return left + String(repeating: "─", count: innerWidth) + right
        }
        func centered(_ s: String) -> String {
            let pad = max(0, (innerWidth - s.count) / 2)
            return String(repeating: " ", count: pad) + s
        }

        var rows: [String] = []
        rows.append(sep("┌", "┐"))
        // LPD suite header + copyright line + selection subtitle so the
        // menu reads like a real OpenVMS layered-product form, and all
        // three lines are localisable (FR speakers see French headings).
        rows.append(boxLine(centered(tr("diag.suite") + "  V1.4"), reverse: true))
        rows.append(boxLine(centered(tr("diag.menu.copyright"))))
        rows.append(boxLine(centered(tr("diag.menu.title"))))
        rows.append(sep("├", "┤"))
        rows.append(boxLine(""))
        for (i, item) in diagMenuItems.enumerated() {
            let marker = i == diagMenuSelection ? " ▶ " : "   "
            let img    = item.image.padding(toLength: 16, withPad: " ", startingAt: 0)
            rows.append(boxLine(marker + img + " " + item.description, reverse: i == diagMenuSelection))
        }
        rows.append(boxLine(""))
        rows.append(sep("├", "┤"))
        rows.append(boxLine("  " + tr("diag.menu.nav")))
        rows.append(sep("└", "┘"))

        // The suite title bar and the selected menu item carry their own
        // reverse-video interior (see boxLine), the way a real OpenVMS
        // full-screen form marks its header and cursor line. A leading
        // CSI 0 m clears any inherited attribute.
        var s = "\u{1B}[0m"
        for (idx, row) in rows.enumerated() {
            s += "\u{1B}[\(idx + 1);1H" + row
        }
        // Reset SGR before erasing below so the cleared region isn't filled
        // with the reverse-video attribute.
        s += "\u{1B}[0m\u{1B}[\(rows.count + 1);1H\u{1B}[J"
        outRaw(s)
    }

    /// Handle keystrokes routed to the menu by the line discipline.
    /// Accepts an arrow-key escape sequence as raw bytes, plus single
    /// control bytes for Enter / Ctrl-Y.
    func handleDiagnosticMenuKey(_ bytes: [UInt8]) {
        guard case .diagnosticMenu = liveMode else { return }
        // The byte array may carry multiple keystrokes batched together
        // (especially over a telnet connection where the user holds an
        // arrow key down), so parse the stream rather than insisting on
        // bytes.count == 3 for a single arrow-key sequence -- the strict
        // check used to silently drop all the keys after the first.
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            // ESC ESC -- alternative exit for users whose tty layer eats
            // ^Y / ^C (e.g. nc-from-macOS-terminal).
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x1B {
                diagnosticMenuExit()
                return
            }
            // CSI sequence: ESC [ <params>* <final 0x40...0x7E>
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, !((0x40...0x7E).contains(bytes[j])) {
                    j += 1
                }
                if j < bytes.count {
                    switch bytes[j] {
                    case 0x41:                          // A - Up
                        if diagMenuSelection > 0 { diagMenuSelection -= 1 }
                    case 0x42:                          // B - Down
                        if diagMenuSelection < diagMenuItems.count - 1 {
                            diagMenuSelection += 1
                        }
                    default:
                        break
                    }
                    refreshDiagnosticMenu()
                    i = j + 1
                    continue
                } else {
                    break       // incomplete escape -- drop the tail
                }
            }
            switch b {
            case 0x0D, 0x0A:                            // Enter
                let chosen = diagMenuItems[diagMenuSelection]
                // Leave the menu but stay in live-screen mode -- the
                // test utility we hand off to will repaint the same alt
                // buffer. Mark the run so stopMonitor pops back here
                // instead of the DCL prompt when the operator dismisses
                // the finished test.
                liveMode = .none
                diagInvokedFromMenu = true
                chosen.runner()
                return
            case 0x03, 0x19:                            // Ctrl-C / Ctrl-Y
                diagnosticMenuExit()
                return
            default:
                break
            }
            i += 1
        }
    }

    private func diagnosticMenuExit() {
        // Drop the menu without the "MONITOR was interrupted"
        // message stopMonitor would print -- the menu was never a
        // monitor session in the first place.
        liveTimer?.invalidate()
        liveTimer = nil
        liveMode = .none
        exitLiveScreen()
        out(prompt)
    }
}
