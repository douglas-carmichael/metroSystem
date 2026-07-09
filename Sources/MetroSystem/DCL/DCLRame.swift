import Foundation

// Rame-control verbs: START / STOP / OPEN / CLOSE.
//
//      $ STOP RAME 101          -- commands the FU (emergency brake)
//      $ START RAME 101         -- releases the FU, returns to service
//      $ STOP LINE              -- arrêt d'urgence général (all rames)
//      $ START LINE             -- start (or resume) line service
//      $ OPEN RAME 101          -- open doors (only while docked)
//      $ CLOSE RAME 101         -- close doors
extension DCLEngine {

    /// START LINE  /  START RAME <label>
    func startCmd(_ cmd: Parsed) -> String {
        guard let world else { return "%SYSTEM-F-NOWORLD, metro world not attached\n" }
        var args = cmd.positional
        guard let first = args.first else {
            return "%START-W-MISSPARM, usage: START LINE  or  START RAME <label>\n"
        }
        if matches(first, "LINE", min: 3) || matches(first, "LIGNE", min: 3) {
            if world.isEmergencyStopped { world.emergencyStopAll(false) }
            let was = world.isRunning
            world.startService()
            return was
                ? "%START-I-NOCHG, line service already running\n"
                : "%START-S-LINE, line service started -- rames in automatic pilot\n"
        }
        if first.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%START-W-MISSPARM, usage: START RAME <label>\n"
        }
        guard let train = world.findTrain(label: label) else {
            return "%START-W-NOSUCHRAME, no such rame \\\(label)\\\n"
        }
        let was = train.isEmergencyBrakeApplied
        world.mutate(train.id) { t in
            t.isEmergencyBrakeApplied = false
            if t.status == .emergency { t.status = .stopped }
        }
        return was
            ? "%START-S-RELEASED, rame \(train.label) FU released -- returning to service\n"
            : "%START-I-NOCHG, rame \(train.label) was not under FU\n"
    }

    /// STOP LINE  /  STOP RAME <label> -- commands the emergency brake.
    func stopCmd(_ cmd: Parsed) -> String {
        guard let world else { return "%SYSTEM-F-NOWORLD, metro world not attached\n" }
        var args = cmd.positional
        guard let first = args.first else {
            return "%STOP-W-MISSPARM, usage: STOP LINE  or  STOP RAME <label>\n"
        }
        if matches(first, "LINE", min: 3) || matches(first, "LIGNE", min: 3) {
            world.emergencyStopAll(true)
            return "%STOP-S-LINE, arrêt d'urgence général -- FU commanded on every rame\n"
        }
        if first.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%STOP-W-MISSPARM, usage: STOP RAME <label>\n"
        }
        guard let train = world.findTrain(label: label) else {
            return "%STOP-W-NOSUCHRAME, no such rame \\\(label)\\\n"
        }
        world.mutate(train.id) { $0.isEmergencyBrakeApplied = true }
        return "%STOP-S-FU, rame \(train.label) FU commanded (emergency brake)\n"
    }

    func openCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%OPEN-W-MISSPARM, usage: OPEN RAME <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, metro world not attached\n" }
        guard let train = world.findTrain(label: label) else {
            return "%OPEN-W-NOSUCHRAME, no such rame \\\(label)\\\n"
        }
        guard train.speed < 0.1 else {
            return "%OPEN-W-MOVING, rame \(train.label) is moving -- door interlock refuses the command\n"
        }
        world.mutate(train.id) { t in
            t.doorsOpen = true
            t.isDwelling = true
            t.dwellRemaining = max(t.dwellRemaining, 5.0)
            t.status = .docked
        }
        return "%OPEN-S-PORTES, rame \(train.label) doors opening\n"
    }

    func closeCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%CLOSE-W-MISSPARM, usage: CLOSE RAME <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, metro world not attached\n" }
        guard let train = world.findTrain(label: label) else {
            return "%CLOSE-W-NOSUCHRAME, no such rame \\\(label)\\\n"
        }
        guard train.doorsOpen else {
            return "%CLOSE-I-NOCHG, rame \(train.label) doors already closed\n"
        }
        world.mutate(train.id) { t in
            t.doorsOpen = false
            t.isDwelling = false
            t.dwellRemaining = 0
            t.paxRemaining = 0
        }
        return "%CLOSE-S-PORTES, rame \(train.label) doors closing\n"
    }
}
