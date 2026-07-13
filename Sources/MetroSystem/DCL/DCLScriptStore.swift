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
        // Self-paced training exercises (TP -- travaux pratiques). Each
        // sets up its own scenario, states the objective, and points at
        // the verification tools, with the expected result printed so the
        // student self-checks -- no instructor console or second node is
        // ever required. Output lines carry EN and FR so either interface
        // language is served (script bodies are plain files, not the
        // localisation table).
        seed(name: "TP1.COM", body: """
        $ ! TP1.COM -- Traction-chain bench reading
        $ !            Lecture de la chaine de traction au banc
        $ WRITE SYS$OUTPUT "=== TP1: TRACTION CHAIN BENCH READING ==="
        $ WRITE SYS$OUTPUT "=== TP1: LECTURE DE LA CHAINE DE TRACTION ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Goal: relate the chopper quantities II, IL, IEX and MHI."
        $ WRITE SYS$OUTPUT "But : relier les grandeurs hacheur II, IL, IEX et MHI."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Rame 101: manual driving, KG on, reverser AV, 80% traction."
        $ WRITE SYS$OUTPUT "Rame 101 : conduite manuelle, KG, inverseur AV, traction 80 %."
        $ VALCP SET RAME 101 /MANUAL
        $ VALCP SET RAME 101 /KG=ON
        $ VALCP SET RAME 101 /REVERSER=AV
        $ VALCP SET RAME 101 /LEVER=80
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "1. Open the rame's DETAIL window, TRACTION section."
        $ WRITE SYS$OUTPUT "   Ouvrez la fenetre DETAIL de la rame, section TRACTION."
        $ WRITE SYS$OUTPUT "2. Launch: II holds its limit while MHI climbs -- the chopper"
        $ WRITE SYS$OUTPUT "   relation is IL = MHI x II (a buck converter)."
        $ WRITE SYS$OUTPUT "   Lancement : II reste a sa limite pendant que MHI monte --"
        $ WRITE SYS$OUTPUT "   la relation hacheur est IL = MHI x II (hacheur serie)."
        $ WRITE SYS$OUTPUT "3. When MHI saturates (100%), note the speed: base speed."
        $ WRITE SYS$OUTPUT "   IEX/II drops 0.059 -> 0.034: field weakening."
        $ WRITE SYS$OUTPUT "   Quand MHI sature (100 %), notez la vitesse : vitesse de"
        $ WRITE SYS$OUTPUT "   base. IEX/II passe de 0,059 a 0,034 : defluxage."
        $ WRITE SYS$OUTPUT "4. Acknowledge KACOP within 14 s: SET RAME 101 /KACOP"
        $ WRITE SYS$OUTPUT "   Acquittez le KACOP sous 14 s : SET RAME 101 /KACOP"
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Verify any time / Verifiez a tout moment : VALCP SHOW RAME 101"
        $ WRITE SYS$OUTPUT "Finish / Terminer :  @TP1_FIN"
        $ EXIT
        """)
        seed(name: "TP1_FIN.COM", body: """
        $ ! TP1_FIN.COM -- end of TP1: brake and hand back to automatic.
        $ !                fin du TP1 : freinage et retour a l'automatique.
        $ VALCP SET RAME 101 /LEVER=-100
        $ WAIT 00:00:06
        $ VALCP SET RAME 101 /LEVER=0
        $ VALCP SET RAME 101 /KG=OFF
        $ VALCP SET RAME 101 /AUTOMATIC
        $ WRITE SYS$OUTPUT "Rame 101 back in automatic. / Rame 101 rendue a l'automatique."
        $ EXIT
        """)
        seed(name: "TP2.COM", body: """
        $ ! TP2.COM -- EB-trip diagnosis down to the board
        $ !            Diagnostic d'un declenchement FU jusqu'a la carte
        $ WRITE SYS$OUTPUT "=== TP2: EB TRIP DIAGNOSIS (LRU) ==="
        $ WRITE SYS$OUTPUT "=== TP2: DIAGNOSTIC D'UN DECLENCHEMENT FU (CARTE) ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "A fault has just been injected on rame 102. Find it, name"
        $ WRITE SYS$OUTPUT "the suspect board, then restore service."
        $ WRITE SYS$OUTPUT "Un defaut vient d'etre injecte sur la rame 102. Trouvez-le,"
        $ WRITE SYS$OUTPUT "nommez la carte suspecte, puis retablissez le service."
        $ VALCP SET RAME 102 /SIGNAL=ON
        $ WAIT 00:00:02
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Method / Demarche :"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             which point? / quel point ?"
        $ WRITE SYS$OUTPUT "  2. VALCP SHOW RAME 102     program + EB cause / cause FU"
        $ WRITE SYS$OUTPUT "  3. RUN LRU_LOOKUP          suspect board / carte suspecte"
        $ WRITE SYS$OUTPUT "  4. Restore: clear the fault, release the EB at a stand, ack:"
        $ WRITE SYS$OUTPUT "     Retablir : levez le defaut, FU relache a l'arret, acquittez :"
        $ WRITE SYS$OUTPUT "       SET RAME 102 /SIGNAL=OFF"
        $ WRITE SYS$OUTPUT "       START RAME 102"
        $ WRITE SYS$OUTPUT "       ACKNOWLEDGE ALARM ALL"
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Self-check: the EB cause reads SF; the lookup names CPFS-A"
        $ WRITE SYS$OUTPUT "(vehicle) and the WCU AFSC/PP board."
        $ WRITE SYS$OUTPUT "Auto-verification : la cause FU indique SF ; la recherche"
        $ WRITE SYS$OUTPUT "nomme CPFS-A (vehicule) et la carte AFSC/PP du WCU."
        $ EXIT
        """)
        seed(name: "TP3.COM", body: """
        $ ! TP3.COM -- Adhesion and the anti-skid function
        $ !            Adherence et fonction anti-patinage
        $ WRITE SYS$OUTPUT "=== TP3: ADHESION AND THE ANTI-SKID FUNCTION ==="
        $ WRITE SYS$OUTPUT "=== TP3: ADHERENCE ET FONCTION ANTI-PATINAGE ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Rame 103 now runs over a low-adhesion patch under traction."
        $ WRITE SYS$OUTPUT "La rame 103 franchit desormais une zone glissante en traction."
        $ VALCP SET RAME 103 /SLIP=ON
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Observe / Observez :"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             PATINAGE raises (advisory)."
        $ WRITE SYS$OUTPUT "  2. The affected car's effort is cancelled then ramped back:"
        $ WRITE SYS$OUTPUT "     the anti-skid trips on an 8 km/h motor-speed spread and"
        $ WRITE SYS$OUTPUT "     cannot act per wheel -- the differential forbids it."
        $ WRITE SYS$OUTPUT "     L'effort de la voiture touchee est annule puis retabli en"
        $ WRITE SYS$OUTPUT "     rampe : l'anti-patinage detecte un ecart moteur de 8 km/h"
        $ WRITE SYS$OUTPUT "     et ne peut agir par roue -- le differentiel l'interdit."
        $ WRITE SYS$OUTPUT "  3. MONITOR DYNAMICS        speed vs consigne under slip."
        $ WRITE SYS$OUTPUT "                             vitesse vs consigne en patinage."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Restore & acknowledge / Retablissez et acquittez :"
        $ WRITE SYS$OUTPUT "   SET RAME 103 /SLIP=OFF"
        $ WRITE SYS$OUTPUT "   ACKNOWLEDGE ALARM ALL"
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
