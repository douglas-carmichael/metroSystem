import Foundation

/// RUN LRU_DIR -- the interactive LRU directory, presented as a
/// simulated DECforms application (the way a real VMS shop would ship a
/// parts-catalogue form on top of FMS/DECforms). A scrolling board list
/// on the left, the selected board's record on the right, a live
/// type-to-find field at the bottom. Board codes and rack names follow
/// the STS maintenance-contract nomenclature (Attachment A) used across
/// the VAL backend; the descriptions localize like any LPD content.
struct LRUBoard {
    /// Board code as silk-screened on the extractor handles (identifier,
    /// language-neutral).
    let code: String
    /// Rack / location identifier (OBCU SAFETY, WAYSIDE WCU, ...).
    let rack: String
    /// Localization key of the function description.
    let functionKey: String
    /// FU trip mnemonics this board explains (VALTripCause mnemonics,
    /// firmware identifiers).
    let trips: [String]
    /// Source citation shown on the Ref line.
    let ref: String
}

enum LRUDirectory {
    /// The catalogue, grouped rack by rack (the on-screen order).
    static let boards: [LRUBoard] = [
        // -- PA embarqué, SAFETY rack (AVP) --------------------------------
        LRUBoard(code: "CPFS-A", rack: "OBCU SAFETY", functionKey: "lru.fn.cpfs",
                 trips: ["SF"], ref: "DOT §3.5.2.2"),
        LRUBoard(code: "SSV", rack: "OBCU SAFETY", functionKey: "lru.fn.ssv",
                 trips: ["SURVITESSE"], ref: "DOT §3.5.2.3"),
        LRUBoard(code: "CPPP-A", rack: "OBCU SAFETY", functionKey: "lru.fn.cppp",
                 trips: ["PP-LIMIT", "CANTON"], ref: "DOT §3.5.2.4"),
        LRUBoard(code: "SFU", rack: "OBCU SAFETY", functionKey: "lru.fn.sfu",
                 trips: ["FU-CDE", "URGENCE"], ref: "DOT §3.5.3.2"),
        LRUBoard(code: "CMP-AB", rack: "OBCU SAFETY", functionKey: "lru.fn.cmpab",
                 trips: ["PA-CHAINE", "PA-DISCORD"], ref: "DOT §3.5.2.15"),
        // -- PA embarqué, DRIVE rack (AVO) ---------------------------------
        LRUBoard(code: "MP 68K3", rack: "OBCU DRIVE", functionKey: "lru.fn.mp68k3",
                 trips: [], ref: "STS ATT.A"),
        LRUBoard(code: "REG-A", rack: "OBCU DRIVE", functionKey: "lru.fn.rega",
                 trips: [], ref: "STS ATT.A"),
        LRUBoard(code: "ASST-A", rack: "OBCU DRIVE", functionKey: "lru.fn.assta",
                 trips: [], ref: "STS ATT.A"),
        LRUBoard(code: "ILTE", rack: "OBCU DRIVE", functionKey: "lru.fn.ilte",
                 trips: ["PORTES", "DEF-PORTES"], ref: "STS ATT.A"),
        // -- Traction / brake (HR car) -------------------------------------
        LRUBoard(code: "APEP", rack: "TRACTION", functionKey: "lru.fn.apep",
                 trips: ["DEF-FREIN"], ref: "STS ATT.A"),
        LRUBoard(code: "ESSCT", rack: "TRACTION", functionKey: "lru.fn.essct",
                 trips: ["DEF-FREIN"], ref: "STS ATT.A"),
        LRUBoard(code: "GTO CHOP", rack: "TRACTION", functionKey: "lru.fn.chopper",
                 trips: [], ref: "VERHILLE CH.1"),
        LRUBoard(code: "EXC MOD", rack: "TRACTION", functionKey: "lru.fn.excitation",
                 trips: [], ref: "VERHILLE CH.1"),
        LRUBoard(code: "CVS", rack: "TRACTION", functionKey: "lru.fn.cvs",
                 trips: [], ref: "VERHILLE ANN.A"),
        // -- Cab -----------------------------------------------------------
        LRUBoard(code: "A22", rack: "CONSOLE", functionKey: "lru.fn.a22",
                 trips: ["KACOP"], ref: "DOT §3.2.6"),
        // -- Wayside (per-station WCU) --------------------------------------
        LRUBoard(code: "INTUSA", rack: "WAYSIDE WCU", functionKey: "lru.fn.intusa",
                 trips: ["CANTON", "ROLLBACK"], ref: "STS ATT.A"),
        LRUBoard(code: "DCIS", rack: "WAYSIDE WCU", functionKey: "lru.fn.dcis",
                 trips: ["CANTON"], ref: "STS ATT.A"),
        LRUBoard(code: "AFSC", rack: "WAYSIDE WCU", functionKey: "lru.fn.afsc",
                 trips: ["SF", "PP-LIMIT"], ref: "STS ATT.A"),
        LRUBoard(code: "CKDO2", rack: "WAYSIDE WCU", functionKey: "lru.fn.ckdo2",
                 trips: ["AIGUILLE"], ref: "STS ATT.A"),
        LRUBoard(code: "INTREL", rack: "WAYSIDE WCU", functionKey: "lru.fn.intrel",
                 trips: ["AIGUILLE"], ref: "STS ATT.A"),
        LRUBoard(code: "DTU", rack: "WAYSIDE WCU", functionKey: "lru.fn.dtu",
                 trips: ["PCC"], ref: "STS ATT.A"),
        LRUBoard(code: "WCCU", rack: "WAYSIDE WCU", functionKey: "lru.fn.wccu",
                 trips: ["SF", "URGENCE"], ref: "DOT §3.5.2"),
        LRUBoard(code: "DOCU", rack: "STATION", functionKey: "lru.fn.docu",
                 trips: [], ref: "DOT §3.5.2.6"),
    ]
}

extension DCLEngine {

    /// Boards passing the current type-to-find filter (matched against
    /// the code and the rack, case-insensitive).
    private var lruFilteredBoards: [LRUBoard] {
        guard !lruDirFilter.isEmpty else { return LRUDirectory.boards }
        let needle = lruDirFilter.uppercased()
        return LRUDirectory.boards.filter {
            $0.code.uppercased().contains(needle)
                || $0.rack.uppercased().contains(needle)
        }
    }

    /// RUN LRU_DIR entry point.
    func startLRUBrowser() {
        liveTimer?.invalidate()
        liveTimer = nil
        lruDirSelection = 0
        lruDirFilter = ""
        liveMode = .lruBrowser
        enterLiveScreen()
        refreshLRUBrowser()
    }

    /// Paint the form. Fixed cell coordinates (CUP per row) like the
    /// other full-screen utilities, so nothing ever scrolls off.
    func refreshLRUBrowser() {
        guard case .lruBrowser = liveMode else { return }
        let width = 78
        let innerWidth = width - 2
        let listWidth = 22                      // interior of the list pane
        let detailWidth = innerWidth - listWidth - 1
        let listRows = 14                       // visible board rows

        let boards = lruFilteredBoards
        if lruDirSelection >= boards.count { lruDirSelection = max(0, boards.count - 1) }

        func clamp(_ s: String, _ w: Int) -> String {
            let c = String(s.prefix(w))
            return c + String(repeating: " ", count: max(0, w - c.count))
        }
        func sep(_ l: String, _ m: String, _ r: String) -> String {
            l + String(repeating: "─", count: listWidth)
              + m + String(repeating: "─", count: detailWidth) + r
        }
        func full(_ l: String, _ r: String) -> String {
            l + String(repeating: "─", count: innerWidth) + r
        }
        func boxLine(_ inner: String, reverse: Bool = false) -> String {
            let body = clamp(inner, innerWidth)
            let painted = reverse ? "\u{1B}[7m" + body + "\u{1B}[27m" : body
            return "│" + painted + "│"
        }
        func centered(_ s: String) -> String {
            let pad = max(0, (innerWidth - s.count) / 2)
            return String(repeating: " ", count: pad) + s
        }
        /// One split row: list cell + detail cell; the selected list row
        /// paints its interior in reverse video (the DECforms cursor bar).
        func splitLine(_ list: String, _ detail: String, selected: Bool = false) -> String {
            let l = clamp(list, listWidth)
            let leftPainted = selected ? "\u{1B}[7m" + l + "\u{1B}[27m" : l
            return "│" + leftPainted + "│" + clamp(detail, detailWidth) + "│"
        }
        /// Wrap a description onto lines of the detail column, with a
        /// hanging indent under the field label.
        func wrap(_ text: String, firstPrefix: String, hang: String, width w: Int) -> [String] {
            var lines: [String] = []
            var current = firstPrefix
            for word in text.split(separator: " ") {
                let candidate = current.hasSuffix(" ") || current.isEmpty
                    ? current + word : current + " " + word
                if candidate.count > w && current != firstPrefix && current != hang {
                    lines.append(current)
                    current = hang + word
                } else {
                    current = candidate
                }
            }
            lines.append(current)
            return lines
        }

        // ----- detail record for the selected board -----------------------
        // Field labels come pre-padded from the string table so the values
        // align in a column, the way DECforms lays out a record.
        var detail: [String] = []
        if let board = boards.indices.contains(lruDirSelection) ? boards[lruDirSelection] : nil {
            detail.append("")
            detail.append("  " + tr("lru.field.board") + board.code)
            detail.append("  " + tr("lru.field.rack") + board.rack)
            detail.append("")
            let label = "  " + tr("lru.field.function")
            let hang = String(repeating: " ", count: label.count)
            detail += wrap(tr(board.functionKey), firstPrefix: label,
                           hang: hang, width: detailWidth - 1)
            detail.append("")
            if !board.trips.isEmpty {
                detail.append("  " + tr("lru.field.trips") + board.trips.joined(separator: " · "))
            }
            detail.append("  " + tr("lru.field.ref") + board.ref)
        } else {
            detail.append("")
            detail.append("  " + tr("lru.nomatch"))
        }

        // ----- list window centred on the selection -----------------------
        var top = 0
        if boards.count > listRows {
            top = min(max(0, lruDirSelection - listRows / 2), boards.count - listRows)
        }

        var rows: [String] = []
        rows.append(full("┌", "┐"))
        rows.append(boxLine(centered(tr("lru.title") + "  V1.0"), reverse: true))
        rows.append(boxLine(centered(tr("diag.menu.copyright"))))
        rows.append(sep("├", "┬", "┤"))
        rows.append(splitLine(" " + tr("lru.col.header"), ""))
        for i in 0..<listRows {
            let idx = top + i
            var cell = ""
            if idx < boards.count {
                let marker = idx == lruDirSelection ? "▶" : " "
                cell = "\(marker)\(clamp(boards[idx].code, 10)) \(boards[idx].rack)"
            }
            let detailLine = i < detail.count ? detail[i] : ""
            rows.append(splitLine(cell, detailLine, selected: idx == lruDirSelection && idx < boards.count))
        }
        rows.append(sep("├", "┴", "┤"))
        // DECforms text field: typed characters fill the underscores.
        let fieldLen = 20
        let filled = String(lruDirFilter.prefix(fieldLen))
        let field = filled + String(repeating: "_", count: max(0, fieldLen - filled.count))
        let count = boards.count == 1
            ? tr("lru.count.one")
            : String(format: tr("lru.count"), boards.count)
        let findLine = "  \(tr("lru.find")) \(field)"
        let pad = max(1, innerWidth - findLine.count - count.count - 2)
        rows.append(boxLine(findLine + String(repeating: " ", count: pad) + count))
        rows.append(boxLine("  " + tr("lru.nav")))
        rows.append(full("└", "┘"))

        var s = "\u{1B}[0m"
        for (idx, row) in rows.enumerated() {
            s += "\u{1B}[\(idx + 1);1H" + row
        }
        s += "\u{1B}[0m\u{1B}[\(rows.count + 1);1H\u{1B}[J"
        outRaw(s)
    }

    /// Keystroke handling: arrows move the selection, printable text
    /// feeds the find field, DEL erases, Ctrl/U clears, Ctrl/Z (or the
    /// usual interrupt gestures) leaves the form.
    func handleLRUBrowserKey(_ bytes: [UInt8]) {
        guard case .lruBrowser = liveMode else { return }
        var i = 0
        var dirty = false
        while i < bytes.count {
            let b = bytes[i]
            // ESC ESC -- exit fallback for ttys that eat control bytes.
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x1B {
                lruBrowserExit()
                return
            }
            // CSI sequence (arrow keys).
            if b == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5B {
                var j = i + 2
                while j < bytes.count, !((0x40...0x7E).contains(bytes[j])) {
                    j += 1
                }
                if j < bytes.count {
                    let boards = lruFilteredBoards
                    switch bytes[j] {
                    case 0x41:                          // Up
                        if lruDirSelection > 0 { lruDirSelection -= 1; dirty = true }
                    case 0x42:                          // Down
                        if lruDirSelection < boards.count - 1 {
                            lruDirSelection += 1; dirty = true
                        }
                    default:
                        break
                    }
                    i = j + 1
                    continue
                } else {
                    break                               // incomplete escape
                }
            }
            switch b {
            case 0x03, 0x19, 0x1A:                      // Ctrl-C / Ctrl-Y / Ctrl-Z
                lruBrowserExit()
                return
            case 0x7F, 0x08:                            // DEL / BS
                if !lruDirFilter.isEmpty {
                    lruDirFilter.removeLast()
                    lruDirSelection = 0
                    dirty = true
                }
            case 0x15:                                  // Ctrl-U: clear field
                if !lruDirFilter.isEmpty {
                    lruDirFilter = ""
                    lruDirSelection = 0
                    dirty = true
                }
            case 0x20...0x7E:                           // printable: find field
                if lruDirFilter.count < 20 {
                    lruDirFilter.append(Character(UnicodeScalar(b)).uppercased())
                    lruDirSelection = 0
                    dirty = true
                }
            default:
                break
            }
            i += 1
        }
        if dirty { refreshLRUBrowser() }
    }

    private func lruBrowserExit() {
        liveTimer?.invalidate()
        liveTimer = nil
        liveMode = .none
        // Launched from the DIAGNOSE menu: pop back to the menu (the alt
        // buffer stays active, the menu repaints over the form).
        if diagInvokedFromMenu {
            diagInvokedFromMenu = false
            startDiagnosticMenu()
            return
        }
        exitLiveScreen()
        out(prompt)
    }
}
