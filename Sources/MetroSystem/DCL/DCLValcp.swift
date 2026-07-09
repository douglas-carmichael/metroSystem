import Foundation

// VAL-CP -- LPD VAL Control Program.
//
// Top-level entry for the metro-control layered product, modelled on
// the real VMS layered-tool pattern (NCP for DECnet, LATCP for LAT, ...).
// A PCC operator types the program name first, then a subverb, then the
// noun keyword:
//
//      $ VALCP SHOW RAME 101
//      $ VALCP SHOW LIGNE
//      $ VALCP SET RAME 101 /MANUAL /SPEED=8
//      $ VALCP SET LIGNE /SP=(1,3,60)
//
// On a real OpenVMS host this would be a separately-linked image
// installed via SET COMMAND on a .CLD definition. Here it just shares
// the DCLEngine extension surface with every other verb.
//
// Convenience aliases (RAME, LIGNE, PAX, STATIONS, ...) are defined as
// foreign-command symbols in the seeded LOGIN.COM so a returning operator
// can type the short form. Symbol substitution in DCLEngine.execute()
// expands those aliases to VALCP ... before parsing.
//
// VALCP output is localised (EN / FR) because the vendor is French --
// same rationale as LPD-DIAG. The underlying VMS error facility names
// (VALCP-W-IVVERB, VALCP-W-MISSQUAL) stay English to look like a real
// VMS error code; the human-readable tail of each message localises.
extension DCLEngine {

    func valcpCmd(_ cmd: Parsed) -> String {
        guard let subverb = cmd.positional.first else {
            return valcpSynopsis()
        }
        // Strip the subverb so the downstream handler sees positional
        // = [<subject>, <args>...].
        let inner = Parsed(verb: subverb.uppercased(),
                           positional: Array(cmd.positional.dropFirst()),
                           qualifiers: cmd.qualifiers)
        switch true {
        case matches(subverb, "SHOW"):           return valcpShow(inner)
        case matches(subverb, "SET"):            return valcpSet(inner)
        case matches(subverb, "HELP"):           return valcpHelp()
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("valcp.err.ivverb"), subverb)
        }
    }

    private func valcpShow(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return tr("valcp.err.show.missqual")
        }
        switch true {
        case matches(what, "RAME"):              return showRameVALCP(cmd)
        case matches(what, "RAMES", min: 5):     return showFleet()
        case matchesLoc(what, en: "LINE", fr: "LIGNE", min: 4):
            return showLigneVALCP()
        case matches(what, "STATIONS", min: 4):  return showStationsVALCP()
        case matches(what, "PAX"):               return showPax()
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("valcp.err.show.ivkeyw"), what)
        }
    }

    private func valcpSet(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return tr("valcp.err.set.missqual")
        }
        switch true {
        case matches(what, "RAME"):              return setRame(cmd)
        case matchesLoc(what, en: "LINE", fr: "LIGNE", min: 4):
            return setLigne(cmd)
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return String(format: tr("valcp.err.set.ivkeyw"), what)
        }
    }

    /// VALCP SHOW RAME [label] -- per-rame status sheet, or the fleet
    /// table when no label is supplied.
    func showRameVALCP(_ cmd: Parsed) -> String {
        guard let label = cmd.positional.dropFirst().first else {
            return showFleet()
        }
        guard let world else { return "%SHOW-W-NOWORLD, metro world not attached\n" }
        guard let t = world.findTrain(label: label) else {
            fail("SHOW-W-NOSUCHRAME", "%X000080A4")
            return "%SHOW-W-NOSUCHRAME, no such rame \\\(label)\\\n"
        }
        let statusKey: String
        switch t.status {
        case .stopped:   statusKey = "valcp.status.stopped"
        case .moving:    statusKey = "valcp.status.moving"
        case .emergency: statusKey = "valcp.status.emergency"
        case .docked:    statusKey = "valcp.status.docked"
        }
        let modeKey = t.mode == .auto ? "valcp.mode.auto" : "valcp.mode.manual"
        let doorKey = t.doorsOpen ? "valcp.door.open" : "valcp.door.closed"
        let cantonName = world.canton(at: t.position).map { blockName($0.id) } ?? "--"
        let dirKey = t.travelDirection == .forward ? "valcp.dir.forward" : "valcp.dir.reverse"

        var faults: [String] = []
        if t.isDoorFault   { faults.append(tr("fault.portes")) }
        if t.isEngineFault { faults.append(tr("fault.traction")) }
        if t.isBrakeFault  { faults.append(tr("fault.frein")) }
        if t.isSignalFault { faults.append(tr("fault.ctc")) }
        if t.isPatinage    { faults.append(tr("fault.patinage")) }
        if t.isEnrayage    { faults.append(tr("fault.enrayage")) }
        if t.isEmergencyBrakeApplied { faults.append(tr("btn.fu")) }
        let faultStr = faults.isEmpty ? tr("valcp.rame.nofault") : faults.joined(separator: ", ")
        let ownerKey = world.canControl(t) ? "valcp.owner.local" : "valcp.owner.remote"

        var s = String(format: tr("valcp.rame.title"), t.label, stamp(Date()))
        s += String(format: "%@%8.1f m   (%@)\n", tr("valcp.rame.position"), t.position, cantonName)
        s += String(format: "%@%6.2f m/s  (%@ %5.2f m/s)\n", tr("valcp.rame.speed"), t.speed,
                    tr("valcp.rame.consigne"), t.consigneVitesse)
        s += String(format: "%@%8.1f m\n", tr("valcp.rame.ma"), t.distanceToMA)
        s += tr("valcp.rame.direction") + tr(dirKey) + "\n"
        s += tr("valcp.rame.status")    + tr(statusKey) + "\n"
        s += tr("valcp.rame.mode")      + tr(modeKey) + "\n"
        s += tr("valcp.rame.doors")     + tr(doorKey) + "\n"
        s += tr("valcp.rame.owner")     + tr(ownerKey) + "\n"
        s += String(format: tr("valcp.rame.pax") + "\n", t.passengerCount, Sim.paxCapacity)
        s += tr("valcp.rame.nextstop")  + t.nextStationName + "\n"
        s += String(format: "%@%6.0f V   %@%7.0f A\n", tr("valcp.rame.voltage"), t.mainVoltage,
                    tr("valcp.rame.traction"), t.tractionCurrent)
        s += tr("valcp.rame.faults")    + faultStr + "\n"
        // Tire block: eight positions, VMS-table style.
        s += tr("valcp.rame.tires")
        for tire in t.tires {
            s += String(format: "\n      %2d   %4.1f bar   %@", tire.id, tire.pressure, tireStatusName(tire.status))
        }
        s += "\n"
        return s
    }

    /// Fleet summary table shared by VALCP SHOW RAME (no label) and
    /// SHOW RAMES. The Own column marks each rame L (this node) or R
    /// (peer-owned).
    func showFleet() -> String {
        guard let world else { return "%SHOW-W-NOWORLD, metro world not attached\n" }
        var s = "\n" + String(format: tr("valcp.fleet.title"), stamp(Date())) + "\n"
        s += tr("valcp.fleet.header")
        s += tr("valcp.fleet.sep")
        let trains = world.sortedTrains
        if trains.isEmpty {
            s += tr("valcp.fleet.none")
            return s
        }
        for t in trains {
            let canton = world.canton(at: t.position).map { blockName($0.id) } ?? "--"
            let mode = t.mode == .auto ? tr("valcp.fleet.mode.auto") : tr("valcp.fleet.mode.manual")
            let status: String
            switch t.status {
            case .stopped:   status = tr("valcp.fleet.status.stopped")
            case .moving:    status = tr("valcp.fleet.status.moving")
            case .emergency: status = tr("valcp.fleet.status.emergency")
            case .docked:    status = tr("valcp.fleet.status.docked")
            }
            let doors = t.doorsOpen ? tr("valcp.fleet.doors.open") : tr("valcp.fleet.doors.closed")
            let own = world.canControl(t) ? "L" : "R"
            s += String(format: "    %-5@ %@ %8.1f  %-10@ %6.2f  %8.1f  %@  %@  %@  %4d\n",
                        t.label as NSString,
                        own,
                        t.position,
                        canton as NSString,
                        t.speed,
                        t.distanceToMA,
                        mode, status, doors,
                        t.passengerCount)
        }
        return s
    }

    /// VALCP SHOW LIGNE -- one-screen summary of line-wide state.
    func showLigneVALCP() -> String {
        guard let world else { return "%SHOW-W-NOWORLD, metro world not attached\n" }
        let mode: String
        switch world.lineMode {
        case .stopped:           mode = tr("valcp.ligne.mode.stopped")
        case .normal:            mode = tr("valcp.ligne.mode.normal")
        case .serviceProvisoire: mode = tr("valcp.ligne.mode.sp")
        case .emergency:         mode = tr("valcp.ligne.mode.emergency")
        }
        var s = String(format: tr("valcp.ligne.title"), stamp(Date()))
        s += tr("valcp.ligne.mode") + mode + "\n"
        if let sp = world.activeSP {
            s += String(format: tr("valcp.ligne.spdetail") + "\n",
                        world.stationName(id: sp.startStationId),
                        world.stationName(id: sp.endStationId),
                        Int(sp.intervalle))
        }
        s += String(format: tr("valcp.ligne.geometry") + "\n", Sim.cantonCount, Int(Sim.trackLength))
        s += String(format: tr("valcp.ligne.rames"), world.locallyOwned().count, Sim.maxTrainCount)
        s += String(format: tr("valcp.ligne.remote"), world.trains.count - world.locallyOwned().count)
        return s
    }

    /// VALCP SHOW STATIONS -- station list with position and the next
    /// approaching rame (by directed distance).
    func showStationsVALCP() -> String {
        guard let world else { return "%SHOW-W-NOWORLD, metro world not attached\n" }
        var s = "\n" + String(format: tr("valcp.stations.title"), stamp(Date())) + "\n"
        s += tr("valcp.stations.header")
        s += tr("valcp.stations.sep")
        let active = world.activeStations()
        for station in world.stations {
            let served = active.contains(station)
            // Nearest approaching rame: smallest positive gap in each
            // train's running direction.
            var best: (label: String, dist: Double)? = nil
            for t in world.trains {
                var d = t.travelDirection == .forward
                    ? station.position - t.position
                    : t.position - station.position
                if d < 0 { d += Sim.trackLength }
                if best == nil || d < best!.dist {
                    best = (t.label, d)
                }
            }
            let nextStr: String
            if !served {
                nextStr = tr("valcp.stations.barred")
            } else if let b = best {
                nextStr = String(format: tr("valcp.stations.approach"), b.label, b.dist)
            } else {
                nextStr = tr("valcp.stations.none")
            }
            s += String(format: "    %2d  %-22@ %7.0f m   %@\n",
                        station.id, station.name as NSString, station.position, nextStr)
        }
        return s
    }

    /// VALCP SHOW PAX -- per-rame passenger load against nominal capacity.
    func showPax() -> String {
        guard let world else { return "%SHOW-W-NOWORLD, metro world not attached\n" }
        var s = String(format: tr("valcp.pax.title"), stamp(Date()))
        s += tr("valcp.pax.header")
        s += tr("valcp.pax.sep")
        let trains = world.sortedTrains
        if trains.isEmpty {
            s += tr("valcp.pax.none")
            return s
        }
        for t in trains {
            let pct = Double(t.passengerCount) / Double(Sim.paxCapacity) * 100.0
            let stateKey: String
            if pct >= 100     { stateKey = "valcp.pax.state.crush" }
            else if pct >= 80 { stateKey = "valcp.pax.state.full" }
            else if pct < 5   { stateKey = "valcp.pax.state.empty" }
            else              { stateKey = "valcp.pax.state.nominal" }
            s += String(format: "    %-5@  %4d      %4d   %5.1f%%   %@\n",
                        t.label as NSString, t.passengerCount, Sim.paxCapacity, pct, tr(stateKey))
        }
        return s
    }

    /// Localized track-block name ("Block 3" / "Canton 3").
    func blockName(_ id: Int) -> String {
        String(format: tr("block.name"), id)
    }

    private func valcpSynopsis() -> String {
        return tr("valcp.synopsis") + "\n"
    }

    private func valcpHelp() -> String {
        return valcpSynopsis() + tr("valcp.help.body") + "\n"
    }
}
