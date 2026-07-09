import Foundation

/// On-disk store for user-authored .COM files. Lives under
/// ~/Library/Application Support/MetroSystem/COM/ so files round-trip
/// across launches.  TYPE, DIRECTORY, CREATE, DELETE, EDIT and @file all
/// consult this store; STARTUP.COM and a small set of sample scripts are
/// seeded on first use so the operator has something to try.
final class DCLScriptStore {
    struct FileInfo {
        let name: String        // Canonical "FOO.COM"
        let version: Int        // OpenVMS ;ver -- always 1 here
        let bytes: Int
        let modified: Date
    }

    private let root: URL

    /// Absolute path of the on-disk store, surfaced through HELP STORAGE
    /// and the MAIL/.LOG output of SUBMIT so an operator can locate the
    /// real files outside the shell (Finder, shell, backups).
    var rootPath: String { root.path }

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support
            .appendingPathComponent("MetroSystem", isDirectory: true)
            .appendingPathComponent("COM", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = dir
        seedIfNeeded()
    }

    /// Canonical filename: uppercase, with a ".COM" suffix when none given.
    func normalize(_ raw: String) -> String {
        var s = raw.uppercased()
        // Drop any leading device/directory and trailing version ";n".
        if let bracket = s.lastIndex(of: "]") {
            s = String(s[s.index(after: bracket)...])
        }
        if let colon = s.lastIndex(of: ":") {
            s = String(s[s.index(after: colon)...])
        }
        if let semi = s.firstIndex(of: ";") {
            s = String(s[..<semi])
        }
        if !s.contains(".") { s += ".COM" }
        return s
    }

    private func url(for name: String) -> URL {
        return root.appendingPathComponent(name)
    }

    func read(name: String) -> String? {
        let u = url(for: normalize(name))
        return (try? String(contentsOf: u, encoding: .utf8))
    }

    @discardableResult
    func write(name: String, body: String) -> Bool {
        let u = url(for: normalize(name))
        do {
            try body.write(to: u, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(name: String) -> Bool {
        let u = url(for: normalize(name))
        do {
            try FileManager.default.removeItem(at: u)
            return true
        } catch {
            return false
        }
    }

    func exists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: normalize(name)).path)
    }

    func list() -> [FileInfo] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root,
                                                   includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return FileInfo(
                name: url.lastPathComponent.uppercased(),
                version: 1,
                bytes: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? Date()
            )
        }
    }

    /// Seeds STARTUP.COM and two sample scripts the first time the store
    /// is created.  Subsequent launches leave whatever the operator wrote
    /// alone.
    private func seedIfNeeded() {
        // An earlier build seeded a LOGIN.COM whose closing WRITE banner
        // truncated on "/" and printed English in both language modes. Drop
        // any copy still carrying that line so the current (WRITE-free)
        // LOGIN.COM re-seeds below.
        migrate(name: "LOGIN.COM", ifContains: "follow the interface language (SHOW")
        seed(name: "STARTUP.COM", body: """
        $ ! METRO$ROOT:[CONTROL]STARTUP.COM
        $ ! Boot-time initialization for the metro line controller
        $ SET NOON
        $ DEFINE/SYSTEM METRO$ROOT    DISK$METRO_SYS:[METRO]
        $ DEFINE/SYSTEM RAME$DATA     DISK$METRO_DATA:[RAMES]
        $ DEFINE/SYSTEM ZC$TABLES     DISK$METRO_SYS:[ZC.SECTEUR1]
        $ INSTALL ADD METRO$ROOT:[CONTROL]VALCP.EXE     /OPEN/SHARED
        $ INSTALL ADD METRO$ROOT:[CONTROL]VAL_PILOT.EXE /OPEN/SHARED
        $ EXIT
        """)
        seed(name: "LOGIN.COM", body: """
        $ ! SYS$LOGIN:LOGIN.COM -- per-user logon
        $ ! The LPD VAL-CP short-form command aliases are built into the
        $ ! shell and gated by the interface language: the English aliases
        $ ! (TRAIN FLEET LINE STATIONS PAX EMERGENCY RESUME) resolve only in
        $ ! English mode, the French ones (RAME FLOTTE LIGNE GARES PAX
        $ ! URGENCE REPRISE AIDE) only in French mode. There is nothing to
        $ ! define here; VALCP itself is the installed layered product.
        $ ! Type HELP VALCP for the reference.
        $ SET NOON
        $ VALCP    == "$SYS$SYSTEM:VALCP.EXE"
        $ EXIT
        """)
        seed(name: "HELLO.COM", body: """
        $ ! HELLO.COM -- demonstrates symbols, IF/THEN and GOTO
        $ WRITE SYS$OUTPUT "Hello from DCL scripting!"
        $ COUNT = 1
        $LOOP:
        $   IF COUNT .GT. 3 THEN GOTO DONE
        $   WRITE SYS$OUTPUT "  Iteration ''COUNT'"
        $   COUNT = COUNT + 1
        $   GOTO LOOP
        $DONE:
        $ WRITE SYS$OUTPUT "Done. F$TIME() is now ''F$TIME()'"
        $ EXIT
        """)
        seed(name: "DEMO.COM", body: """
        $ ! DEMO.COM -- drive rame 101 through a short exploitation cycle.
        $ ! Rame state changes go through VALCP (the layered control
        $ ! program); START / STOP / OPEN / CLOSE remain bare operator verbs.
        $ WRITE SYS$OUTPUT "Putting rame 101 into conduite manuelle..."
        $ VALCP SET RAME 101 /MANUAL
        $ VALCP SET RAME 101 /SPEED=8
        $ WAIT 00:00:03
        $ VALCP SET RAME 101 /SPEED=0
        $ WAIT 00:00:02
        $ OPEN RAME 101
        $ WAIT 00:00:02
        $ CLOSE RAME 101
        $ VALCP SET RAME 101 /AUTOMATIC
        $ WRITE SYS$OUTPUT "Returned rame 101 to conduite automatique."
        $ EXIT
        """)
    }

    private func seed(name: String, body: String) {
        let u = url(for: name)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? body.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    /// Removes a seeded file if it still contains `marker`, so a corrected
    /// default re-seeds on next launch. Scoped to the exact stale text, so a
    /// file the operator has since edited past the marker is left untouched.
    private func migrate(name: String, ifContains marker: String) {
        let u = url(for: name)
        if let existing = try? String(contentsOf: u, encoding: .utf8),
           existing.contains(marker) {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
