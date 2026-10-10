import Foundation

// VALCP MONITOR LINE / LIGNE -- the LPD VAL-CTRL live line monitor.
//
// A layered product cannot add a class to DEC's MONITOR utility, so like
// LATCP's or NCP's own displays this is a VALCP subcommand that paints a
// product-owned SMG$ pasteboard (24 x 80): a reverse-video product banner
// and status line, then three bordered, labelled virtual displays -- LINE
// (a mimic board of the loop: rames as reverse-video labels moving along a
// two-row track, 0-500 m left to right on top and 500-1000 m right to left
// underneath, block occupancy lit between the rails, switch zones with
// their position), ALARMS (the most severe active alarm) and TRAINS (the
// per-rame table) -- a message row, and the key-legend status bar (Ctrl/Z
// exit, Ctrl/W repaint, Ctrl/Y interrupt). Like SMG$ the screen is drawn
// once and then updated by rewriting only the rows that changed.
//
// VALCP output is localised (the vendor is French); the `%VALCP-x-IDENT`
// facility codes and SCADA identifiers stay as-is. The emulator honours
// only reverse video, so the "blink" on moving switches, an EB'd rame and
// unacknowledged alarms is done by toggling reverse video on alternate
// frames.
extension DCLEngine {
    /// `monitorClass` tag that routes the live timer to this screen.
    static let valcpLineMonitorClass = "VALCP_LINE"

    /// Whether the VALCP line monitor owns the screen (the line discipline
    /// checks this to give Ctrl/Z and Ctrl/W their SMG meanings).
    var isValcpLineMonitorActive: Bool {
        guard liveActive, case .monitor = liveMode else { return false }
        return monitorClass == Self.valcpLineMonitorClass
    }

    /// Track columns per half-loop. 70 columns over 500 m makes each 100 m
    /// block exactly 14 columns, and the 150 m station spacing (21 columns)
    /// leaves room for the longest station name.
    private static let lineCols = 70
    private static let blockCols = 14
    /// Rame length (head to tail) used for the drawn glyph and occupancy;
    /// matches the VAL wayside's detection length.
    private static let rameLength: Double = 26.0
    /// Rows of the per-rame table that fit the 24-line pasteboard.
    private static let maxTableRows = 6
    private static let screenWidth = 79

    /// `VALCP MONITOR object [/INTERVAL=seconds]`. LINE / LIGNE follows the
    /// session language like every other VALCP line object.
    func valcpMonitor(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return tr("valcp.err.mon.missqual")
        }
        guard matchesLoc(what, en: "LINE", fr: "LIGNE", min: 4) else {
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("valcp.err.mon.ivkeyw"), what.uppercased())
        }
        guard world != nil else { return tr("valcp.cmd.noworld") }
        var interval: TimeInterval = 0.5
        if let raw = cmd.qualifierValue("INTERVAL") {
            guard let n = Double(raw), n >= 0.25 else {
                return String(format: tr("valcp.err.mon.interval"), raw)
            }
            interval = n
        }
        if dryRun {
            return String(format: tr("valcp.mon.dryrun"), localizedInterval(interval))
        }
        // Fresh pasteboard: the first frame paints every row, and the
        // cursor is hidden while the screen is up (DECTCEM).
        valcpScreenRows = []
        outRaw("\u{1B}[?25l")
        startMonitor(class: Self.valcpLineMonitorClass, interval: interval)
        return ""
    }

    /// "0.5" / "0,5": the interval with the language's decimal separator.
    private func localizedInterval(_ t: TimeInterval) -> String {
        let s = formatInterval(t)
        return uiLang == .fr ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    /// VMS absolute time with the month abbreviation in the session
    /// language -- what LIB$FORMAT_DATE_TIME yields under SYS$LANGUAGE
    /// FRENCH. The rest of the format is identical in both.
    private func lpdStamp(_ date: Date) -> String {
        let s = stamp(date)
        guard uiLang == .fr else { return s }
        let fr = ["JAN": "JAN", "FEB": "FÉV", "MAR": "MAR", "APR": "AVR",
                  "MAY": "MAI", "JUN": "JUN", "JUL": "JUL", "AUG": "AOÛ",
                  "SEP": "SEP", "OCT": "OCT", "NOV": "NOV", "DEC": "DÉC"]
        var parts = s.components(separatedBy: "-")
        if parts.count >= 3, let m = fr[parts[1]] { parts[1] = m }
        return parts.joined(separator: "-")
    }

    /// A full-width reverse-video bar with left / centre / right fields.
    private func smgBar(_ left: String, _ mid: String, _ right: String) -> String {
        let w = Self.screenWidth
        var row = [Character](repeating: " ", count: w)
        func put(_ text: String, at col: Int) {
            for (i, ch) in text.enumerated() where col + i >= 0 && col + i < w { row[col + i] = ch }
        }
        // Centre field slides right of a long left field rather than
        // overprinting it (the FR key legend is wider than the EN one).
        put(left, at: 1)
        put(right, at: w - 1 - right.count)
        put(mid, at: max((w - mid.count) / 2, left.count + 4))
        return "\u{1B}[7m" + String(row) + "\u{1B}[27m"
    }

    // MARK: -- SMG pasteboard

    /// Printable width of a row, ignoring SGR escape sequences.
    private func visibleWidth(_ s: String) -> Int {
        var n = 0
        var inEsc = false
        for u in s.unicodeScalars {
            if inEsc {
                if (0x40...0x7E).contains(u.value) && u != "[" { inEsc = false }
            } else if u == "\u{1B}" {
                inEsc = true
            } else {
                n += 1
            }
        }
        return n
    }

    /// One bordered SMG virtual display (SMG$CREATE_VIRTUAL_DISPLAY with
    /// SMG$M_BORDER, labelled with SMG$LABEL_BORDER): a top border carrying
    /// the label, the content rows padded to the inner width, and the
    /// bottom border.
    private func smgDisplay(label: String, rows: [String]) -> [String] {
        let inner = Self.screenWidth - 2
        let lbl = " " + label + " "
        let top = "┌─" + lbl + String(repeating: "─", count: max(0, inner - 1 - lbl.count)) + "┐"
        var out = [top]
        for r in rows {
            out.append("│" + r + String(repeating: " ", count: max(0, inner - visibleWidth(r))) + "│")
        }
        out.append("└" + String(repeating: "─", count: inner) + "┘")
        return out
    }

    /// CTRL/W: SMG$REPAINT_SCREEN -- forget the last frame and redraw
    /// every row (recovers from line noise or a resized window).
    func valcpRepaint() {
        valcpScreenRows = []
        refreshLiveDisplay()
    }

    /// Paste a frame onto the terminal the way SMG$ updates a pasteboard:
    /// the first frame (and a CTRL/W repaint) clears and draws every row;
    /// after that only rows that changed since the last frame are
    /// rewritten, addressed with CUP -- no full-screen clear, no flicker.
    func valcpPaint(_ rows: [String]) {
        let full = valcpScreenRows.count != rows.count
        var out = full ? "\u{1B}[0m\u{1B}[2J" : ""
        for (i, row) in rows.enumerated() where full || valcpScreenRows[i] != row {
            out += "\u{1B}[\(i + 1);1H" + row + "\u{1B}[0m\u{1B}[K"
        }
        valcpScreenRows = rows
        if !out.isEmpty { outRaw(out) }
    }

    /// One frame of the line monitor: 24 pasteboard rows -- product banner,
    /// status line, then the LINE, ALARMS and TRAINS virtual displays, a
    /// message row and the key-legend status bar.
    func valcpLineMonitorRows(elapsed: String) -> [String] {
        guard let world else { return [tr("valcp.cmd.noworld")] }
        let now = Date()
        let blinkOn = Int(now.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
        let trains = world.sortedTrains
        let half = Sim.trackLength / 2

        // Product banner (reverse-video header) and the line status.
        var screen: [String] = []
        screen.append(smgBar("LPD VAL-CTRL V4.2", tr("valcp.mon.title"),
                             String(format: tr("valcp.mon.node"), nodeName)))
        let modeKey: String
        switch world.lineMode {
        case .stopped:           modeKey = "valcp.ligne.mode.stopped"
        case .normal:            modeKey = "valcp.mon.mode.normal"
        case .serviceProvisoire: modeKey = "valcp.ligne.mode.sp"
        case .emergency:         modeKey = "valcp.ligne.mode.emergency"
        }
        var mode = tr(modeKey)
        if world.lineMode == .emergency && blinkOn { mode = "\u{1B}[7m" + mode + "\u{1B}[27m" }
        screen.append(" " + lpdStamp(now) + "   "
                      + String(format: tr("valcp.mon.status"),
                               mode, BackendManager.shared.kind.rawValue, trains.count))

        // MARK: track geometry

        // Screen cell for a position: top row runs left to right, bottom
        // row right to left, so the loop reads clockwise.
        func cell(_ p: Double) -> (bottom: Bool, col: Int) {
            let x = p.truncatingRemainder(dividingBy: Sim.trackLength)
            let pos = x < 0 ? x + Sim.trackLength : x
            let n = Self.lineCols
            if pos < half {
                return (false, min(n - 1, Int(pos / half * Double(n))))
            }
            return (true, (n - 1) - min(n - 1, Int((pos - half) / half * Double(n))))
        }
        func blockId(_ p: Double) -> Int {
            let x = p.truncatingRemainder(dividingBy: Sim.trackLength)
            let pos = x < 0 ? x + Sim.trackLength : x
            return min(Sim.cantonCount, Int(pos / Sim.cantonLength) + 1)
        }

        // Track rows: double rail with a tick at every block boundary.
        var top = [String](repeating: "═", count: Self.lineCols)
        var bot = [String](repeating: "═", count: Self.lineCols)
        for c in stride(from: Self.blockCols, to: Self.lineCols, by: Self.blockCols) {
            top[c] = "╤"
            bot[c] = "╧"
        }

        // Switch zones (VAL wayside equipment only): NORMAL ╪, REVERSE a
        // reverse-video ╳, in motion alternating between the two.
        if let backend = BackendManager.shared.engine as? VALSimBackend {
            for sw in backend.switchTable() {
                let c = cell((sw.entry + sw.exit) / 2)
                let glyph: String
                if !sw.locked {
                    glyph = blinkOn ? "\u{1B}[7m╳\u{1B}[27m" : "╪"
                } else {
                    glyph = sw.reversed ? "\u{1B}[7m╳\u{1B}[27m" : "╪"
                }
                if c.bottom { bot[c.col] = glyph } else { top[c.col] = glyph }
            }
        }

        // Occupancy (head block + tail block) and the rame glyphs.
        var occupied = Set<Int>()
        for t in trains {
            let dir = t.travelDirection.rawValue
            occupied.insert(blockId(t.position))
            occupied.insert(blockId(t.position - dir * Self.rameLength))

            // Three cells from the head back towards the tail.
            let step = half / Double(Self.lineCols)
            var cells: [(bottom: Bool, col: Int)] = []
            for k in 0..<3 {
                let c = cell(t.position - dir * step * Double(k))
                if !cells.contains(where: { $0 == c }) { cells.append(c) }
            }
            let label = Array(t.label.prefix(3))
            let sameRow = cells.allSatisfy { $0.bottom == cells[0].bottom }
            let ordered = cells.sorted { $0.col < $1.col }
            for (i, c) in ordered.enumerated() {
                // Write the label in screen order when the glyph sits on one
                // row; a rame straddling a corner shows as a solid bar.
                let ch = (sameRow && ordered.count == label.count) ? String(label[i]) : " "
                let g = "\u{1B}[7m" + ch + "\u{1B}[27m"
                if c.bottom { bot[c.col] = g } else { top[c.col] = g }
            }
        }

        // Block rows between the rails: each 14-column segment carries the
        // block number and lights up in reverse video while occupied.
        func blockRow(_ ids: [Int]) -> String {
            ids.map { id -> String in
                let name = String(format: tr("valcp.mon.block.short"), id)
                let pad = max(0, Self.blockCols - name.count)
                let seg = String(repeating: " ", count: pad / 2) + name
                        + String(repeating: " ", count: pad - pad / 2)
                return occupied.contains(id) ? "\u{1B}[7m" + seg + "\u{1B}[27m" : seg
            }.joined()
        }
        let topIds = Array(1...(Sim.cantonCount / 2))
        let botIds = Array(((Sim.cantonCount / 2) + 1)...Sim.cantonCount).reversed()

        // Station label rows: a marker at the stop point, name after it.
        func stationRow(bottom: Bool, marker: String) -> String {
            var row = [Character](repeating: " ", count: Self.lineCols + 2)
            for st in world.stations {
                let c = cell(st.position)
                guard c.bottom == bottom else { continue }
                let text = Array(marker + st.name)
                for (i, ch) in text.enumerated() where c.col + 1 + i < row.count {
                    row[c.col + 1 + i] = ch
                }
            }
            return String(row)
        }

        let indent = "  "
        screen += smgDisplay(label: tr("valcp.mon.lbl.line"), rows: [
            indent + stationRow(bottom: false, marker: "▼"),
            indent + "╭" + top.joined() + "╮",
            indent + "│" + blockRow(topIds) + "│",
            indent + "│" + blockRow(Array(botIds)) + "│",
            indent + "╰" + bot.joined() + "╯",
            indent + stationRow(bottom: true, marker: "▲"),
        ])

        // MARK: alarms display

        let active = world.activeAlarms
        let unacked = active.filter { !$0.isAcknowledged }.count
        var alarm = " "
        if let a = active.first {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let sev: String
            switch a.severity {
            case .critical: sev = "F"
            case .major:    sev = "E"
            case .minor:    sev = "W"
            case .advisory: sev = "I"
            }
            // Time and ACK state lead so truncation only ever clips the
            // message tail.
            let status = a.isAcknowledged ? tr("alarm.status.ack") : tr("alarm.status.unack")
            var text = f.string(from: a.raisedAt) + "  " + status.padding(toLength: 6, withPad: " ", startingAt: 0)
            text += "%VALCP-\(sev)-\(a.point), \(a.source): \(alarmMessage(a.message))"
            let room = Self.screenWidth - 4
            if text.count > room { text = String(text.prefix(room)) }
            alarm += (!a.isAcknowledged && blinkOn) ? "\u{1B}[7m" + text + "\u{1B}[27m" : text
        } else {
            alarm += tr("valcp.mon.noalarm")
        }
        screen += smgDisplay(label: String(format: tr("valcp.mon.lbl.alarms"), active.count, unacked),
                             rows: [alarm])

        // MARK: trains display

        func col(_ str: String, _ w: Int) -> String {
            str.count >= w ? String(str.prefix(w - 1)) + " " : str.padding(toLength: w, withPad: " ", startingAt: 0)
        }
        // Sums to the 77-column inner width with the longest state text.
        let widths = [6, 5, 15, 6, 9, 7, 14]
        let stateWidth = Self.screenWidth - 2 - 1 - widths.reduce(0, +)
        let heads = ["valcp.mon.col.train", "valcp.mon.col.prog", "valcp.mon.col.speed",
                     "valcp.mon.col.setpt", "valcp.mon.col.limit", "valcp.mon.col.block",
                     "valcp.mon.col.next"]
        var hdr = " "
        for (k, w) in zip(heads, widths) { hdr += col(tr(k), w) }
        hdr += col(tr("valcp.mon.col.state"), stateWidth)
        var rows = ["\u{1B}[7m" + hdr + "\u{1B}[27m"]

        if trains.isEmpty {
            rows.append(" " + tr("dynamics.empty"))
        }
        let barWidth = 8
        for t in trains.prefix(Self.maxTableRows) {
            let kmh = t.speed * 3.6
            let filled = max(0, min(barWidth, Int((t.speed / Sim.manualSpeedMax * Double(barWidth)).rounded())))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
            let prog = VALSpeedProgram(rawValue: t.speedProgram)?.mnemonic
                ?? (t.speedProgram.isEmpty ? "--" : t.speedProgram.uppercased())
            let limit = t.distanceToMA > 9999 ? "  >9999" : String(format: "%7.1f", t.distanceToMA)
            var row = " "
            row += col(t.label, widths[0])
            row += col(prog, widths[1])
            row += col(String(format: "%5.1f ", kmh) + bar, widths[2])
            row += col(String(format: "%5.1f", t.consigneVitesse * 3.6), widths[3])
            row += col(limit, widths[4])
            row += col(String(format: tr("valcp.mon.block.short"), blockId(t.position)), widths[5])
            row += col(t.nextStationName, widths[6])
            let state = String(tr("dynamics.state." + lineStateKey(for: t)).prefix(stateWidth))
            // An EB'd rame flashes its state so it reads from across the room.
            row += (lineStateKey(for: t) == "eb" && blinkOn) ? "\u{1B}[7m" + state + "\u{1B}[27m" : state
            rows.append(row)
        }
        // Keep the display a fixed height so the pasteboard never shifts.
        while rows.count < Self.maxTableRows + 1 { rows.append("") }
        let shown = min(trains.count, Self.maxTableRows)
        let trainsLabel = trains.count > shown
            ? String(format: tr("valcp.mon.lbl.trains.part"), shown, trains.count)
            : String(format: tr("valcp.mon.lbl.trains"), trains.count)
        screen += smgDisplay(label: trainsLabel, rows: rows)

        // Message row (empty, as SMG leaves it until a message arrives),
        // then the status bar: key legend, refresh interval, elapsed time.
        screen.append("")
        screen.append(smgBar(tr("valcp.mon.keys"),
                             String(format: tr("valcp.mon.interval"), localizedInterval(monitorIntervalSec)),
                             String(format: tr("valcp.mon.elapsed"), elapsed)))
        return screen
    }

    /// Asservissement regime as a `dynamics.state.*` key suffix -- the same
    /// precedence MONITOR DYNAMICS uses, but localized for the VALCP screen.
    private func lineStateKey(for train: Train) -> String {
        if train.isEmergencyBrakeApplied || train.status == .emergency { return "eb" }
        if train.doorsOpen { return "dwell" }
        if train.isDepartureHold { return "hold" }
        if train.mode == .manual { return "manual" }
        if train.status == .stopped { return abs(train.speed) > 0.05 ? "stopping" : "idle" }
        if train.speedProgram == VALSpeedProgram.perturbed.rawValue && train.speedError < -0.1 {
            return "perturbed"
        }
        if train.speedError < -0.3 { return "decel" }
        if train.speed >= train.consigneVitesse * 0.95 && train.consigneVitesse > 0.5 { return "cruise" }
        return "accel"
    }
}
