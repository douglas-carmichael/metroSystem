import Foundation
import DCLixKit

// DCLixKit bridge for MetroSystem.
//
// Copy to Sources/MetroSystem/DCL/DCLixBridge.swift; see
// dclix_swift/docs/integration.md for the four edits to DCLEngine.swift
// and the project.yml change that go with it. This is the ONLY file that
// knows about both sides.
//
// The rule it enforces: DCLixKit never overrides the metro simulation.
// Every verb DCLEngine already implements keeps its existing behaviour --
// VALCP, the rames, the alarm model, MONITOR, DIAGNOSE, the whole VAL /
// PRATIC / CBTC backend surface. DCLix is consulted only where the engine
// would otherwise print %DCL-W-IVVERB, and for the SHOW / SET keywords it
// doesn't recognise.

// MARK: -- host conformance

// `@preconcurrency` states what is already true: DCLEngine is
// @MainActor and every call into DCLixKit happens on the main
// actor. Without it the conformance is a warning today and an
// error under the Swift 6 language mode.
extension DCLEngine: @preconcurrency DCLixHost, @preconcurrency DCLixLocalizing {

    // -- identity ---------------------------------------------------------

    public var dclixUserName: String { username }
    public var dclixNodeName: String { nodeName }
    public var dclixProcessID: String { pid }
    public var dclixTerminalName: String { terminalName }
    public var dclixOperatingSystemTitle: String { osTitle }
    public var dclixOperatingSystemVersion: String { osVersion }

    // -- session state ----------------------------------------------------

    public var dclixDefaultDevice: String { defaultDevice }
    public var dclixDefaultDirectory: String { defaultDirectory }
    public var dclixTerminalWidth: Int { terminalWidth }
    public var dclixTerminalPageLength: Int { terminalPage }
    public var dclixBootTime: Date { bootTime }
    public var dclixIsDryRun: Bool { dryRun }

    // -- symbols and logical names ----------------------------------------

    public func dclixSymbol(named name: String) -> String? {
        symbols[name.uppercased()]
    }

    public func dclixSetSymbol(named name: String, to value: String) {
        symbols[name.uppercased()] = value
    }

    public func dclixAllSymbols() -> [String: String] { symbols }

    public func dclixLogical(named name: String) -> String? {
        processLogicals[name.uppercased()]
    }

    public func dclixAllLogicals() -> [String: String] { processLogicals }

    // -- the .COM file store ----------------------------------------------
    //
    // Language sources live beside the command procedures, so DIRECTORY,
    // TYPE and EDIT see HELLO.FOR exactly as they see STARTUP.COM.
    //
    // DCLScriptStore keeps one generation per name (it strips ";n" in
    // normalize), so DCLixKit's version machinery collapses to a single
    // version here -- `TYPE FOO.COM;2` finds FOO.COM, and PURGE has
    // nothing to do. That matches what DIRECTORY already reports.

    public func dclixReadFile(named name: String) -> String? {
        scriptStore.read(name: name)
    }

    @discardableResult
    public func dclixWriteFile(named name: String, body: String) -> Bool {
        scriptStore.write(name: name, body: body)
    }

    @discardableResult
    public func dclixDeleteFile(named name: String) -> Bool {
        scriptStore.delete(name: name)
    }

    public func dclixFileExists(named name: String) -> Bool {
        scriptStore.exists(name: name)
    }

    public func dclixListFiles() -> [DCLixFileEntry] {
        scriptStore.list().map {
            DCLixFileEntry(name: $0.name, version: $0.version,
                           bytes: $0.bytes, modified: $0.modified)
        }
    }

    public var dclixStateDirectory: URL {
        // Beside the COM store, so everything the shell persists lives in
        // one directory the operator can find, back up or delete:
        //   ~/Library/Application Support/MetroSystem/DCLix/
        URL(fileURLWithPath: scriptStore.rootPath)
            .deletingLastPathComponent()
            .appendingPathComponent("DCLix", isDirectory: true)
    }

    // -- machine statistics -----------------------------------------------
    //
    // The app already samples the Mac properly through HostStats, so reuse
    // it: SYSMAN's SHOW MEMORY then agrees with the engine's own SHOW
    // MEMORY instead of sampling twice and disagreeing by a page or two.

    public var dclixMachineStats: DCLixMachineStats {
        let vm = host.vmStats()
        let swap = host.swapUsage()
        let cpu = host.cpuUsage()
        let pageSize = vm.pageSize
        return DCLixMachineStats(
            physicalCPUs: host.processorCount,
            logicalCPUs: host.activeProcessorCount,
            cpuFrequencyMHz: Double(host.cpuFrequencyMHz),
            perCPUPercent: [cpu.busy],
            memoryTotalBytes: host.physicalMemoryBytes,
            memoryUsedBytes: vm.inUsePages * pageSize,
            memoryFreeBytes: vm.freePages * pageSize,
            swapTotalBytes: swap.totalBytes,
            swapUsedBytes: swap.usedBytes,
            bootTime: host.bootDate,
            volumes: host.mountedVolumes().map {
                DCLixMachineStats.Volume(device: $0.bsdName ?? $0.name,
                                         label: $0.name,
                                         totalBytes: UInt64(max(0, $0.totalBytes)),
                                         freeBytes: UInt64(max(0, $0.freeBytes)))
            },
            processCount: host.processCount(),
            architecture: host.cpuModel)
    }

    // -- what the app's own shell already owns ----------------------------
    //
    // Keep this in step with the keyword switches in DCLShow.swift and
    // DCLSet.swift. DCLixKit declines every name listed here, so its
    // supplements can never replace one of the engine's own accurate VSI
    // displays -- SHOW CLUSTER, SHOW USERS, SHOW CONNECTIONS and
    // SHOW PROTECTION stay exactly as the app renders them.

    public func dclixReservedKeywords(for verb: String) -> Set<String> {
        switch verb.uppercased() {
        case "SHOW":
            return ["ALARMS", "AUDIT", "BACKEND", "CLUSTER", "CONNECTIONS", "CPU",
                    "DEFAULT", "DEVICES", "DIAGNOSTICS", "ERROR", "HARDWARE",
                    "INTRUSION", "LICENSE", "LOGICAL", "MEMORY", "MODBUS", "NETWORK",
                    "PAX", "PRATIC", "PROCESS", "PROTECTION", "QUOTA", "RAME",
                    "RAMES", "STATIONS", "STATUS", "SYMBOL", "SYSTEM", "TERMINAL",
                    "TIME", "USERS", "VERSION"]
        case "SET":
            return ["BACKEND", "DEFAULT", "HARDWARE", "NOON", "NOVERIFY", "ON",
                    "PASSWORD", "PRATIC", "PROCESS", "PROMPT", "RAME", "STANDARD",
                    "TERMINAL", "VERIFY"]
        default:
            return []
        }
    }

    // -- cluster peers ----------------------------------------------------
    //
    // SHOW CLUSTER and the DECforms cluster panel are driven by the app's
    // OWN transport, not by a second discovery mechanism: `PeerNetwork`
    // already finds other app instances and headless ClusterDaemon nodes
    // over Bonjour, already exchanges `hello` / `state` / `stats`, and
    // already keeps the latest `HostSnapshotWire` per peer. This just
    // reshapes what it has.
    //
    // So `metro-clusterd --nodes 2 --trains 2` shows up as two MEMBER
    // nodes with their real CPU, memory, I/O and lock rates, the rames
    // each one owns listed as its jobs, and quorum recalculated as
    // daemons start and stop.

    public func dclixClusterPeers() -> [DCLixClusterPeer] {
        guard let network else { return [] }

        /// The rames a peer owns, by label -- the cluster display's "jobs".
        func owned(_ peerId: String) -> [String] {
            (world?.trains ?? [])
                .filter { $0.ownerPeerId == peerId }
                .map(\.label)
                .sorted()
        }

        func peer(id: String, label: String, address: String,
                  isLocal: Bool) -> DCLixClusterPeer {
            let snapshot = network.peerStats[id]
            return DCLixClusterPeer(
                id: id,
                displayName: label,
                address: address,
                isLocal: isLocal,
                // The local node carries the extra votes a full member
                // has; discovered peers get one each, so losing a daemon
                // costs one vote and losing the PCC costs quorum.
                votes: isLocal ? 3 : 1,
                isFullMember: isLocal,
                cpuBusyPercent: snapshot?.cpuBusy,
                memoryUsedPercent: snapshot?.memUsedPercent,
                bufferedIORate: snapshot?.bufferedIORate,
                directIORate: snapshot?.directIORate,
                lockRate: snapshot?.lockRate,
                processCount: snapshot?.processCount,
                sampledAt: snapshot?.sampledAt,
                ownedObjects: owned(id))
        }

        var peers = [peer(id: network.localPeerId,
                          label: nodeName,
                          address: "localhost",
                          isLocal: true)]
        peers += network.peers.map {
            peer(id: $0.id, label: $0.displayName, address: $0.address, isLocal: false)
        }
        return peers
    }

    // -- language ---------------------------------------------------------
    //
    // Everything DCLixKit prints -- reports, DECforms panels, HELP, the
    // descriptive half of every %FACILITY message -- follows this, so the
    // system-management surface switches with the rest of the UI. DCL
    // verbs, qualifiers, SYSGEN parameter names, privilege names, queue
    // names and VMS date stamps stay language-neutral either way.

    public var dclixLanguage: DCLixLanguage {
        (language?.current ?? .en) == .fr ? .fr : .en
    }

    // -- localization -----------------------------------------------------
    //
    // Optional refinement on top of `dclixLanguage`: any key the app's
    // own Strings.swift defines overrides the package's wording, so a
    // site can reword a panel without touching DCLixKit. A key with no
    // entry falls through to the package's own EN/FR text.

    public func dclixLocalized(_ key: String, default fallback: String) -> String {
        let translated = tr(key)
        return translated == key ? fallback : translated
    }
}

// MARK: -- engine integration

extension DCLEngine {

    /// The per-session DCLix subsystem, created on first use and held in
    /// the bridge's own side table -- DCLEngine gains no stored property.
    var dclix: DCLix {
        DCLixSessions.subsystem(for: self) { makeDCLixSubsystem() }
    }

    private func makeDCLixSubsystem() -> DCLix {
        let created = DCLix(host: self)
        created.formWidth = 78                 // matches DIAGNOSE / LRU_DIR
        // SYSMAN's cluster-wide `DO` re-enters DCL. execute() is async, so
        // the synchronous runner schedules the command and acknowledges
        // it -- which is what a real clusterwide DO does anyway.
        created.commandRunner = { [weak self] line in
            guard let self else { return "" }
            Task { @MainActor in
                let body = await self.execute(line)
                if !body.isEmpty {
                    self.out(body)
                    if !body.hasSuffix("\n") { self.out("\n") }
                }
            }
            return "%SYSMAN-I-QUEUED, \(line)"
        }
        return created
    }

    /// Offer an unrecognized verb to DCLix. Call from the `default:` arm
    /// of `execute()`:
    ///
    ///     default:
    ///         if let text = dclixFallback(line) { return text }
    ///         return ivverb(head)
    ///
    /// Returns nil when DCLix doesn't own the verb either.
    func dclixFallback(_ line: String) -> String? {
        switch dclix.handle(line) {
        case .notHandled:
            return nil

        case .output(let text):
            return text

        case .enteredSubshell(let banner, let newPrompt):
            dclixPreviousPrompt = prompt
            prompt = newPrompt
            return banner

        case .enteredFullScreen(let raw):
            // Take over the terminal the way DIAGNOSE and RUN LRU_DIR do
            // -- alternate screen buffer, live mode on, no prompt until
            // the form exits -- but WITHOUT adding a `LiveMode` case:
            // `liveActive` is the flag the line discipline and Ctrl/Y
            // already test, and `dclixWantsKeystrokes` below says who owns
            // the keyboard.
            liveTimer?.invalidate()
            liveTimer = nil
            liveActive = true
            outRaw(raw)
            return ""
        }
    }

    /// True while a DCLix line-mode utility (UAF>, SYSMAN>) owns input.
    var dclixSubshellActive: Bool { dclixStorage?.isSubshellActive == true }

    /// Route a line typed at a DCLix subshell prompt. Call from `submit()`
    /// beside the existing `editorActive` / `mailActive` branches.
    func dclixSubshellLine(_ raw: String) -> String {
        let body = dclix.handleSubshellLine(raw)
        if dclix.isSubshellActive {
            if let current = dclix.prompt { prompt = current }
        } else {
            prompt = dclixPreviousPrompt ?? "$ "
            dclixPreviousPrompt = nil
        }
        return body
    }

    /// True while a DCLix DECforms panel owns the keyboard. The line
    /// discipline tests this instead of a new `LiveMode` case, so
    /// `DCLEngine.LiveMode` is untouched.
    var dclixWantsKeystrokes: Bool { dclixStorage?.isFullScreenActive == true }

    /// Route keystrokes to an active DECforms panel.
    func handleDCLixFormKey(_ bytes: [UInt8]) {
        guard dclixWantsKeystrokes else { return }
        let result = dclix.handleFormBytes(bytes)
        if !result.raw.isEmpty { outRaw(result.raw) }
        guard result.finished else { return }
        liveActive = false
        if !result.message.isEmpty { out(result.message) }
        out(prompt)
    }

    /// Offer a `SHOW <keyword>` the engine doesn't recognise. Call from
    /// the `default:` arm of `showCmd`, before its "invalid keyword" line.
    func dclixShow(_ cmd: Parsed) -> String? {
        dclix.handleShow(cmd.asDCLixCommand)
    }

    /// Offer a `SET <keyword>` the engine doesn't recognise. Call from the
    /// `default:` arm of `setCmd`.
    func dclixSet(_ cmd: Parsed) -> String? {
        dclix.handleSet(cmd.asDCLixCommand)
    }

    /// Resolve an `F$` lexical the engine's own table doesn't implement.
    /// Call from the fall-through of the script engine's lexical evaluator.
    func dclixLexical(_ name: String, _ arguments: [String]) -> String? {
        dclix.lexicals.evaluate(name: name, arguments: arguments)
    }

    /// Open the DECforms system-management menu -- wire to a menu item or
    /// to a `SYSMGR` verb.
    func presentDCLixSystemManagement() {
        switch dclix.presentSystemManagementForms() {
        case .enteredFullScreen(let raw):
            liveTimer?.invalidate()
            liveTimer = nil
            liveActive = true
            outRaw(raw)
        case .output(let text):
            out(text)
        default:
            break
        }
    }

    /// Close everything DCLix owns. Call from LOGOUT, and from
    /// `stopMonitor` when `dclixWantsKeystrokes` is true.
    func dclixAbort() {
        guard let dclix = dclixStorage else { return }
        let result = dclix.abort()
        if !result.raw.isEmpty { outRaw(result.raw) }
        if !result.message.isEmpty { out(result.message) }
        if dclixWantsKeystrokes || !result.raw.isEmpty { liveActive = false }
        if let previous = dclixPreviousPrompt {
            prompt = previous
            dclixPreviousPrompt = nil
        }
    }

    /// Write the LOGOUT accounting record and drop the session from
    /// SHOW USERS. Call from `logoutText`.
    func dclixEndSession() {
        dclixStorage?.services.endSession(loginTime: sessionStart)
        dclixDiscardSession()
    }

    /// Every verb DCLix contributes -- append to the `verbs` array in
    /// `selfTest()` so SELFTEST covers them too.
    static var dclixVerbs: [String] { DCLix.addedVerbs }

    /// The command lines SELFTEST should add so its sweep covers what
    /// DCLix contributes: every language verb (with a file that doesn't
    /// exist, so the run is a clean FILENOTFOUND rather than a program),
    /// the utilities, and the HELP topics.
    var dclixSelfTestLines: [String] {
        LanguageCatalog.entries.map { "\($0.verb) SELFTEST.\($0.fileType)" }
            + ["SYSMAN", "AUTHORIZE", "UAF", "SYSMGR", "CLUSTERUI",
               "MCR SYSMAN", "MCR AUTHORIZE",
               "HELP FORTRAN", "HELP LANGUAGES", "HELP SYSMAN",
               "HELP AUTHORIZE", "HELP SYSMGR", "HELP CLUSTERUI",
               "HELP SHOW QUEUE", "HELP SET SECURITY"]
    }

    /// The app's HELP library with DCLix's topics folded in. Pass this to
    /// `HelpLibrary.parse` instead of `HelpLibrary.source`.
    ///
    /// It is a merge, not a concatenation: the app already has level-1
    /// `SHOW`, `SET` and `ACCOUNTING` topics, and DCLix's subtopics are
    /// added *inside* them, leaving the app's own text authoritative.
    static var dclixHelpSource: String {
        DCLixHelp.source(mergedWith: HelpLibrary.source)
    }
}


// MARK: -- per-engine state, held here rather than on DCLEngine
//
// Swift extensions can't add stored properties, and the point of this
// integration is that DCLEngine itself doesn't change -- no new fields, no
// new `LiveMode` case, no edits to its declarations. So the two pieces of
// per-session state DCLix needs live in a main-actor side table keyed by
// the engine's identity, and are dropped when the engine goes away.

@MainActor
private enum DCLixSessions {
    private static var subsystems: [ObjectIdentifier: DCLix] = [:]
    private static var savedPrompts: [ObjectIdentifier: String] = [:]

    static func subsystem(for engine: DCLEngine, make: () -> DCLix) -> DCLix {
        let key = ObjectIdentifier(engine)
        if let existing = subsystems[key] { return existing }
        let created = make()
        subsystems[key] = created
        return created
    }

    static func existing(for engine: DCLEngine) -> DCLix? {
        subsystems[ObjectIdentifier(engine)]
    }

    static func savedPrompt(for engine: DCLEngine) -> String? {
        savedPrompts[ObjectIdentifier(engine)]
    }

    static func setSavedPrompt(_ prompt: String?, for engine: DCLEngine) {
        savedPrompts[ObjectIdentifier(engine)] = prompt
    }

    /// Called from LOGOUT so a closed session leaves nothing behind.
    static func discard(_ engine: DCLEngine) {
        let key = ObjectIdentifier(engine)
        subsystems.removeValue(forKey: key)
        savedPrompts.removeValue(forKey: key)
    }
}

extension DCLEngine {
    var dclixStorage: DCLix? { DCLixSessions.existing(for: self) }

    var dclixPreviousPrompt: String? {
        get { DCLixSessions.savedPrompt(for: self) }
        set { DCLixSessions.setSavedPrompt(newValue, for: self) }
    }

    /// Drop everything this session held. Call from LOGOUT.
    func dclixDiscardSession() { DCLixSessions.discard(self) }
}

// MARK: -- parsed-command adapter

extension DCLEngine.Parsed {
    /// The engine's own parse result, in the shape DCLixKit takes. No
    /// re-parsing, so an abbreviation the engine accepted is the same one
    /// DCLix sees.
    var asDCLixCommand: DCLixCommand {
        DCLixCommand(verb: verb,
                     parameters: positional,
                     qualifiers: qualifiers.map {
                         DCLixCommand.Qualifier(name: $0.name, value: $0.value)
                     })
    }
}
