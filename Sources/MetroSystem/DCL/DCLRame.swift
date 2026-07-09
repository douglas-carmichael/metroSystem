import Foundation

// Rame-control verbs: START / STOP / OPEN / CLOSE.
//
//      $ STOP RAME 101          -- commands the emergency brake (FU)
//      $ START RAME 101         -- releases it, returns to service
//      $ STOP LINE              -- general emergency stop (all rames)
//      $ START LINE             -- start (or resume) line service
//      $ OPEN RAME 101          -- open doors (only while at a stand)
//      $ CLOSE RAME 101         -- close doors
//
// The verbs work on local and remote rames alike: a command against a
// peer-owned rame is forwarded to its owning node over the peer link,
// exactly like the PCC panel buttons.
extension DCLEngine {

    /// Outcome of routing a rame-control action from a DCL verb.
    enum ControlRoute {
        case local      // rame is ours -- mutated directly
        case forwarded  // rame is remote -- request sent to the owning peer
        case noLink     // rame is remote but its owner is unreachable
    }

    /// Route a doors / FU / mode / speed command to a rame whether it's
    /// local or remote. Keeps the network dependency out of the individual
    /// verbs.
    func routeControl(_ train: Train, _ kind: TrainCommandKind,
                      value: Double? = nil, in world: MetroWorld) -> ControlRoute {
        if world.canControl(train) {
            world.applyControl(trainId: train.id, kind: kind, value: value)
            return .local
        }
        guard let network, network.control(train, kind, value: value) else { return .noLink }
        return .forwarded
    }

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
                : "%START-S-LINE, line service started -- trains in automatic operation\n"
        }
        if first.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%START-W-MISSPARM, usage: START RAME <label>\n"
        }
        guard let train = world.findTrain(label: label) else {
            return "%START-W-NOSUCHRAME, no such train \\\(label)\\\n"
        }
        let was = train.isEmergencyBrakeApplied
        switch routeControl(train, .fuRelease, in: world) {
        case .local:
            return was
                ? "%START-S-RELEASED, train \(train.label) emergency brake released -- returning to service\n"
                : "%START-I-NOCHG, train \(train.label) was not under emergency braking\n"
        case .forwarded:
            return "%START-S-FORWARD, emergency-brake release sent to train \(train.label)'s owner node\n"
        case .noLink:
            return "%START-W-NOLINK, train \(train.label) is remote and its owner is unreachable\n"
        }
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
            return "%STOP-S-LINE, general emergency stop -- emergency brake commanded on every local train\n"
        }
        if first.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%STOP-W-MISSPARM, usage: STOP RAME <label>\n"
        }
        guard let train = world.findTrain(label: label) else {
            return "%STOP-W-NOSUCHRAME, no such train \\\(label)\\\n"
        }
        switch routeControl(train, .fuSet, in: world) {
        case .local:
            return "%STOP-S-FU, emergency brake commanded on train \(train.label)\n"
        case .forwarded:
            return "%STOP-S-FORWARD, emergency-brake command sent to train \(train.label)'s owner node\n"
        case .noLink:
            return "%STOP-W-NOLINK, train \(train.label) is remote and its owner is unreachable\n"
        }
    }

    func openCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%OPEN-W-MISSPARM, usage: OPEN RAME <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, metro world not attached\n" }
        guard let train = world.findTrain(label: label) else {
            return "%OPEN-W-NOSUCHRAME, no such train \\\(label)\\\n"
        }
        guard train.speed < 0.1 else {
            return "%OPEN-W-MOVING, train \(train.label) is moving -- door interlock refuses the command\n"
        }
        switch routeControl(train, .openDoors, in: world) {
        case .local:     return "%OPEN-S-PORTES, train \(train.label) doors opening\n"
        case .forwarded: return "%OPEN-S-FORWARD, door-open request sent to train \(train.label)'s owner node\n"
        case .noLink:    return "%OPEN-W-NOLINK, train \(train.label) is remote and its owner is unreachable\n"
        }
    }

    func closeCmd(_ cmd: Parsed) -> String {
        var args = cmd.positional
        if args.first?.uppercased() == "RAME" { args.removeFirst() }
        guard let label = args.first else {
            return "%CLOSE-W-MISSPARM, usage: CLOSE RAME <label>\n"
        }
        guard let world else { return "%SYSTEM-F-NOWORLD, metro world not attached\n" }
        guard let train = world.findTrain(label: label) else {
            return "%CLOSE-W-NOSUCHRAME, no such train \\\(label)\\\n"
        }
        guard train.doorsOpen else {
            return "%CLOSE-I-NOCHG, train \(train.label) doors already closed\n"
        }
        switch routeControl(train, .closeDoors, in: world) {
        case .local:     return "%CLOSE-S-PORTES, train \(train.label) doors closing\n"
        case .forwarded: return "%CLOSE-S-FORWARD, door-close request sent to train \(train.label)'s owner node\n"
        case .noLink:    return "%CLOSE-W-NOLINK, train \(train.label) is remote and its owner is unreachable\n"
        }
    }
}
