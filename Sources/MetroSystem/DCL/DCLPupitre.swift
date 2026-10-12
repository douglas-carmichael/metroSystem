import Foundation

// SHOW PUPITRE / SET PUPITRE -- the operator surface of the pupitre link
// (Networking/PupitreLink.swift): the VALPupitreSim cabs this node finds and
// drives as their PCC.
//
// Like HARDWARE and MODBUS, PUPITRE is fixed CLI vocabulary (a
// language-neutral identifier keyword, not language-gated); the display text
// localizes as LPD layered-product content. The link is per-process, so the
// verbs talk to PupitreLink.shared.
extension DCLEngine {

    /// SHOW PUPITRE -- discovery, the line lent to cabs, and every cab found:
    /// link, COMMANDE position, control, line, motion and last refusal.
    func showPupitre() -> String {
        let link = PupitreLink.shared

        var s = "\n  " + tr("cablink.title") + "\n"
        let discovery: String
        switch link.discovery {
        case .stopped:         discovery = tr("cablink.discovery.stopped")
        case .browsing:        discovery = tr("cablink.discovery.browsing")
        case .failed(let why): discovery = String(format: tr("cablink.discovery.failed"), why)
        }
        s += "  " + String(format: tr("cablink.discovery"), PupitreWire.serviceType, discovery) + "\n"
        s += "  " + String(format: tr("cablink.line"), link.lineName, link.lineID,
                           Sim.trackLength, Sim.stationLayout.count, Sim.cantonCount) + "\n"
        if !link.addresses.isEmpty {
            let list = link.addresses.map { "\($0.host) port \($0.port)" }.joined(separator: ", ")
            s += "  " + tr("cablink.addresses") + " \(list)\n"
        }

        if link.cabs.isEmpty {
            s += "\n  " + tr("cablink.none") + "\n"
        }
        for cab in link.cabs {
            s += "\n  RAME \(cab.rame ?? "---")  \(cab.name ?? "")\n"
            s += "    \(cab.address)  "
                + tr(cab.viaBonjour ? "cablink.via.bonjour" : "cablink.via.address") + "\n"

            let state: String
            switch cab.link {
            case .connecting: state = tr("cablink.state.connecting")
            case .ready:      state = tr("cablink.state.ready")
            case .down:       state = tr("cablink.state.down")
            }
            let command = cab.authority.map { tr($0 == "pcc" ? "cablink.cmd.pcc" : "cablink.cmd.local") } ?? "--"
            let control = cab.controlledHere ? tr("cablink.ctl.here") : (cab.holder ?? "--")
            s += "    " + tr("cablink.link") + ": \(state)   "
                + tr("cablink.command") + ": \(command)   "
                + tr("cablink.control") + ": \(control)\n"

            let line: String
            switch cab.lineID {
            case nil:                  line = "--"
            case link.lineID?:         line = tr("cablink.line.on")
            case "test-track"?:        line = tr("cablink.line.test")
            case let other?:           line = String(format: tr("cablink.line.other"), other)
            }
            s += "    " + tr("cablink.online") + ": \(line)"
            if let position = cab.position, let speed = cab.speed {
                s += String(format: "   %.1f m  %.1f m/s", position, speed)
            }
            if let stop = cab.stopPointDistance {
                s += "   " + String(format: tr("cablink.stoppoint"), stop)
            }
            if cab.emergencyBrake { s += "   " + tr("btn.fu") }
            s += "\n"
            if let refusal = cab.lastRefusal {
                s += "    " + String(format: tr("cablink.refusal"), refusal) + "\n"
            }
        }
        s += "\n  " + tr("cablink.hint") + "\n"
        return s
    }

    /// SET PUPITRE rame /ACQUIRE [/FORCE] | /RELEASE
    ///             /ADD=(host[,port]) | /REMOVE=(host[,port])
    func setPupitre(_ cmd: Parsed) -> String {
        // SELFTEST never touches the cabs or the persisted addresses.
        if dryRun {
            return "%PUP-I-DRYRUN, would apply pupitre-link settings (no change made)\n"
        }
        let link = PupitreLink.shared
        let rame = cmd.positional.dropFirst().first
        var lines: [String] = []

        if let spec = cmd.qualifierValue("ADD", min: 3) {
            if let (host, port) = Self.cabAddress(spec), link.addAddress(host: host, port: port) {
                lines.append(String(format: tr("cablink.set.add"), host, Int(port)))
            } else {
                lines.append(tr("cablink.set.address.bad"))
            }
        }
        if let spec = cmd.qualifierValue("REMOVE", min: 3) {
            if let (host, port) = Self.cabAddress(spec), link.removeAddress(host: host, port: port) {
                lines.append(String(format: tr("cablink.set.remove"), host, Int(port)))
            } else {
                lines.append(tr("cablink.set.address.bad"))
            }
        }
        let acquire = cmd.hasQualifier("ACQUIRE", min: 3)
        let release = cmd.hasQualifier("RELEASE", min: 3)
        if acquire || release {
            if let rame {
                let force = cmd.hasQualifier("FORCE", min: 3)
                if acquire, link.acquire(rame: rame, force: force) {
                    lines.append(String(format: tr(force ? "cablink.set.force" : "cablink.set.acquire"), rame))
                } else if release, link.release(rame: rame) {
                    lines.append(String(format: tr("cablink.set.release"), rame))
                } else {
                    fail("PUP-W-NOSUCHCAB", "%X000080C1")
                    lines.append(String(format: tr("cablink.set.nosuchcab"), rame))
                }
            } else {
                lines.append(tr("cablink.set.needrame"))
            }
        }

        guard !lines.isEmpty else { return tr("cablink.set.missqual") + "\n" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "(host,port)", "(host)" or "host"; the port defaults to the cab's.
    private static func cabAddress(_ spec: String) -> (String, UInt16)? {
        let cleaned = spec.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let host = parts.first, !host.isEmpty else { return nil }
        guard let port = parts.count == 2 ? UInt16(parts[1]) : PupitreWire.defaultPort, port > 0 else {
            return nil
        }
        return (host, port)
    }
}
