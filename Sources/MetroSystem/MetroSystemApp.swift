import SwiftUI
import AppKit

@main
struct MetroSystemApp: App {
    @StateObject private var language: AppLanguage
    @StateObject private var world: MetroWorld
    @StateObject private var network: PeerNetwork
    @StateObject private var telnet: DCLTelnetServer
    @StateObject private var modbus: ModbusTCPServer
    @StateObject private var sessions = DCLSessionCoordinator()

    init() {
        let peerId = UUID().uuidString
        let label = Host.current().localizedName ?? "PCC"
        _language = StateObject(wrappedValue: AppLanguage())
        _world = StateObject(wrappedValue: MetroWorld(localPeerId: peerId, localPeerLabel: label))
        _network = StateObject(wrappedValue: PeerNetwork(peerId: peerId, label: label))
        _telnet = StateObject(wrappedValue: DCLTelnetServer())
        _modbus = StateObject(wrappedValue: ModbusTCPServer())
    }

    var body: some Scene {
        WindowGroup("PCC Dispatcher", id: "control") {
            PCCControlWindow()
                .environmentObject(language)
                .environmentObject(world)
                .environmentObject(network)
                .environmentObject(telnet)
                .environmentObject(modbus)
                .onAppear { bootstrap() }
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()
        .commands {
            // Replace the standard File > New with an opener that spawns a
            // fresh DCL terminal session (each carries its own DCLEngine).
            CommandGroup(replacing: .newItem) {
                NewTerminalCommand()
            }
        }

        WindowGroup("Line Synoptic 3D", id: "scene") {
            MetroSceneWindow()
                .environmentObject(language)
                .environmentObject(world)
                .environmentObject(network)
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()

        // Data-driven group keyed by DCLSessionID: each distinct session id
        // opens a separate window, and DCLShellWindow gives each one its own
        // DCLEngine -- so terminals are fully independent logins (separate
        // transcript / symbols / history / MAIL browse state), the same way
        // each telnet connection already gets its own engine.
        WindowGroup("DCL Terminal", id: "dcl", for: DCLSessionID.self) { _ in
            DCLShellWindow()
                .environmentObject(language)
                .environmentObject(world)
                .environmentObject(network)
                .environmentObject(sessions)
        } defaultValue: {
            DCLSessionID()
        }
        .windowResizability(.contentMinSize)
        .restorationDisabled()

        WindowGroup("Rame Dynamics", id: "dynamics") {
            DynamicsMonitorWindow()
                .environmentObject(language)
                .environmentObject(world)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 900)
        .restorationDisabled()

        // Per-rame detail window, keyed by train id: each distinct train
        // opens its own TCMS "train detail" synoptic.
        WindowGroup("Train Detail", id: "train-detail", for: UUID.self) { $trainId in
            if let trainId {
                TrainDetailWindow(trainId: trainId)
                    .environmentObject(language)
                    .environmentObject(world)
                    .environmentObject(network)
            } else {
                Text("No train selected")
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 760)
        .restorationDisabled()
    }

    private func bootstrap() {
        guard world.trains.isEmpty else { return }
        if let other = otherRunningInstance() {
            refuseDuplicateLaunch(other: other)
            return
        }
        world.seedTrains()
        network.attach(world: world)
        network.start()
        telnet.attach(world: world, network: network, language: language,
                      sessionCoordinator: sessions)
        telnet.start()
        modbus.attach(world: world, network: network, telnet: telnet)
        modbus.start()
        // Model-track hardware bridge: starts its output scan but stays
        // DISABLED until the operator arms it (SET HARDWARE /ENABLE).
        HardwareBridge.shared.attach(world: world)
        // Backend selection (VAL / PRATIC_SIM / PRATIC_HW): attaching
        // starts the default VALSimBackend against the seeded fleet.
        BackendManager.shared.attach(world: world)
    }

    /// Looks for another running MetroSystem process on this Mac. A second
    /// instance would fail to bind the telnet port and fight over the shared
    /// COM store, so refuse the duplicate launch outright.
    ///
    /// `isFinishedLaunching` filters out app entries that NSWorkspace
    /// reports transiently during macOS session restore -- if we don't
    /// require the other instance to be fully launched, a system-restored
    /// ghost can cause every fresh launch to false-positive on itself.
    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != mine && $0.isFinishedLaunching }
    }

    private func refuseDuplicateLaunch(other: NSRunningApplication) {
        // Defer the modal + terminate so we're running OUTSIDE the AppKit
        // / Core Animation transaction that the .onAppear that called us
        // is nested inside. NSAlert.runModal() is suppressed inside a CA
        // transaction, which would silently drop the alert.
        let pid = other.processIdentifier
        let info = """
            Only one PCC node may run on this Mac at a time. The existing \
            instance (pid \(pid)) will keep running; this launch will quit.
            """
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Another MetroSystem instance is already running"
            alert.informativeText = info
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Activate Existing")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                other.activate()
            }
            NSApp.terminate(nil)
        }
    }
}

private extension Scene {
    // Opts each WindowGroup out of macOS session restore so the app
    // launches in its declared layout rather than reopening whatever the
    // user last had on screen.
    func restorationDisabled() -> some Scene {
        self.restorationBehavior(.disabled)
    }
}

/// Identifies one DCL terminal window. Each distinct value drives a
/// separate window in the "dcl" WindowGroup; the fresh UUID means every
/// open request spawns a new, independent session rather than re-focusing
/// an existing one (SwiftUI only reuses a window when the presented value
/// matches one already on screen).
struct DCLSessionID: Hashable, Codable {
    var id: UUID = UUID()
}

/// File menu command that opens a brand-new DCL terminal session. Lives in
/// a view so it can read the `openWindow` action from the environment.
private struct NewTerminalCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New DCL Terminal") {
            openWindow(id: "dcl", value: DCLSessionID())
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}
