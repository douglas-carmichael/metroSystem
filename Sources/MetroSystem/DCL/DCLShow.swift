import Foundation

// SHOW family of commands -- one entry per `SHOW <keyword>` subcommand.
// All methods are extensions of the main DCLEngine class so they share
// state (`world`, `host`, `username` ...) directly.
extension DCLEngine {
    func showCmd(_ cmd: Parsed) -> String {
        guard let what = cmd.positional.first else {
            return missQual("SHOW")
        }
        switch true {
        case matches(what, "PROCESS",     min: 4): return showProcess(cmd)
        case matches(what, "SYSTEM",      min: 3): return showSystem()
        case matches(what, "USERS",       min: 4): return showUsers()
        case matches(what, "DEVICES",     min: 3): return showDevices()
        case matches(what, "MEMORY",      min: 3): return showMemory()
        case matches(what, "MODBUS",      min: 3): return showModbus()
        case matches(what, "HARDWARE",    min: 4): return showHardware()
        case matches(what, "BACKEND",     min: 4): return showBackend()
        case matches(what, "PRATIC",      min: 4): return showPratic()
        case matches(what, "TIME"):                return showTime()
        case matches(what, "NETWORK",     min: 3): return showNetwork()
        case matches(what, "RAMES",       min: 4): return showFleet()
        case matches(what, "RAME"):                return showRameVALCP(cmd)
        case matchesLoc(what, en: "LINE", fr: "LIGNE", min: 4):
            return showLigneVALCP()
        case matches(what, "STATIONS",    min: 4): return showStationsVALCP()
        case matches(what, "PAX"):                 return showPax()
        case matches(what, "ALARMS",      min: 3): return showAlarms(cmd)
        case matches(what, "LOGICAL",     min: 3): return showLogical(cmd)
        case matches(what, "SYMBOL",      min: 3): return showSymbol(cmd)
        case matches(what, "ERROR",       min: 3): return showError()
        case matches(what, "STATUS",      min: 4): return showStatus()
        case matches(what, "LICENSE",     min: 3): return showLicense()
        case matches(what, "CPU"):                 return showCPU()
        case matches(what, "DEFAULT",     min: 3): return showDefault()
        case matches(what, "QUOTA",       min: 4): return showQuota()
        case matches(what, "PROTECTION",  min: 4): return showProtection()
        case matches(what, "TERMINAL",    min: 4): return showTerminal()
        case matches(what, "WORKING_SET", min: 4): return showWorkingSet()
        case matches(what, "VERSION",     min: 3): return showVersion()
        case matches(what, "RMS_DEFAULT", min: 3): return showRMS()
        case matches(what, "INTRUSION",   min: 3): return showIntrusion()
        case matches(what, "CLUSTER",     min: 3): return showCluster()
        case matches(what, "CONNECTIONS", min: 4): return showConnections()
        case matches(what, "AUDIT",       min: 3): return showAudit()
        case matches(what, "DIAGNOSTICS", min: 4): return showDiagnostics()
        default:
            fail("DCL-W-IVKEYW", "%X00038088")
            return "%DCL-W-IVKEYW, unrecognized keyword - check validity and spelling\n   \\\(what)\\\n"
        }
    }

    func showAlarms(_ cmd: Parsed) -> String {
        // Default view mirrors the annunciator/panel: only standing
        // (uncleared, unshelved) alarms, priority-sorted. /ALL dumps the full
        // journal -- RTN / CLEARED / SHLVD history included -- for audit. This
        // is why CLEAR ALL empties the default list but the history survives.
        let showAll = cmd.hasQualifier("ALL", min: 3)
        let alarms = showAll ? (world?.alarmLog ?? []) : (world?.activeAlarms ?? [])
        var s = "\n" + String(format: tr(showAll ? "dcl.alarm.title" : "dcl.alarm.title.active"), stamp(Date())) + "\n"
        s += tr("dcl.alarm.header") + "\n"
        s += "  ----  ---------------------------  ---------  -------  ---------  -------------  ------------------------------\n"
        guard !alarms.isEmpty else {
            s += tr(showAll ? "dcl.alarm.none" : "dcl.alarm.none.active") + "\n"
            return s
        }
        for alarm in alarms.prefix(40) {
            let id = String(format: "%04d", alarm.sequence)
            // stamp() returns 23 chars ("dd-MMM-yyyy HH:mm:ss.SS"); the
            // Time column dashes reserve 27. Pad so Severity lines up.
            let time = stamp(alarm.raisedAt).padding(toLength: 27, withPad: " ", startingAt: 0)
            let sev = alarmSeverityLabel(alarm.severity).padding(toLength: 9, withPad: " ", startingAt: 0)
            let state = alarmStatusLabel(alarm).padding(toLength: 7, withPad: " ", startingAt: 0)
            let source = alarm.source.padding(toLength: 9, withPad: " ", startingAt: 0)
            let point = alarm.point.padding(toLength: 13, withPad: " ", startingAt: 0)
            s += "  \(id)  \(time)  \(sev)  \(state)  \(source)  \(point)  \(alarmMessage(alarm.message))\n"
        }
        s += "\n" + tr("dcl.alarm.ackhint") + "\n"
        // In the active view, point the operator at /ALL for cleared history.
        if !showAll { s += tr("dcl.alarm.allhint") + "\n" }
        return s
    }

    private func alarmSeverityLabel(_ severity: AlarmSeverity) -> String {
        switch severity {
        case .advisory: return tr("alarm.sev.advisory")
        case .minor: return tr("alarm.sev.minor")
        case .major: return tr("alarm.sev.major")
        case .critical: return tr("alarm.sev.critical")
        }
    }

    private func alarmStatusLabel(_ alarm: SCADAAlarm) -> String {
        // Mirrors SCADAAlarm.statusLabel precedence with localized text.
        if alarm.isShelved { return tr("alarm.status.shlvd") }
        if alarm.clearedAt != nil {
            return alarm.isAcknowledged ? tr("alarm.status.cleared") : tr("alarm.status.rtn")
        }
        return alarm.isAcknowledged ? tr("alarm.status.ack") : tr("alarm.status.unack")
    }

    /// Alarm messages are stored in English (the log is in-universe VMS
    /// output); localize known messages for display.
    func alarmMessage(_ message: String) -> String {
        for key in Strings.alarmMessageKeys {
            if message == Strings.lookup(key, lang: .en) { return tr(key) }
        }
        return message
    }

    func showProcess(_ cmd: Parsed) -> String {
        let now = Date()
        let upS = Int(host.uptime())
        var s = "\n\(stamp(now))   User: \(username.padding(toLength: 12, withPad: " ", startingAt: 0))   Process ID:   \(pid)\n"
        s += "                          Node: \(nodeName.padding(toLength: 8, withPad: " ", startingAt: 0))       Process name: \"DCL_\(username)\"\n\n"
        s += "Terminal:            \(terminalName)\n"
        s += "User Identifier:     [METRO,\(username)]\n"
        s += "Base priority:       4\n"
        s += "Default file spec:   \(defaultDevice)\(defaultDirectory)\n"
        s += "Devices allocated:   none\n\n"
        s += "Process Quotas:\n"
        s += " Account name:                  PCC_ROOM\n"
        s += " CPU limit:                     Infinite       Direct I/O limit:      150\n"
        s += " Buffered I/O byte count quota: 65536          Buffered I/O limit:    150\n"
        s += " Timer queue entry quota:       20             Open file quota:       100\n"
        s += " Paging file quota:             50000          Subprocess quota:      8\n"
        s += " Default page fault cluster:    64             AST quota:             250\n"
        s += " Enqueue quota:                 200            Shared file limit:     0\n"
        s += " Max detached processes:        0              Max active jobs:       0\n\n"
        s += "Accounting information:\n"
        s += String(format: " Buffered I/O count:            %-12d  Peak working set size:    1648\n", upS / 4)
        s += String(format: " Direct I/O count:              %-12d  Peak page file size:     20384\n", upS / 8)
        s += String(format: " Page faults:                   %-12d  Mounted volumes:             0\n", upS / 2)
        s += " Images activated:              3\n"
        s += String(format: " Elapsed CPU time:              0 00:%02d:%02d.%02d\n",
                    (upS / 60) % 60, upS % 60, (upS * 7) % 100)
        s += String(format: " Connect time:                  %@\n", uptimeString(from: bootTime, to: now))
        if cmd.hasQualifier("ALL", min: 1) {
            s += "\nProcess rights:\n"
            s += "  INTERACTIVE\n"
            s += "  LOCAL\n"
            s += "  PCC_OPERATOR\n"
            s += "System rights:\n"
            s += "  SYS$NODE_\(nodeName)\n"
        }
        return s
    }

    func showSystem() -> String {
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(sessionStart))
        let uptime = uptimeString(from: bootTime, to: now)
        let loads = host.loadAverages()
        let procCount = host.processCount()
        var s = "\n\(osTitle) \(osVersion) on node \(nodeName)  \(stamp(now))  Uptime  \(uptime)\n"
        s += String(format: "  Load average: %.2f  %.2f  %.2f    Active processes: %d\n",
                    loads.one, loads.five, loads.fifteen, procCount)
        s += "  Pid    Process Name      State  Pri      I/O       CPU       Page flts Pages\n"

        // Synthetic process model: each row defines a baseline plus growth
        // rates so I/O, CPU time and page-fault counters tick upward on
        // every SHOW SYSTEM refresh, page counts oscillate around their
        // working-set baseline, and LEF processes flicker briefly to COM
        // as if they were waking to service a request -- the table looks
        // like a live VMS box instead of a frozen snapshot.
        for p in Self.backgroundProcs {
            s += renderSysProc(p, elapsed: elapsed)
        }

        let trains = world?.sortedTrains ?? []
        for (i, train) in trains.prefix(6).enumerated() {
            let trainPid = String(format: "%08X", 0x040A + i)
            let name = "RAME_\(train.label)_OBCU"
            // Live rame state takes precedence: doors open means the task
            // is in LEF (waiting for the dwell timer); a moving rame is
            // COM; an idle stationary rame is HIB.
            let liveState = train.doorsOpen ? "LEF" :
                            (train.speed < 0.05 ? "HIB" : "COM")
            let phase = Double(i) * 1.7
            let ioBase = 800 + i * 47
            let ioJitter = Int(sin(elapsed / 5.3 + phase) * 14)
            let io = ioBase + Int(0.9 * elapsed) + ioJitter
            let cpuBase = Double(12 + i) + Double((i * 17 + 9) % 100) / 100.0
            let cpu = cpuBase + 0.045 * elapsed
            let flts = 320 + i * 18 + Int(0.18 * elapsed)
            let pgsJitter = Int(sin(elapsed / 7.1 + phase) * 22)
            let pgs = 610 + i * 8 + pgsJitter
            s += sysLine(trainPid, name, liveState, 6, io, formatVMSCPUTime(cpu), flts, max(0, pgs))
        }

        for p in Self.serviceProcs {
            s += renderSysProc(p, elapsed: elapsed)
        }

        // The operator's own DCL process: CUR (current) so the table
        // always ends with the row the user is typing from.
        let userName = "DCL_" + String(username.prefix(12))
        let userIO   = 21 + Int(0.3 * elapsed)
        let userCPU  = 0.18 + 0.0008 * elapsed
        let userFlts = 24 + Int(0.05 * elapsed)
        let userPgs  = 148 + Int(sin(elapsed / 4.2) * 7)
        s += sysLine(pid, userName, "CUR", 4, userIO, formatVMSCPUTime(userCPU), userFlts, max(0, userPgs))
        return s
    }

    private func sysLine(_ pid: String, _ name: String, _ state: String, _ pri: Int, _ io: Int, _ cpu: String, _ faults: Int, _ pages: Int) -> String {
        let padName = name.padding(toLength: 16, withPad: " ", startingAt: 0)
        return "\(pid) \(padName) \(state)    \(String(format: "%2d", pri))   \(String(format: "%6d", io))   \(cpu)       \(String(format: "%4d", faults))  \(String(format: "%4d", pages))\n"
    }

    /// Synthetic-process descriptor. Baseline values come from a typical
    /// snapshot of an active node; the rates produce believable per-second
    /// growth so the table looks alive on repeated SHOW SYSTEM.
    struct SysProc {
        let pid: String
        let name: String
        let baseState: String
        let pri: Int
        let ioBase: Int
        let ioRate: Double         // I/O ops per second
        let cpuBaseSec: Double     // CPU seconds at session start
        let cpuRate: Double        // CPU share (0..1) of wall time
        let faultBase: Int
        let faultRate: Double      // page faults per second
        let pagesBase: Int
        let pagesAmp: Int          // working-set oscillation amplitude
    }

    /// Background VAL-CTRL / VMS system tasks shown above the rame
    /// process block.
    static let backgroundProcs: [SysProc] = [
        SysProc(pid: "00000401", name: "SWAPPER",       baseState: "HIB", pri: 16,
                ioBase: 0,    ioRate: 0,    cpuBaseSec: 1.21,    cpuRate: 0.00005,
                faultBase: 0,    faultRate: 0,    pagesBase: 0,    pagesAmp: 0),
        SysProc(pid: "00000402", name: "NULL",          baseState: "COM", pri: 0,
                ioBase: 0,    ioRate: 0,    cpuBaseSec: 259_200, cpuRate: 0.55,
                faultBase: 0,    faultRate: 0,    pagesBase: 0,    pagesAmp: 0),
        SysProc(pid: "00000403", name: "VAL_PILOT",     baseState: "LEF", pri: 8,
                ioBase: 4823, ioRate: 1.7,  cpuBaseSec: 92.14,   cpuRate: 0.012,
                faultBase: 1842, faultRate: 0.4, pagesBase: 3104, pagesAmp: 64),
        SysProc(pid: "00000404", name: "PCC_DISPATCH",  baseState: "LEF", pri: 7,
                ioBase: 2204, ioRate: 0.9,  cpuBaseSec: 48.21,   cpuRate: 0.0060,
                faultBase: 412, faultRate: 0.12, pagesBase: 1480, pagesAmp: 40),
        SysProc(pid: "00000405", name: "ZC_SECTEUR_1",  baseState: "LEF", pri: 6,
                ioBase: 1187, ioRate: 0.5,  cpuBaseSec: 24.04,   cpuRate: 0.0030,
                faultBase: 284, faultRate: 0.08, pagesBase: 720, pagesAmp: 24),
        SysProc(pid: "00000406", name: "PORTES_SVC",    baseState: "LEF", pri: 6,
                ioBase: 942,  ioRate: 0.35, cpuBaseSec: 18.42,   cpuRate: 0.0025,
                faultBase: 212, faultRate: 0.06, pagesBase: 612, pagesAmp: 20),
        SysProc(pid: "00000407", name: "FREIN_MON",     baseState: "HIB", pri: 7,
                ioBase: 84,   ioRate: 0.04, cpuBaseSec: 2.18,    cpuRate: 0.0003,
                faultBase: 48, faultRate: 0.01, pagesBase: 180, pagesAmp: 12),
        SysProc(pid: "00000408", name: "PNEU_MON",      baseState: "HIB", pri: 6,
                ioBase: 62,   ioRate: 0.03, cpuBaseSec: 1.42,    cpuRate: 0.00025,
                faultBase: 38, faultRate: 0.008, pagesBase: 148, pagesAmp: 10),
        SysProc(pid: "00000409", name: "LOGGER",        baseState: "LEF", pri: 4,
                ioBase: 208,  ioRate: 0.18, cpuBaseSec: 4.81,    cpuRate: 0.0008,
                faultBase: 72, faultRate: 0.02, pagesBase: 246, pagesAmp: 16),
    ]

    /// Radio / CTC / maintenance services shown below the rame block.
    static let serviceProcs: [SysProc] = [
        SysProc(pid: "00000414", name: "CTC_RADIOSRV",  baseState: "LEF", pri: 6,
                ioBase: 612,  ioRate: 0.5,  cpuBaseSec: 8.71,    cpuRate: 0.0014,
                faultBase: 412, faultRate: 0.18, pagesBase: 1024, pagesAmp: 32),
        SysProc(pid: "00000415", name: "QUAI_AFFSRV",   baseState: "LEF", pri: 6,
                ioBase: 144,  ioRate: 0.12, cpuBaseSec: 1.95,    cpuRate: 0.0003,
                faultBase: 108, faultRate: 0.04, pagesBase: 384, pagesAmp: 16),
        SysProc(pid: "00000416", name: "MAINT_AGENT",   baseState: "HIB", pri: 4,
                ioBase: 72,   ioRate: 0.06, cpuBaseSec: 0.94,    cpuRate: 0.0001,
                faultBase: 36, faultRate: 0.02, pagesBase: 158, pagesAmp: 10),
    ]

    private func renderSysProc(_ p: SysProc, elapsed: Double) -> String {
        let io  = p.ioBase + Int(p.ioRate * elapsed)
        let cpu = p.cpuBaseSec + p.cpuRate * elapsed
        let flt = p.faultBase + Int(p.faultRate * elapsed)
        // Stable per-process phase derived from the PID so two processes
        // don't oscillate in lockstep.
        let phase = Double(abs(p.pid.hashValue) % 360) * .pi / 180.0
        let pgs  = p.pagesBase + Int(sin(elapsed / 6.0 + phase) * Double(p.pagesAmp))
        // LEF (local-event-flag wait) processes occasionally flicker to COM
        // for a 2-tick burst as if they were waking to service a request.
        let bucket = (Int(elapsed * 0.3) + abs(p.pid.hashValue)) % 20
        let state  = (p.baseState == "LEF" && bucket < 2) ? "COM" : p.baseState
        return sysLine(p.pid, p.name, state, p.pri, io, formatVMSCPUTime(cpu), flt, max(0, pgs))
    }

    /// VMS-style CPU-time string: "<days> <hh>:<mm>:<ss>.<NN>" using
    /// hundredths for the fractional part, matching real `SHOW SYSTEM`.
    func formatVMSCPUTime(_ seconds: Double) -> String {
        let clamp = max(0, seconds)
        let total = Int(clamp * 100)
        let hundredths = total % 100
        let totalSec = total / 100
        let d = totalSec / 86_400
        let h = (totalSec % 86_400) / 3600
        let m = (totalSec % 3600) / 60
        let ss = totalSec % 60
        return String(format: "%d %02d:%02d:%02d.%02d", d, h, m, ss, hundredths)
    }

    func showUsers() -> String {
        var s = "\n       OpenVMS User Processes at \(stamp(Date()))\n"
        s += "       Total number of users = \(1 + (network?.peers.count ?? 0)), number of processes = \((world?.trains.count ?? 0) + 4)\n\n"
        s += "  Username     Process Name         PID      Terminal\n"
        s += "  \(username.padding(toLength: 12, withPad: " ", startingAt: 0)) DCL_\(username.prefix(12).padding(toLength: 16, withPad: " ", startingAt: 0)) \(pid) \(terminalName)\n"
        for (i, peer) in (network?.peers ?? []).enumerated() {
            let upper = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
            let uname = String(upper.prefix(12)).padding(toLength: 12, withPad: " ", startingAt: 0)
            let pname = "DCL_" + String(upper.prefix(12)).padding(toLength: 16, withPad: " ", startingAt: 0)
            let ppid = String(format: "%08X", 0x0500 + i)
            s += "  \(uname) \(pname) \(ppid) TT$NTA00\(i + 1):\n"
        }
        return s
    }

    func showDevices() -> String {
        // Column layout (fixed widths so values can't crowd the next
        // column even when the disk is multi-terabyte and free-block
        // counts run to 11 digits). Swift's String(format:) ignores
        // width on %@, so do the padding ourselves.
        func padLeft(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        func padRight(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
        }
        func row(_ name: String, _ status: String, _ err: String,
                 _ label: String, _ free: String, _ trans: String, _ mnt: String) -> String {
            return padLeft(name,   16) + " "
                +  padLeft(status, 10) + " "
                +  padRight(err,    5) + "  "
                +  padLeft(label,  18) + " "
                +  padRight(free,  14) + " "
                +  padRight(trans,  6) + " "
                +  padRight(mnt,    4) + "\n"
        }
        var s = "\n"
        s += row("Device", "Device", "Error", "Volume", "Free",   "Trans", "Mnt")
        s += row(" Name",  "Status", "Count", " Label", "Blocks", "Count", "Cnt")

        let volumes = host.mountedVolumes()
        for (i, vol) in volumes.enumerated() {
            let dev = "DKA\(i):"
            let label = vol.vmsLabel
            let free = String(vol.freeBlocks)
            let trans = i == 0 ? 44 : max(1, 12 - (i - 1) * 3)
            s += row(dev, "Mounted", "0", label, free, String(trans), "1")
        }
        s += row("CTC$EBA0:",  "Online", "0", "(none)", "-", "-", "-")
        s += row(terminalName, "Online", "0", "(none)", "-", "-", "-")
        return s
    }

    func showMemory() -> String {
        let vm = host.vmStats()
        let procCount = host.processCount()
        let resident = max(1, procCount - 8)

        // VMS accounts for every physical page as free, on the modified list,
        // or in use -- so the three sum to Total. Derive Free that way (rather
        // than the raw Mach free_count, which excludes speculative/other
        // categories) so the row is internally consistent.
        let totalPages = vm.totalPages
        let inUse      = min(vm.inUsePages, totalPages)
        let modified   = min(vm.modifiedPages, totalPages - inUse)
        let free       = totalPages - inUse - modified

        var s = "\n                System Memory Resources on \(stamp(Date()))\n\n"
        s += "Physical Memory Usage (pages):     Total       Free      In Use     Modified\n"
        let memLabel = "  Main Memory (\(HostStats.memSize(host.usableMemoryBytes)))"
            .padding(toLength: 32, withPad: " ", startingAt: 0)
        s += memLabel + String(format: "%8llu   %8llu    %8llu     %8llu\n",
                               totalPages, free, inUse, modified)
        s += "\nSlot Usage (slots):                Total       Free   Resident      Swapped\n"
        s += String(format: "  Process Entry Slots             %4d       %4d       %4d            0\n",
                    max(procCount + 32, 160), 32, procCount)
        s += String(format: "  Balance Set Slots               %4d       %4d       %4d            0\n",
                    max(resident + 18, 140), 18, resident)
        // Dynamic-memory pools have no direct Mach analog -- oscillate
        // around realistic baselines so the figures look like a live
        // VMS kernel rather than a frozen snapshot.
        let t = Date().timeIntervalSinceReferenceDate
        let npTotal = 524288
        let npFree  = 94216 + Int(sin(t / 7.0) * 6400)
        let npUse   = npTotal - npFree
        let npLarge = 18432 + Int(sin(t / 11.0 + 1.3) * 1800)
        let pgTotal = 262144
        let pgFree  = 72488 + Int(sin(t / 6.0 + 0.7) * 3200)
        let pgUse   = pgTotal - pgFree
        let pgLarge = 12104 + Int(sin(t / 13.0 + 2.4) * 900)
        s += "\nDynamic Memory Usage (bytes):      Total       Free    In Use      Largest\n"
        s += String(format: "  Non-Paged Dynamic Memory      %8d   %8d  %8d     %8d\n",
                    npTotal, max(0, npFree), max(0, npUse), max(0, npLarge))
        s += String(format: "  Paged Dynamic Memory          %8d   %8d  %8d     %8d\n\n",
                    pgTotal, max(0, pgFree), max(0, pgUse), max(0, pgLarge))
        s += "Paging File Usage (pages):     Free  Reservable      Total\n"
        s += "  DISK$METRO_SYS:[SYS0.SYSEXE]PAGEFILE.SYS\n"
        // Back the page file with the host's real swap (sysctl vm.swapusage),
        // expressed in the same page unit as the rest of the display. Before
        // macOS activates any swap the sysctl reports zero, so fall back to a
        // RAM-derived figure to keep the section reading like a live VMS
        // backing store rather than an empty 0/0/0.
        let swap = host.swapUsage()
        let pfFree: UInt64, pfReservable: UInt64, pfTotal: UInt64
        if swap.totalBytes > 0 {
            pfTotal      = swap.totalBytes / host.pageSize
            pfFree       = swap.freeBytes  / host.pageSize
            pfReservable = pfFree
        } else {
            pfTotal      = vm.totalPages
            pfFree       = vm.freePages
            pfReservable = vm.freePages + vm.inactivePages
        }
        s += String(format: "                              %8llu    %8llu   %8llu\n",
                    pfFree, pfReservable, pfTotal)
        return s
    }

    func showTime() -> String {
        return "  \(stamp(Date()))\n"
    }

    /// SHOW MODBUS -- summary of the Modbus TCP register map so an external
    /// tool (mbpoll, pymodbus, OpenPLC, Node-RED) can be wired to the right
    /// addresses. Localized (it is LPD-facing lab documentation, like the
    /// PCC panel's M-key legend, which shows the same map).
    func showModbus() -> String {
        let n = ModbusTCPServer.maxTrains
        let sb = ModbusTCPServer.scalarBase
        func row(_ addr: String, _ text: String) -> String {
            "    " + addr.padding(toLength: 10, withPad: " ", startingAt: 0) + text + "\n"
        }
        func grp(_ g: Int) -> String { "\(g*n)..\(g*n + n - 1)" }

        var s = "\n  " + tr("modbus.legend.title") + "\n"
        s += "  " + tr("modbus.legend.endpoint") + "\n\n"

        s += "  " + tr("modbus.legend.coil") + "\n"
        s += row(grp(0), tr("modbus.reg.dooropen"))
        s += row(grp(1), tr("modbus.reg.doorclose"))
        s += row(grp(2), tr("modbus.reg.fuset"))
        s += row(grp(3), tr("modbus.reg.furelease")) + "\n"

        s += "  " + tr("modbus.legend.di") + "\n"
        s += row(grp(0), tr("modbus.reg.local"))
        s += row(grp(1), tr("modbus.reg.moving"))
        s += row(grp(2), tr("modbus.reg.doorsopen"))
        s += row(grp(3), tr("modbus.reg.fuapplied"))
        s += row(grp(4), tr("modbus.reg.faultdoor"))
        s += row(grp(5), tr("modbus.reg.faulttraction"))
        s += row(grp(6), tr("modbus.reg.faultbrake"))
        s += row(grp(7), tr("modbus.reg.faultctc"))
        s += row(grp(8), tr("modbus.reg.faultslip"))
        s += row(grp(9), tr("modbus.reg.faultslide"))
        s += "  " + tr("modbus.legend.chain") + "\n"
        s += row(grp(10), tr("modbus.chain.doorinterlock"))
        s += row(grp(11), tr("modbus.chain.overspeed"))
        s += row(grp(12), tr("modbus.chain.ma"))
        s += row(grp(13), tr("modbus.chain.brake"))
        s += row(grp(14), tr("modbus.chain.adhesion"))
        s += row(grp(15), tr("modbus.chain.intact")) + "\n"

        s += "  " + tr("modbus.legend.hr") + "\n"
        s += row(grp(0), tr("modbus.reg.mode"))
        s += row(grp(1), tr("modbus.reg.setspeed")) + "\n"

        s += "  " + tr("modbus.legend.ir") + "\n"
        s += row(grp(0), tr("modbus.reg.position"))
        s += row(grp(1), tr("modbus.reg.speed"))
        s += row(grp(2), tr("modbus.reg.consigne"))
        s += row(grp(3), tr("modbus.reg.ma"))
        s += row(grp(4), tr("modbus.reg.pax"))
        s += row(grp(5), tr("modbus.reg.status"))
        s += row(grp(6), tr("modbus.reg.canton"))
        s += row(grp(7), tr("modbus.reg.tire"))
        s += row("\(sb+0)",  tr("modbus.reg.traincount"))
        s += row("\(sb+1)",  tr("modbus.reg.peers"))
        s += row("\(sb+2)",  tr("modbus.reg.cantoncount"))
        s += row("\(sb+3)",  tr("modbus.reg.telnet"))
        s += row("\(sb+4)",  tr("modbus.reg.clients"))
        s += row("\(sb+5)",  tr("modbus.reg.linemode"))
        s += row("\(sb+6)",  tr("modbus.reg.spfrom"))
        s += row("\(sb+7)",  tr("modbus.reg.spto"))
        s += row("\(sb+8)",  tr("modbus.reg.spheadway"))
        s += row("\(sb+9)",  tr("modbus.reg.alarms"))
        s += row("\(sb+10)", tr("modbus.reg.severity"))
        s += row("\(sb+11)", tr("modbus.reg.unack"))
        s += row("\(sb+12)", tr("modbus.reg.shelved"))
        s += row("\(sb+13)", tr("modbus.reg.rtn"))
        s += row("\(sb+14)", tr("modbus.reg.tracklen"))
        return s
    }

    func showNetwork() -> String {
        // Header, separator and every data row share one fixed-width builder
        // so the columns line up regardless of node-name / count widths.
        func row(_ node: String, _ state: String, _ links: String,
                 _ delay: String, _ cost: String, _ hops: String, _ name: String) -> String {
            return "  "
                + node.padding(toLength: 9, withPad: " ", startingAt: 0)
                + state.padding(toLength: 12, withPad: " ", startingAt: 0)
                + rightPad(links, width: 12) + "   "
                + rightPad(delay, width: 5) + "   "
                + rightPad(cost,  width: 4) + "   "
                + rightPad(hops,  width: 4) + "  "
                + name + "\n"
        }
        var s = "\n" + row("Node", "State", "Active Links", "Delay", "Cost", "Hops", "Name")
        s += row("----", "-----", "------------", "-----", "----", "----", "----")
        s += row("1.1", "LOCAL", "2", "0", "0", "0", nodeName)
        if let peers = network?.peers, !peers.isEmpty {
            for (i, peer) in peers.enumerated() {
                let addr = "1.\(2 + i)"
                let upper = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let nm = String(upper.prefix(6))
                s += row(addr, "REACHABLE", "1", "\(2 + i)", "1", "1", nm)
            }
        } else {
            s += row("-", "-", "-", "-", "-", "-", "(no adjacent nodes)")
        }
        return s
    }

    func showLogical(_ cmd: Parsed) -> String {
        let procOnly = cmd.hasQualifier("PROCESS", min: 4)
        var s = "\n"
        if !procOnly {
            s += "(LNM$SYSTEM_TABLE)\n"
            s += "  \"METRO$ROOT\"                = \"DISK$METRO_SYS:[METRO]\"\n"
            s += "  \"RAME$DATA\"                 = \"DISK$METRO_DATA:[RAMES]\"\n"
            s += "  \"PORTES$STATE\"              = \"DISK$METRO_DOORS:[STATE]\"\n"
            s += "  \"ZC$TABLES\"                 = \"DISK$METRO_SYS:[ZC.SECTEUR1]\"\n"
            s += "  \"SYS$NODE\"                  = \"\(nodeName)::\"\n"
            s += "  \"SYS$LOGIN\"                 = \"METRO$ROOT:[\(username)]\"\n"
            s += "  \"SYS$SYSDEVICE\"             = \"DISK$METRO_SYS:\"\n"
            s += "  \"SYS$DISK\"                  = \"\(defaultDevice)\"\n"
        }
        s += "\n(LNM$PROCESS_TABLE)\n"
        s += "  \"SYS$COMMAND\"                = \"\(terminalName)\"\n"
        s += "  \"SYS$INPUT\"                  = \"\(terminalName)\"\n"
        s += "  \"SYS$OUTPUT\"                 = \"\(terminalName)\"\n"
        s += "  \"SYS$ERROR\"                  = \"\(terminalName)\"\n"
        for key in processLogicals.keys.sorted() {
            let padded = ("\"" + key + "\"").padding(toLength: 28, withPad: " ", startingAt: 0)
            s += "  \(padded) = \"\(processLogicals[key] ?? "")\"\n"
        }
        return s
    }

    func showSymbol(_ cmd: Parsed) -> String {
        if let name = cmd.positional.dropFirst().first {
            let key = name.uppercased()
            if let builtin = builtinSymbol(key) {
                return "  \(key) = \"\(builtin)\"\n"
            }
            if let v = symbols[key] {
                return "  \(key) = \"\(v)\"\n"
            }
            fail("DCL-W-UNDSYM", "%X00038150")
            return "%DCL-W-UNDSYM, undefined symbol - check validity and spelling\n"
        }
        if symbols.isEmpty {
            return "  (no local or global symbols defined)\n"
        }
        var s = "\n"
        for k in symbols.keys.sorted() {
            s += "  \(k) = \"\(symbols[k] ?? "")\"\n"
        }
        return s
    }

    /// DCL exposes a few read-only built-in symbols every shell sees.
    func builtinSymbol(_ name: String) -> String? {
        switch name {
        case "$STATUS":   return lastStatus
        case "$SEVERITY":
            let parsed = UInt32(lastStatus.replacingOccurrences(of: "%X", with: ""), radix: 16) ?? 1
            return String(parsed & 0x7)
        case "$RESTART":  return "FALSE"
        case "$PID":      return pid
        case "$PROCESS":  return "DCL_\(username)"
        default:          return nil
        }
    }

    func showError() -> String {
        let baseSeq = 4870 + Int.random(in: 0...12)
        var s = "\nERROR LOG SUMMARY -- last 5 entries\n"
        s += "   Sequence  Date / Time             Source           Code           Detail\n"
        s += "   ---------+------------------------+----------------+--------------+-----------------------------------\n"
        // %%X escapes %% so printf emits a literal "%X" -- without the escape
        // printf treats %X as a hex specifier and reads uninitialized memory
        // for the missing argument, printing garbage where the code should be.
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-2400)))  RAME_103_PORTES  %%X0000002C     DOOR SVC TIMEOUT, retried (success)\n", baseSeq + 0)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-1820)))  CTC_RADIOSRV     %%X00000018     RADIO HOLE: CANTON 7, MA coasted\n", baseSeq + 11)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-1100)))  RAME_101_FREIN   %%X00000004     INFO: routine brake test PASS\n", baseSeq + 20)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-220)))  PORTES_SVC       %%X00000040     PAGE FAULT FLOOD, throttling\n", baseSeq + 31)
        s += String(format: "    %7d  \(stamp(Date().addingTimeInterval(-12)))  QUAI_AFFSRV      %%X00000001     SS$_NORMAL, display re-announced\n", baseSeq + 40)
        return s
    }

    func showStatus() -> String {
        let upS = Int(host.uptime())
        var s = "\n  Status on \(stamp(Date()))\n"
        s += String(format: "  Elapsed CPU: 0 00:%02d:%02d.%02d   Buf I/O: %-6d   Dir I/O: %-6d   Page faults: %-6d\n",
                    (upS / 60) % 60, upS % 60, (upS * 7) % 100,
                    upS / 4, upS / 8, upS / 2)
        s += "  Connect time: \(uptimeString(from: bootTime, to: Date()))\n"
        s += "  Line mode: \(lineModeStatusLine())\n"
        let stdMode = (language?.standardOverride == nil)
            ? tr("dcl.set.standard.followlang") : tr("dcl.set.standard.override")
        s += String(format: tr("dcl.status.standard"), safetyStandard.label, stdMode) + "\n"
        // Per-train overrides (only shown when any train is non-nominal).
        if let trains = world?.trains,
           trains.contains(where: { $0.mode == .manual || $0.isEmergencyBrakeApplied }) {
            for t in trains where t.mode == .manual || t.isEmergencyBrakeApplied {
                var flags: [String] = []
                if t.mode == .manual { flags.append("MANUAL-DRIVING") }
                if t.isEmergencyBrakeApplied { flags.append("EMERG-BRAKE") }
                s += "    Train \(t.label): \(flags.joined(separator: " + "))\n"
            }
        }
        return s
    }

    private func lineModeStatusLine() -> String {
        guard let world else { return "NORMAL" }
        switch world.lineMode {
        case .stopped:
            return "SERVICE STOPPED"
        case .normal:
            return "NORMAL  (full automatic operation)"
        case .serviceProvisoire:
            if let sp = world.activeSP {
                return "\(sterm("safety.sp"))  (\(world.stationName(id: sp.startStationId)) <-> \(world.stationName(id: sp.endStationId)), \(Int(sp.intervalle))s)"
            }
            return sterm("safety.sp")
        case .emergency:
            return "GENERAL EMERGENCY STOP  (emergency brake on all trains)"
        }
    }

    func showLicense() -> String {
        var s = "\nActive licenses on \(nodeName) (\(osTitle) \(osVersion)):\n\n"
        s += "OPENVMS-X86          Active            (loaded)\n"
        s += "DECNET-PLUS          Active            (loaded)\n"
        s += "LPD-VAL-CTRL         Active            (loaded)\n"
        s += "LPD-DIAG             Active            (loaded)\n"
        return s
    }

    func showCPU() -> String {
        let now = Date()
        let usage = host.cpuUsage()
        let kernel = usage.system * 0.55
        let exec   = usage.system * 0.25
        let super_ = usage.system * 0.15
        let intr   = usage.system * 0.05

        let freqLabel: String
        if host.cpuFrequencyMHz > 0 {
            freqLabel = "\(host.cpuFrequencyMHz) MHz"
        } else {
            freqLabel = "host clock"
        }
        let cores = "\(host.activeProcessorCount) of \(host.processorCount) processors online"

        var s = "\n  CPU 0  (\(freqLabel))  -- \(stamp(now))\n"
        s += "    Model:     \(host.cpuModel)\n"
        s += "    Mode:      Multiprocessing primary\n"
        s += "    State:     Run   [\(cores)]\n"
        s += String(format: "    Idle:      %5.2f%%\n", usage.idle)
        s += String(format: "    Kernel:    %5.2f%%\n", kernel)
        s += String(format: "    Exec:      %5.2f%%\n", exec)
        s += String(format: "    Super:     %5.2f%%\n", super_)
        s += String(format: "    User:      %5.2f%%\n", usage.user + usage.nice)
        s += String(format: "    Interrupt: %5.2f%%\n", intr)
        return s
    }

    func showDefault() -> String {
        return "  \(defaultDevice)\(defaultDirectory)\n"
    }

    func showQuota() -> String {
        // Real boot-volume capacity in 512-byte VMS blocks. "Used" is total
        // minus free; "authorized" is the whole volume; overdraft mirrors
        // VMS's small soft cushion.
        let boot = host.bootVolume()
        let authorized = boot?.totalBlocks ?? 0
        let available  = boot?.freeBlocks  ?? 0
        let used = max(0, authorized - available)
        let overdraft = max(1024, authorized / 4096)
        var s = "\nUser [METRO,\(username)] has \(used) blocks used, \(available) available,\n"
        s += "   of \(authorized) authorized and permitted overdraft of \(overdraft) blocks on \(defaultDevice)\n"
        return s
    }

    func showProtection() -> String {
        return "  SYSTEM=RWED, OWNER=RWED, GROUP=RE, WORLD=NO ACCESS\n"
    }

    func showTerminal() -> String {
        var s = "\nTerminal:  \(terminalName)        Device_Type: VT100         Owner: \(username)\n\n"
        s += "Input:    9600  LFfill: 0  Width: \(terminalWidth)  Parity: None\n"
        s += "Output:   9600  CRfill: 0  Page:  \(terminalPage)\n\n"
        s += "Terminal Characteristics:\n"
        s += "  Interactive    Echo            Type_ahead     No Escape\n"
        s += "  No Hostsync    TTsync          Lowercase      Tab\n"
        s += "  Wrap           Scope           No Remote      Eightbit\n"
        s += "  Broadcast      No Readsync     No Form        Fulldup\n"
        s += "  No Modem       No Local_echo   No Autobaud    Hangup\n"
        s += "  No Brdcstmbx   No DMA          No Altypeahd   Set_speed\n"
        s += "  No Commsync    Line Editing    Overstrike editing            Smooth Scroll\n"
        s += "  No Fallback    No Dialup       No Secure server\n"
        s += "  No Disconnect  No Pasthru      No Syspassword                No SIXEL Graphics\n"
        s += "  No Soft Characters             No Printer Port               Numeric Keypad\n"
        s += "  ANSI_CRT       Edit_mode       DEC_CRT        DEC_CRT2      DEC_CRT3\n"
        s += "  Advanced_video Block_mode      No Regis       No Printer\n"
        return s
    }

    func showWorkingSet() -> String {
        // Resident size of this process from task_info; quota/extent are
        // expressed as multiples of the live working set so the VMS-style
        // /Limit, /Quota, /Extent triple is anchored to a real measurement.
        let ws = host.workingSet()
        let resident = Int(ws.residentPages)
        let limit  = max(2048, resident)
        let quota  = max(limit * 2,  8192)
        let extent = max(quota * 2, 16384)
        var s = "\nWorking Set     /Limit=\(limit)  /Quota=\(quota)  /Extent=\(extent)\n"
        s += "Adjustment enabled    Authorized Quota=\(quota)   Authorized Extent=\(extent)\n"
        s += "Current size:   \(resident) pages   (\(ws.residentBytes / 1024) KB resident)\n"
        return s
    }

    func showVersion() -> String {
        return "\n\(osTitle) \(osVersion)\n"
    }

    func showRMS() -> String {
        var s = "\nRMS_DEFAULT process values:\n"
        s += "  Multiblock count:        16        Multibuffer counts:\n"
        s += "                                       Indexed:  0    Relative:  0\n"
        s += "                                       Sequential: 0  Network:   0\n"
        s += "  Prolog level:             0        Extend quantity:        0\n"
        s += "  Block count:             32        Buffer count:           4\n"
        return s
    }

    func showIntrusion() -> String {
        var s = "\nIntrusion   Type      Count    Expiration    Source\n"
        s += "   (no intrusion records found)\n"
        return s
    }

    func showCluster() -> String {
        let w = 33
        let bar = String(repeating: "─", count: w - 2)
        var s = "\n              View of Cluster from system ID 1025  node: \(nodeName)\n"
        s += "┌\(bar)┐\n"
        s += "│            SYSTEMS            │\n"
        s += "│   NODE      SOFTWARE   STATUS │\n"
        s += "├\(bar)┤\n"
        s += "│  \(nodeName.padding(toLength: 8, withPad: " ", startingAt: 0))  VMS V\(osVersion.dropFirst())  MEMBER │\n"
        if let peers = network?.peers {
            for peer in peers {
                let nm = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                s += "│  \(String(nm).padding(toLength: 8, withPad: " ", startingAt: 0))  VMS V\(osVersion.dropFirst())  MEMBER │\n"
            }
        }
        s += "└\(bar)┘\n"
        return s
    }

    func showConnections() -> String {
        var s = "\nLogical Link  Node      Process       Remote link  Remote user\n"
        s += "============  ====      =======       ===========  ===========\n"
        if let peers = network?.peers, !peers.isEmpty {
            for (i, peer) in peers.enumerated() {
                let nm = peer.displayName.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                let nodePad = ("\(nm)::").padding(toLength: 9, withPad: " ", startingAt: 0)
                let procPad = "CTC_RADIOSRV".padding(toLength: 13, withPad: " ", startingAt: 0)
                s += String(format: "%-13d %@ %@ %-12d %@\n",
                            32768 + i, nodePad, procPad,
                            32768 + i + 1, "_METROSYS")
            }
        } else {
            s += "       (no active links)\n"
        }
        return s
    }

    func showAudit() -> String {
        return "\nSystem security audit characteristics:\n  Security alarm failure mode = NONE\n  Security audit failure mode = NONE\n  (no recent audit events)\n"
    }

    /// Lists the layered-product diagnostic test utilities the operator
    /// can launch via `RUN <name>` or the interactive `DIAGNOSE` menu.
    func showDiagnostics() -> String {
        var s = "\nVAL-CTRL Diagnostic Suite -- LPD-DIAG V1.4\n"
        s += "    " + "Image".padding(toLength: 16, withPad: " ", startingAt: 0)
        s += "Description\n"
        s += "    " + String(repeating: "-", count: 16) + " " + String(repeating: "-", count: 60) + "\n"
        s += "    " + "FREIN_TEST".padding(toLength: 16, withPad: " ", startingAt: 0)
        s += tr("login.lpd.frein") + "\n"
        s += "    " + "PORTES_TEST".padding(toLength: 16, withPad: " ", startingAt: 0)
        s += tr("login.lpd.portes") + "\n"
        s += "    " + "PNEU_CAL".padding(toLength: 16, withPad: " ", startingAt: 0)
        s += tr("login.lpd.pneu") + "\n"
        s += "    " + "QUAI_LAMP_TEST".padding(toLength: 16, withPad: " ", startingAt: 0)
        s += tr("login.lpd.quai") + "\n"
        s += "\nLaunch with    RUN <image>    or    DIAGNOSE    for an interactive menu.\n"
        return s
    }
}
