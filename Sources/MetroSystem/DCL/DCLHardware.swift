import Foundation

// SHOW HARDWARE / SET HARDWARE -- the operator surface of the model-track
// hardware bridge (Hardware/HardwareBridge.swift).
//
// Like MODBUS, HARDWARE is fixed CLI vocabulary (language-neutral
// identifier keyword, not language-gated); the display text localizes as
// LPD layered-product content. The bridge is per-process (one physical
// layout per Mac, like the telnet port), so the verbs talk to
// HardwareBridge.shared rather than a per-engine reference.
extension DCLEngine {

    /// SHOW HARDWARE -- link status, endpoint, mapping, driver catalogue
    /// and the recent layout sensor events.
    func showHardware() -> String {
        let bridge = HardwareBridge.shared
        let cfg = bridge.config

        var s = "\n  " + tr("hardware.title") + "\n"
        if let d = bridge.selectedDescriptor {
            s += "  " + tr("hardware.driver") + ": \(d.id) -- \(d.name)\n"
        } else {
            s += "  " + tr("hardware.driver") + ": " + tr("hardware.nodriver") + "\n"
        }
        var link = tr(bridge.linkState.localizationKey)
        if let why = bridge.linkState.failureReason {
            link = String(format: link, why)
        }
        let output = tr(bridge.isEnabled ? "hardware.output.enabled" : "hardware.output.disabled")
        s += "  " + tr("hardware.link") + ": \(link)   " + tr("hardware.output") + ": \(output)\n"
        s += "  " + String(format: tr("hardware.endpoint"), cfg.host, Int(cfg.port)) + "\n"
        s += "  " + String(format: tr("hardware.stats"),
                           cfg.speedScale,
                           tr(cfg.resyncEnabled ? "sub.val.on" : "sub.val.off"),
                           bridge.framesSent) + "\n"

        s += "\n  " + tr("hardware.unitmap") + "\n"
        if cfg.unitMap.isEmpty {
            s += "    " + tr("hardware.unitmap.default") + "\n"
        } else {
            for (label, unit) in cfg.unitMap.sorted(by: { $0.key < $1.key }) {
                s += "    RAME \(label) -> \(unit)\n"
            }
            s += "    " + tr("hardware.unitmap.default") + "\n"
        }

        s += "\n  " + tr("hardware.drivers.available") + "\n"
        for d in bridge.registry.descriptors {
            let id = d.id.padding(toLength: 9, withPad: " ", startingAt: 0)
            s += "    \(id)\(d.summary)\n"
        }

        s += "\n  " + tr("hardware.sensors.recent") + " "
        if bridge.sensorLog.isEmpty {
            s += tr("hardware.sensors.none") + "\n"
        } else {
            s += "\n"
            for ev in bridge.sensorLog {
                let state = tr(ev.active ? "hardware.sensor.active" : "hardware.sensor.clear")
                s += "    \(stamp(ev.receivedAt))  S\(String(format: "%03d", ev.sensorId))  \(state)\n"
            }
        }
        s += "\n  " + tr("hardware.hint") + "\n"
        return s
    }

    /// SET HARDWARE /DRIVER=name /HOST=h /PORT=n /UNIT=(rame,unit)
    ///              /SCALE=x /RESYNC=ON|OFF /POWER=ON|OFF
    ///              /CONNECT /DISCONNECT /ENABLE /DISABLE
    ///
    /// Qualifiers compose left to right, so one line can configure and
    /// arm: SET HARDWARE/DRIVER=DCCEX/HOST=192.168.1.50/CONNECT/ENABLE.
    func setHardware(_ cmd: Parsed) -> String {
        // SELFTEST never touches the physical link or the persisted
        // config (same posture as EDIT / DIAGNOSE dry-run).
        if dryRun {
            return "%HW-I-DRYRUN, would apply hardware-link settings (no change made)\n"
        }
        let bridge = HardwareBridge.shared
        var lines: [String] = []

        if let id = cmd.qualifierValue("DRIVER", min: 3) {
            if bridge.selectDriver(id: id) {
                lines.append(String(format: tr("hardware.set.driver.ok"),
                                    bridge.config.driverId))
            } else {
                fail("HW-W-NOSUCHDRV", "%X000080B2")
                lines.append(String(format: tr("hardware.set.driver.bad"), id.uppercased()))
            }
        }
        let host = cmd.qualifierValue("HOST", min: 3)
        let port = cmd.qualifierValue("PORT", min: 3).flatMap { UInt16($0) }
        if host != nil || port != nil {
            bridge.setEndpoint(host: host, port: port)
            lines.append(String(format: tr("hardware.set.endpoint.ok"),
                                bridge.config.host, Int(bridge.config.port)))
        }
        if let spec = cmd.qualifierValue("UNIT", min: 4) {
            // Accept "(101,3)" to map and "(101)" / "101" to clear.
            let cleaned = spec.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, let unit = Int(parts[1]), unit > 0 {
                bridge.setUnitMapping(label: parts[0], unit: unit)
                lines.append(String(format: tr("hardware.set.unit.ok"), parts[0], unit))
            } else if parts.count == 1, !parts[0].isEmpty {
                bridge.setUnitMapping(label: parts[0], unit: nil)
                lines.append(String(format: tr("hardware.set.unit.clear"), parts[0]))
            } else {
                lines.append(tr("hardware.set.unit.bad"))
            }
        }
        if let scaleStr = cmd.qualifierValue("SCALE", min: 3), let scale = Double(scaleStr) {
            if bridge.setSpeedScale(scale) {
                lines.append(String(format: tr("hardware.set.scale.ok"), scale))
            } else {
                lines.append(tr("hardware.set.scale.bad"))
            }
        }
        if let re = cmd.qualifierValue("RESYNC", min: 3) {
            let on = re.uppercased() == "ON"
            bridge.setResync(on)
            lines.append(tr(on ? "hardware.set.resync.on" : "hardware.set.resync.off"))
        }
        if cmd.hasQualifier("CONNECT", min: 3) {
            if bridge.connect() {
                lines.append(String(format: tr("hardware.set.connect"),
                                    bridge.config.host, Int(bridge.config.port)))
            } else {
                lines.append(tr("hardware.set.noconnect"))
            }
        }
        if cmd.hasQualifier("DISCONNECT", min: 4) {
            bridge.disconnect()
            lines.append(tr("hardware.set.disconnect"))
        }
        if let pw = cmd.qualifierValue("POWER", min: 3) {
            let on = pw.uppercased() == "ON"
            if bridge.setTrackPower(on) {
                lines.append(tr(on ? "hardware.set.power.on" : "hardware.set.power.off"))
            } else {
                lines.append(tr("hardware.set.power.unsup"))
            }
        }
        if cmd.hasQualifier("ENABLE", min: 3) {
            if bridge.setEnabled(true) {
                lines.append(tr("hardware.set.enable.on"))
            } else {
                lines.append(tr("hardware.set.noconnect"))
            }
        }
        if cmd.hasQualifier("DISABLE", min: 4) {
            bridge.setEnabled(false)
            lines.append(tr("hardware.set.enable.off"))
        }

        guard !lines.isEmpty else { return tr("hardware.set.missqual") + "\n" }
        return lines.joined(separator: "\n") + "\n"
    }
}
