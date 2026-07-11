import Foundation

// SHOW BACKEND / SET BACKEND and SHOW PRATIC / SET PRATIC -- the operator
// surface of the backend layer (Backends/). Like MODBUS and HARDWARE,
// BACKEND and PRATIC are fixed CLI vocabulary (language-neutral keywords,
// not language-gated); the display text localizes as layered-product
// content. Identifiers on the wire (VAL, PRATIC_SIM, PRATIC_HW, JSONL,
// SERIAL, the link/confidence mnemonics) stay language-neutral.
extension DCLEngine {

    // MARK: -- SHOW BACKEND / SET BACKEND

    func showBackend() -> String {
        let manager = BackendManager.shared
        var s = "\n  " + tr("backend.title") + "\n"
        for kind in BackendKind.allCases {
            let marker = kind == manager.kind ? "*" : " "
            let id = kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            s += "   \(marker) \(id)\(tr(kind.summaryKey))\n"
        }
        if let pratic = manager.pratic {
            var link = tr(pratic.transportState.localizationKey)
            if let why = pratic.transportState.failureReason {
                link = String(format: link, why)
            }
            s += "\n  " + String(format: tr("backend.transport"), link) + "\n"
        }
        s += "  " + tr("backend.hint") + "\n"
        return s
    }

    /// SET BACKEND VAL | PRATIC_SIM | PRATIC_HW
    /// (PRATIC and SIM select the simulation; HW / HARDWARE the real one.)
    func setBackend(_ cmd: Parsed) -> String {
        guard let arg = cmd.positional.dropFirst().first?.uppercased() else {
            return tr("backend.set.usage") + "\n"
        }
        if dryRun {
            return "%BACKEND-I-DRYRUN, would switch backend to \(arg) (no change made)\n"
        }
        let kind: BackendKind
        switch arg {
        case "VAL":
            kind = .val
        case "PRATIC", "PRATIC_SIM", "SIM", "SIMULATION":
            kind = .praticSim
        case "PRATIC_HW", "HW", "HARDWARE":
            kind = .praticHardware
        default:
            fail("BACKEND-W-IVKEYW", "%X000080C0")
            return String(format: tr("backend.set.bad"), arg) + "\n"
        }
        guard BackendManager.shared.select(kind) else {
            return tr("backend.set.noworld") + "\n"
        }
        return String(format: tr("backend.set.ok"), kind.rawValue) + "\n"
    }

    // MARK: -- SHOW PRATIC

    func showPratic() -> String {
        guard let pratic = BackendManager.shared.pratic else {
            return "\n  " + tr("pratic.notactive") + "\n"
        }
        let net = pratic.network
        let now = Date()
        var s = "\n  " + tr("pratic.title") + "\n"
        var link = tr(pratic.transportState.localizationKey)
        if let why = pratic.transportState.failureReason {
            link = String(format: link, why)
        }
        s += "  " + String(format: tr("backend.transport"), link) + "\n\n"

        s += "  " + tr("pratic.trains.header") + "\n"
        s += "  ------  ---------  ------  --------------  ------  --------  ------------  ------\n"
        if net.trains.isEmpty {
            s += "  " + tr("pratic.trains.none") + "\n"
        }
        for t in net.trains {
            let label = t.label.padding(toLength: 6, withPad: " ", startingAt: 0)
            let pos = String(format: "%5.0f m", t.position).padding(toLength: 9, withPad: " ", startingAt: 0)
            let seg = String(format: "%d+%02.0f", t.segmentId, t.segmentOffset)
                .padding(toLength: 6, withPad: " ", startingAt: 0)
            let speed = String(format: "%4.1f/%4.1f m/s", t.speed, t.consigne)
                .padding(toLength: 14, withPad: " ", startingAt: 0)
            let maAge = Int(now.timeIntervalSince(t.maIssuedAt))
            let ma = String(format: "%4.0f m", t.maLimit).padding(toLength: 6, withPad: " ", startingAt: 0)
            let linkTag = tr(t.linkStatus.localizationKey)
                .padding(toLength: 10, withPad: " ", startingAt: 0)
            let conf = tr(t.confidence.localizationKey)
                .padding(toLength: 13, withPad: " ", startingAt: 0)
            let unc = String(format: "±%.0fm", t.uncertainty)
            s += "  \(label)  \(pos)  \(seg)  \(speed)  \(ma)  \(linkTag)  \(conf)  \(unc) (MA \(maAge)s)\n"
        }

        s += "\n  " + tr("pratic.wayside.header") + "\n"
        for st in net.stations {
            let id = String(format: "S%02d", st.id)
            let at = String(format: "%4.0f m", st.position)
            let status = st.faulted ? tr("pratic.wayside.fault") : tr("pratic.wayside.ok")
            let seen: String
            if let last = st.lastDetection {
                seen = String(format: tr("pratic.wayside.seen"), Int(now.timeIntervalSince(last)))
            } else {
                seen = tr("pratic.wayside.never")
            }
            s += "    \(id)  \(at)  \(status.padding(toLength: 10, withPad: " ", startingAt: 0))  \(seen)\n"
        }

        s += "\n  " + tr("pratic.turnouts.header") + "\n"
        for tn in net.turnouts {
            let state = tr(tn.reversed ? "pratic.turnout.reverse" : "pratic.turnout.normal")
            let lock = tn.locked ? "  [" + tr("pratic.turnout.locked") + "]" : ""
            s += "    T\(tn.id)  \(state)\(lock)\n"
        }
        s += "\n  " + String(format: tr("pratic.balises"), net.balises.count) + "\n"
        s += "  " + tr("pratic.hint") + "\n"
        return s
    }

    // MARK: -- SET PRATIC

    /// SET PRATIC /MA=(train,limit-m) | /MA=(train,OFF)
    ///            /TARGET=(train,m/s)
    ///            /RELOCALIZE=train | /RELOCALIZE=(train,balise)
    ///            /TURNOUT=(id,NORMAL|REVERSE)
    ///            /INJECT=COMMS:train | /INJECT=SENSOR:station
    ///            /RESTORE=COMMS:train | /RESTORE=SENSOR:station
    ///            /TRANSPORT=JSONL|SERIAL /HOST=h /PORT=n
    ///            /CONNECT /DISCONNECT
    func setPratic(_ cmd: Parsed) -> String {
        if dryRun {
            return "%PRATIC-I-DRYRUN, would apply PRATIC network settings (no change made)\n"
        }
        guard let pratic = BackendManager.shared.pratic else {
            return tr("pratic.notactive") + "\n"
        }
        var lines: [String] = []

        if let spec = cmd.qualifierValue("MA", min: 2) {
            let parts = pairParts(spec)
            if parts.count == 2, parts[1].uppercased() == "OFF" || parts[1].uppercased() == "NONE" {
                lines.append(pratic.issueMovementAuthority(label: parts[0], limit: nil)
                    ? String(format: tr("pratic.set.ma.off"), parts[0])
                    : String(format: tr("pratic.set.notrain"), parts[0]))
            } else if parts.count == 2, let limit = Double(parts[1]) {
                lines.append(pratic.issueMovementAuthority(label: parts[0], limit: limit)
                    ? String(format: tr("pratic.set.ma.ok"), parts[0], limit)
                    : String(format: tr("pratic.set.notrain"), parts[0]))
            } else {
                lines.append(tr("pratic.set.ma.usage"))
            }
        }
        if let spec = cmd.qualifierValue("TARGET", min: 3) {
            let parts = pairParts(spec)
            if parts.count == 2, let speed = Double(parts[1]) {
                lines.append(pratic.setTargetSpeed(label: parts[0], speed: speed)
                    ? String(format: tr("pratic.set.target.ok"), parts[0], speed)
                    : String(format: tr("pratic.set.notrain"), parts[0]))
            } else {
                lines.append(tr("pratic.set.target.usage"))
            }
        }
        if let spec = cmd.qualifierValue("RELOCALIZE", min: 3) {
            let parts = pairParts(spec)
            if parts.count >= 1, !parts[0].isEmpty {
                let balise = parts.count >= 2 ? Int(parts[1]) : nil
                lines.append(pratic.relocalize(label: parts[0], baliseId: balise)
                    ? String(format: tr("pratic.set.reloc.ok"), parts[0])
                    : String(format: tr("pratic.set.notrain"), parts[0]))
            } else {
                lines.append(tr("pratic.set.reloc.usage"))
            }
        }
        if let spec = cmd.qualifierValue("TURNOUT", min: 4) {
            let parts = pairParts(spec)
            if parts.count == 2, let id = Int(parts[0]) {
                let reversed = matchesLoc(parts[1],
                                          en: "REVERSE", fr: "DEVIEE", min: 3)
                    || parts[1].uppercased() == "R"
                lines.append(pratic.throwTurnout(id: id, reversed: reversed)
                    ? String(format: tr(reversed ? "pratic.set.turnout.reverse"
                                                 : "pratic.set.turnout.normal"), id)
                    : String(format: tr("pratic.set.turnout.bad"), id))
            } else {
                lines.append(tr("pratic.set.turnout.usage"))
            }
        }
        if let spec = cmd.qualifierValue("INJECT", min: 3) {
            lines.append(injection(spec, restore: false, pratic: pratic))
        }
        if let spec = cmd.qualifierValue("RESTORE", min: 4) {
            lines.append(injection(spec, restore: true, pratic: pratic))
        }
        let transportKind = cmd.qualifierValue("TRANSPORT", min: 5)
        let host = cmd.qualifierValue("HOST", min: 3)
        let port = cmd.qualifierValue("PORT", min: 3).flatMap { UInt16($0) }
        if transportKind != nil || host != nil || port != nil {
            lines.append(pratic.configureTransport(kind: transportKind, host: host, port: port)
                ? tr("pratic.set.transport.ok")
                : tr("pratic.set.transport.bad"))
        }
        if cmd.hasQualifier("CONNECT", min: 3) {
            lines.append(pratic.connectTransport()
                ? tr("pratic.set.connect")
                : tr("pratic.set.transport.bad"))
        }
        if cmd.hasQualifier("DISCONNECT", min: 4) {
            pratic.disconnectTransport()
            lines.append(tr("pratic.set.disconnect"))
        }

        guard !lines.isEmpty else { return tr("pratic.set.missqual") + "\n" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "(a,b)" / "a,b" / "a" -> trimmed parts.
    private func pairParts(_ spec: String) -> [String] {
        spec.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "COMMS:201" / "SENSOR:3" -> the matching injection or restore.
    private func injection(_ spec: String, restore: Bool,
                           pratic: any PraticBackend) -> String {
        let parts = spec.split(separator: ":").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return tr("pratic.set.inject.usage") }
        let ok: Bool
        switch parts[0].uppercased() {
        case "COMMS":
            ok = pratic.inject(restore ? .commsRestore(label: parts[1])
                                       : .commsLoss(label: parts[1]))
        case "SENSOR":
            guard let id = Int(parts[1]) else { return tr("pratic.set.inject.usage") }
            ok = pratic.inject(restore ? .sensorRestore(stationId: id)
                                       : .sensorFault(stationId: id))
        default:
            return tr("pratic.set.inject.usage")
        }
        if !ok { return tr("pratic.set.inject.unsup") }
        return tr(restore ? "pratic.set.restore.ok" : "pratic.set.inject.ok")
    }
}
