import Foundation

// SET family -- per-keyword subcommands.
extension DCLEngine {
    func setCmd(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else { return missQual("SET") }
        switch true {
        case matches(what, "DEFAULT", min: 3):  return setDefault(cmd)
        case matches(what, "TERMINAL", min: 4): return setTerminal(cmd)
        case matches(what, "PROMPT", min: 3):   return setPrompt(cmd)
        case matches(what, "ON"):               return ""
        case matches(what, "NOON", min: 3):     return ""
        case matches(what, "VERIFY", min: 3):   return ""
        case matches(what, "NOVERIFY", min: 3): return ""
        case matches(what, "PASSWORD", min: 4): return setPassword()
        case matches(what, "PROCESS", min: 4):  return setProcess(cmd)
        case matches(what, "STANDARD", min: 3): return setStandard(cmd)
        case matches(what, "HARDWARE", min: 4): return setHardware(cmd)
        case matches(what, "BACKEND", min: 4):  return setBackend(cmd)
        case matches(what, "PRATIC", min: 4):   return setPratic(cmd)
        case matches(what, "RAME", min: 4):     return setRame(cmd)
        case matchesLoc(what, en: "LINE", fr: "LIGNE", min: 4):
            return setLigne(cmd)
        default:
            return noPriv("SET \(what)")
        }
    }

    /// SET STANDARD IEEE | EN62290 | AUTO
    ///
    /// Chooses which CBTC standard's terminology the UI presents.
    /// AUTO (the default) follows the UI language: French → EN 62290,
    /// English → IEEE 1474. Affects the safety-chain labels and the
    /// SHOW STATUS line.
    func setStandard(_ cmd: Parsed) -> String {
        guard let language else { return noPriv("SET STANDARD") }
        guard let arg = cmd.positional.dropFirst().first?.uppercased() else {
            return tr("dcl.set.standard.usage") + "\n"
        }
        switch arg {
        case "IEEE", "1474", "IEEE1474":
            language.standardOverride = .ieee
        case "EN62290", "EN-62290", "EN", "62290":
            language.standardOverride = .en62290
        case "AUTO", "LANGUAGE", "DEFAULT":
            language.standardOverride = nil
        default:
            return String(format: tr("dcl.set.standard.bad"), arg) + "\n"
        }
        let modeKey = language.standardOverride == nil
            ? "dcl.set.standard.followlang" : "dcl.set.standard.override"
        return String(format: tr("dcl.set.standard.ok"),
                      language.standard.label, tr(modeKey)) + "\n"
    }

    /// SET LIGNE /SERVICE=ON|OFF
    /// SET LIGNE /EMERGENCY=ON|OFF
    /// SET LIGNE /SP=(<from>,<to>[,<interval-s>])
    /// SET LIGNE /NORMAL
    ///
    /// Line-wide exploitation modes: service on/off, arrêt d'urgence
    /// général, and service provisoire (temporary shuttle between two
    /// stations with a headway). SET LINE is accepted as the EN spelling.
    func setLigne(_ cmd: Parsed) -> String {
        guard let world else { return tr("valcp.cmd.noworld") }
        if cmd.hasQualifier("NORMAL", min: 3) {
            world.setServiceProvisoire(nil)
            world.emergencyStopAll(false)
            world.startService()
            return tr("valcp.ligne.modenormal")
        }
        if let svc = cmd.qualifierValue("SERVICE", min: 4) {
            if svc.uppercased() == "ON" {
                world.startService()
                return tr("valcp.ligne.serviceon")
            } else {
                world.stopService()
                return tr("valcp.ligne.serviceoff")
            }
        }
        if let emer = cmd.qualifierValue(locQual(en: "EMERGENCY", fr: "URGENCE"), min: 4) {
            if emer.uppercased() == "ON" {
                world.emergencyStopAll(true)
                return tr("valcp.ligne.emeron")
            } else {
                world.emergencyStopAll(false)
                return tr("valcp.ligne.emeroff")
            }
        }
        if let spec = cmd.qualifierValue("SP", min: 2)
                        ?? cmd.qualifierValue("SERVICE_PROVISOIRE", min: 9) {
            if spec.uppercased() == "OFF" || spec.uppercased() == "NONE" {
                world.setServiceProvisoire(nil)
                return tr("valcp.ligne.spoff")
            }
            // Accept "(1,3,60)" or "1,3,60" or "1,3".
            let cleaned = spec.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2,
                  let fromId = Int(parts[0]),
                  let toId = Int(parts[1]),
                  world.stations.contains(where: { $0.id == fromId }),
                  world.stations.contains(where: { $0.id == toId }),
                  fromId != toId else {
                return tr("valcp.ligne.spusage")
            }
            let interval = parts.count >= 3 ? (Double(parts[2]) ?? 60.0) : 60.0
            world.setServiceProvisoire(ServiceProvisoire(startStationId: fromId,
                                                         endStationId: toId,
                                                         intervalle: max(10, interval)))
            return String(format: tr("valcp.ligne.spon"),
                          world.stationName(id: fromId),
                          world.stationName(id: toId),
                          Int(max(10, interval)))
        }
        // Switch throws (DOT §3.5.2.9): /SWITCH=(n,NORMAL|REVERSE), FR
        // /AIGUILLE=(n,NORMALE|DEVIEE). The wayside interlock refuses a
        // throw while any vehicle occupies the zone; the points cycle
        // lock-to-lock for 3 s (zone barred meanwhile).
        if let spec = cmd.qualifierValue(locQual(en: "SWITCH", fr: "AIGUILLE"), min: 3) {
            let cleaned = spec.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let parts = cleaned.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard parts.count == 2, let id = Int(parts[0]) else {
                return tr("valcp.ligne.swusage")
            }
            let reversed: Bool
            switch parts[1] {
            case "NORMAL", "NORMALE", "N":            reversed = false
            case "REVERSE", "DEVIEE", "DÉVIÉE", "R", "D": reversed = true
            default:
                return tr("valcp.ligne.swusage")
            }
            guard let backend = BackendManager.shared.engine as? VALSimBackend else {
                return tr("valcp.ligne.swnoval")
            }
            let posName = reversed ? tr("valcp.ligne.swpos.reverse")
                                   : tr("valcp.ligne.swpos.normal")
            switch backend.throwSwitch(id: id, reversed: reversed) {
            case .ok:
                return String(format: tr("valcp.ligne.swok"), id, posName)
            case .zoneOccupied:
                fail("SET-W-SWZONEOCC", "%X000080B2")
                return String(format: tr("valcp.ligne.swocc"), id)
            case .noSuchSwitch:
                fail("SET-W-NOSUCHSW", "%X000080B3")
                return String(format: tr("valcp.ligne.swnone"), id)
            }
        }
        return tr("valcp.ligne.missqual")
    }

    func setDefault(_ cmd: Parsed) -> String {
        guard let target = cmd.positional.dropFirst().first else { return missQual("SET DEFAULT") }
        var dev = defaultDevice
        var dir = defaultDirectory

        var spec = target
        if let colon = spec.firstIndex(of: ":") {
            dev = String(spec[...colon]).uppercased()
            spec = String(spec[spec.index(after: colon)...])
        }
        if !spec.isEmpty {
            if spec == "[-]" {
                if dir.hasPrefix("[") && dir.hasSuffix("]") {
                    var inner = String(dir.dropFirst().dropLast())
                    if let dot = inner.lastIndex(of: ".") {
                        inner = String(inner[..<dot])
                        dir = "[\(inner)]"
                    } else {
                        dir = "[000000]"
                    }
                }
            } else if spec.hasPrefix("[.") {
                let extra = String(spec.dropFirst(2).dropLast())
                let inner = dir.dropFirst().dropLast()
                dir = "[\(inner).\(extra)]"
            } else if spec.hasPrefix("[") {
                dir = spec.uppercased()
            } else {
                fail("DCL-W-IVKEYW", "%X00038088")
                return "%DCL-W-IVKEYW, unrecognized keyword - check validity and spelling\n"
            }
        }
        defaultDevice = dev
        defaultDirectory = dir
        return ""
    }

    func setTerminal(_ cmd: Parsed) -> String {
        if let w = cmd.qualifierValue("WIDTH"), let n = Int(w) { terminalWidth = n }
        if let p = cmd.qualifierValue("PAGE"),  let n = Int(p) { terminalPage = n }
        return ""
    }

    func setPrompt(_ cmd: Parsed) -> String {
        if let v = cmd.qualifiers.first(where: { $0.value != nil })?.value {
            prompt = v.replacingOccurrences(of: "\"", with: "") + " "
            return ""
        }
        if let v = cmd.positional.dropFirst().first {
            prompt = v.replacingOccurrences(of: "\"", with: "") + " "
            return ""
        }
        prompt = "$ "
        return ""
    }

    func setPassword() -> String {
        return "%SET-W-NOTSET, error modifying \(username)\n-SYSTEM-F-NOPRIV, insufficient privilege\n"
    }

    func setProcess(_ cmd: Parsed) -> String {
        if cmd.hasQualifier("PRIORITY", min: 3) || cmd.hasQualifier("NAME", min: 3) {
            return noPriv("SET PROCESS")
        }
        return ""
    }

    /// SET RAME <label> /MANUAL | /AUTOMATIC
    ///                  /SPEED=<m/s>          (manual CML speed ceiling)
    ///                  /FU=ON|OFF            (emergency brake)
    ///                  /KG=ON|OFF            (pupitre master power)
    ///                  /REVERSER=AV|0|AR     (FR: /INVERSEUR)
    ///                  /LEVER=<-100..100>    (FR: /MANIPULATEUR, percent)
    ///                  /KACOP                (dead-man acknowledgment)
    ///                  /KIBS=ON|OFF          (safety-loop inhibition, creep-limited)
    ///                  /KPH=ON|OFF           (headlights)
    ///                  /PORTES=ON|OFF        (door fault; /DOOR synonym)
    ///                  /TRACTION=ON|OFF      (engine fault; /ENGINE synonym)
    ///                  /FREIN=ON|OFF         (brake fault; /BRAKE synonym)
    ///                  /CTC=ON|OFF           (radio fault; /SIGNAL synonym)
    ///                  /PATINAGE=ON|OFF      (wheel slip; /SLIP synonym)
    ///                  /ENRAYAGE=ON|OFF      (wheel slide; /SLIDE synonym)
    ///                  /PNEU=<n>             (cycle tire <n>; /TIRE synonym)
    ///
    /// Qualifiers accept both the French exploitation terms and their
    /// English equivalents so EN and FR operators can drive the same
    /// rame. KG, KACOP and the reverser positions AV/0/AR are real cab
    /// labels -- language-neutral identifiers in both modes.
    func setRame(_ cmd: Parsed) -> String {
        guard let label = cmd.positional.dropFirst().first else {
            return tr("valcp.rame.missrame")
        }
        guard let world else {
            return tr("valcp.cmd.sysnoworld")
        }
        guard let train = world.findTrain(label: label) else {
            fail("SET-W-NOSUCHRAME", "%X000080A4")
            return String(format: tr("valcp.rame.nosuch"), label)
        }
        let dLabel = train.label
        let isLocal = world.canControl(train)
        // Exploitation qualifiers (mode, speed, FU) route to the owning
        // node for a remote rame, exactly like the PCC panel.
        func routed(_ kind: TrainCommandKind, value: Double? = nil,
                    localText: String) -> String {
            switch routeControl(train, kind, value: value, in: world) {
            case .local:     return localText
            case .forwarded: return String(format: tr("valcp.rame.forwarded"), dLabel)
            case .noLink:    return String(format: tr("valcp.rame.nolink"), dLabel)
            }
        }
        // Qualifiers are language-gated: the French spelling resolves only
        // in FR mode, the English only in EN mode (AUTO is a shared
        // abbreviation accepted in both).
        if cmd.hasQualifier(locQual(en: "MANUAL", fr: "MANUEL"), min: 3)
            || (uiLang == .fr && cmd.hasQualifier("MANUELLE", min: 3)) {
            let was = train.mode
            return routed(.modeManual, localText: was == .manual
                ? String(format: tr("valcp.rame.man.nochg"), dLabel)
                : String(format: tr("valcp.rame.man.set"), dLabel))
        }
        if cmd.hasQualifier(locQual(en: "AUTOMATIC", fr: "AUTOMATIQUE"), min: 4)
            || cmd.hasQualifier("AUTO", min: 4) {
            let was = train.mode
            return routed(.modeAuto, localText: was == .auto
                ? String(format: tr("valcp.rame.auto.nochg"), dLabel)
                : String(format: tr("valcp.rame.auto.set"), dLabel))
        }
        if let speedStr = cmd.qualifierValue(locQual(en: "SPEED", fr: "VITESSE"), min: 3),
           let requested = Double(speedStr) {
            guard train.mode == .manual else {
                return String(format: tr("valcp.rame.speed.notmanual"), dLabel)
            }
            let clamped = max(0, min(Sim.manualSpeedMax, requested))
            return routed(.setSpeed, value: clamped,
                          localText: String(format: tr("valcp.rame.speed.set"), dLabel, clamped))
        }
        if let fu = cmd.qualifierValue(locQual(en: "EB", fr: "FU"), min: 2) {
            let on = fu.uppercased() == "ON"
            return routed(on ? .fuSet : .fuRelease, localText: on
                ? String(format: tr("valcp.rame.fu.on"), dLabel)
                : String(format: tr("valcp.rame.fu.off"), dLabel))
        }
        // Console A22 (pupitre) -- exploitation controls, routed like the
        // panel's. KG/KACOP/AV/AR are cab labels, identical in both modes.
        if let kg = cmd.qualifierValue("KG", min: 2) {
            let on = kg.uppercased() == "ON"
            return routed(.pupitreKG, value: on ? 1 : 0, localText:
                String(format: tr("valcp.rame.kg"), dLabel,
                       on ? tr("valcp.rame.pupitre.on") : tr("valcp.rame.pupitre.off")))
        }
        if let rev = cmd.qualifierValue(locQual(en: "REVERSER", fr: "INVERSEUR"), min: 3) {
            let v: Double
            switch rev.uppercased() {
            case "AV", "+1", "1": v = 1
            case "AR", "-1":      v = -1
            case "0", "N", "NEUTRAL", "NEUTRE": v = 0
            default:
                return tr("valcp.rame.reverser.bad")
            }
            guard train.mode == .manual else {
                return String(format: tr("valcp.rame.pupitre.notmanual"), dLabel)
            }
            let name = v > 0 ? "AV" : (v < 0 ? "AR" : "0")
            return routed(.pupitreReverser, value: v, localText:
                String(format: tr("valcp.rame.reverser.set"), dLabel, name))
        }
        if let lev = cmd.qualifierValue(locQual(en: "LEVER", fr: "MANIPULATEUR"), min: 3),
           let pct = Double(lev) {
            guard train.mode == .manual else {
                return String(format: tr("valcp.rame.pupitre.notmanual"), dLabel)
            }
            let clamped = max(-100, min(100, pct))
            return routed(.pupitreLever, value: clamped / 100.0, localText:
                String(format: tr("valcp.rame.lever.set"), dLabel, clamped))
        }
        if cmd.hasQualifier("KACOP", min: 5) {
            return routed(.kacopAck, localText:
                String(format: tr("valcp.rame.kacop.ack"), dLabel))
        }
        if let kibs = cmd.qualifierValue("KIBS", min: 4) {
            let on = kibs.uppercased() == "ON"
            guard train.mode == .manual else {
                return String(format: tr("valcp.rame.pupitre.notmanual"), dLabel)
            }
            return routed(.pupitreKIBS, value: on ? 1 : 0, localText:
                String(format: tr("valcp.rame.kibs"), dLabel,
                       on ? tr("valcp.rame.pupitre.on") : tr("valcp.rame.pupitre.off")))
        }
        if let kph = cmd.qualifierValue("KPH", min: 3) {
            let on = kph.uppercased() == "ON"
            return routed(.pupitreKPH, value: on ? 1 : 0, localText:
                String(format: tr("valcp.rame.kph"), dLabel,
                       on ? tr("valcp.rame.pupitre.on") : tr("valcp.rame.pupitre.off")))
        }
        // AVP redundancy (DOT §3.5.2.15): string selection and the
        // comparison mode are remote exploitation commands. FR keeps the
        // French name of the equipment (PA, pilote automatique).
        if let avp = cmd.qualifierValue(locQual(en: "AVP", fr: "PA"), min: 2) {
            switch avp.uppercased() {
            case "A", "B":
                let toB = avp.uppercased() == "B"
                return routed(.avpSelect, value: toB ? 1 : 0, localText:
                    String(format: tr("valcp.rame.avp.string"), dLabel, toB ? "B" : "A"))
            default:
                return tr("valcp.rame.avp.bad")
            }
        }
        if let vote = cmd.qualifierValue(locQual(en: "VOTING", fr: "VOTE"), min: 4) {
            switch vote.uppercased() {
            case "AND", "ET":
                return routed(.avpVoting, value: 1, localText:
                    String(format: tr("valcp.rame.avp.voting"), dLabel, tr("valcp.rame.avp.and")))
            case "OR", "OU":
                return routed(.avpVoting, value: 0, localText:
                    String(format: tr("valcp.rame.avp.voting"), dLabel, tr("valcp.rame.avp.or")))
            default:
                return tr("valcp.rame.avp.bad")
            }
        }
        // Latched fault points and tires model the owning node's physical
        // rolling stock -- owner-only by design (no wire command exists).
        guard isLocal else {
            return String(format: tr("valcp.rame.owneronly"), dLabel)
        }
        // Each maps a French and an English qualifier spelling to one Train
        // flag; only the current-language spelling is accepted.
        let faultMap: [(fr: String, en: String, set: (inout Train, Bool) -> Void, key: String)] = [
            ("PORTES",   "DOOR",   { $0.isDoorFault = $1 },   "valcp.rame.fault.portes"),
            ("TRACTION", "ENGINE", { $0.isEngineFault = $1 }, "valcp.rame.fault.traction"),
            ("FREIN",    "BRAKE",  { $0.isBrakeFault = $1 },  "valcp.rame.fault.frein"),
            ("CTC",      "SIGNAL", { $0.isSignalFault = $1 }, "valcp.rame.fault.ctc"),
            ("PATINAGE", "SLIP",   { $0.isPatinage = $1 },    "valcp.rame.fault.patinage"),
            ("ENRAYAGE", "SLIDE",  { $0.isEnrayage = $1 },    "valcp.rame.fault.enrayage"),
            ("CHAINEA",  "STRINGA", { $0.avpStringAFault = $1 }, "valcp.rame.fault.avpa"),
            ("CHAINEB",  "STRINGB", { $0.avpStringBFault = $1 }, "valcp.rame.fault.avpb"),
        ]
        for entry in faultMap {
            let name = locQual(en: entry.en, fr: entry.fr)
            if let v = cmd.qualifierValue(name, min: min(3, name.count)) {
                let on = v.uppercased() == "ON"
                world.mutate(train.id) { entry.set(&$0, on) }
                return String(format: tr(entry.key), dLabel,
                              on ? tr("valcp.rame.fault.set") : tr("valcp.rame.fault.cleared"))
            }
        }
        if let tireStr = cmd.qualifierValue(locQual(en: "TIRE", fr: "PNEU"), min: 4),
           let n = Int(tireStr) {
            guard (1...Sim.tireCount).contains(n) else {
                return String(format: tr("valcp.rame.pneu.range"), Sim.tireCount)
            }
            world.mutate(train.id) { $0.cycleTireStatus(at: n - 1) }
            let after = world.findTrain(label: dLabel)?.tires[n - 1].status ?? .ok
            return String(format: tr("valcp.rame.pneu.cycled"), dLabel, n, tireStatusName(after))
        }
        return tr("valcp.rame.missqual")
    }

    /// Localized display name for a tire state (raw values are wire
    /// identifiers, not display text).
    func tireStatusName(_ status: Train.Tire.TireStatus) -> String {
        switch status {
        case .ok:          return tr("train.tire.ok")
        case .lowPressure: return tr("train.tire.low")
        case .puncture:    return tr("train.tire.puncture")
        case .burst:       return tr("train.tire.burst")
        }
    }
}
