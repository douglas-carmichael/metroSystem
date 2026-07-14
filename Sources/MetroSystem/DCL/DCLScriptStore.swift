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
        // Self-paced training exercise kit (TP -- travaux pratiques).
        // Each script sets up its own scenario, states the objective and
        // prints the expected observations for self-checking -- no
        // instructor console or second node is ever required. The
        // scripts read the PCC$LANGUAGE builtin symbol and branch, so
        // each language sees only its own text and its own (language-
        // gated) qualifier spellings. Kit files re-seed when the
        // [TPKIT V3] tag is missing, replacing stale copies.
        for kit in ["TP1.COM", "TP1_FIN.COM", "TP2.COM", "TP3.COM",
                    "TP4.COM", "TP5.COM", "TP6.COM"] {
            reseedKit(name: kit)
        }
        seed(name: "TP1.COM", body: """
        $ ! [TPKIT V3] TP1.COM -- Traction-chain bench reading
        $ !                      Lecture de la chaine de traction au banc
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ WRITE SYS$OUTPUT "=== TP1: TRACTION CHAIN BENCH READING ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Goal: relate the chopper quantities II, IL, IEX and MHI."
        $ WRITE SYS$OUTPUT "Rame 101: manual driving, KG on, reverser AV, 80% traction."
        $ VALCP SET RAME 101 /MANUAL
        $ VALCP SET RAME 101 /SPEED=9
        $ VALCP SET RAME 101 /KG=ON
        $ VALCP SET RAME 101 /REVERSER=AV
        $ VALCP SET RAME 101 /LEVER=80
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "A. Open rame 101's DETAIL window: TRACTION BENCH meters."
        $ WRITE SYS$OUTPUT "   Launch: II pinned while MHI climbs -- IL = MHI x II"
        $ WRITE SYS$OUTPUT "   (a buck converter). The governor caps this run at 9 m/s."
        $ WRITE SYS$OUTPUT "   Acknowledge KACOP within 14 s: SET RAME 101 /KACOP"
        $ WRITE SYS$OUTPUT "B. Then run @TP1_FIN and watch the same rame in AUTOMATIC"
        $ WRITE SYS$OUTPUT "   on the fast stretch: at ~11-13 m/s MHI saturates (100%)"
        $ WRITE SYS$OUTPUT "   and IEX/II drops 0.059 -> 0.034: field weakening."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Verify any time: VALCP SHOW RAME 101.  Finish: @TP1_FIN"
        $ EXIT
        $FR:
        $ WRITE SYS$OUTPUT "=== TP1: LECTURE DE LA CHAINE DE TRACTION ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "But : relier les grandeurs hacheur II, IL, IEX et MHI."
        $ WRITE SYS$OUTPUT "Rame 101 : conduite manuelle, KG, inverseur AV, traction 80 %."
        $ VALCP SET RAME 101 /MANUEL
        $ VALCP SET RAME 101 /VITESSE=9
        $ VALCP SET RAME 101 /KG=ON
        $ VALCP SET RAME 101 /INVERSEUR=AV
        $ VALCP SET RAME 101 /MANIPULATEUR=80
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "A. Ouvrez la fenetre DETAIL de la rame 101 : banc traction."
        $ WRITE SYS$OUTPUT "   Lancement : II a sa limite pendant que MHI monte --"
        $ WRITE SYS$OUTPUT "   IL = MHI x II (hacheur serie). Limiteur regle a 9 m/s."
        $ WRITE SYS$OUTPUT "   Acquittez le KACOP sous 14 s : SET RAME 101 /KACOP"
        $ WRITE SYS$OUTPUT "B. Lancez ensuite @TP1_FIN et observez la meme rame en"
        $ WRITE SYS$OUTPUT "   AUTOMATIQUE sur le troncon rapide : vers 11-13 m/s MHI"
        $ WRITE SYS$OUTPUT "   sature (100 %) et IEX/II passe de 0,059 a 0,034 :"
        $ WRITE SYS$OUTPUT "   defluxage."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Verifiez : VALCP SHOW RAME 101.  Terminer : @TP1_FIN"
        $ EXIT
        """)
        seed(name: "TP1_FIN.COM", body: """
        $ ! [TPKIT V3] TP1_FIN.COM -- brake rame 101, hand back to automatic
        $ !             freine la rame 101, retour a l'automatique
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ VALCP SET RAME 101 /LEVER=-100
        $ WAIT 00:00:06
        $ VALCP SET RAME 101 /LEVER=0
        $ VALCP SET RAME 101 /KG=OFF
        $ VALCP SET RAME 101 /AUTOMATIC
        $ WRITE SYS$OUTPUT "Rame 101 back in automatic."
        $ EXIT
        $FR:
        $ VALCP SET RAME 101 /MANIPULATEUR=-100
        $ WAIT 00:00:06
        $ VALCP SET RAME 101 /MANIPULATEUR=0
        $ VALCP SET RAME 101 /KG=OFF
        $ VALCP SET RAME 101 /AUTOMATIQUE
        $ WRITE SYS$OUTPUT "Rame 101 rendue a l'automatique."
        $ EXIT
        """)
        seed(name: "TP2.COM", body: """
        $ ! [TPKIT V3] TP2.COM -- EB-trip diagnosis down to the board
        $ !                      Diagnostic d'un declenchement FU jusqu'a la carte
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ WRITE SYS$OUTPUT "=== TP2: EB TRIP DIAGNOSIS (LRU) ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "A fault has just been injected on rame 102. Find it, name"
        $ WRITE SYS$OUTPUT "the suspect board, then restore service."
        $ VALCP SET RAME 102 /SIGNAL=ON
        $ WAIT 00:00:02
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Procedure:"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             which point?"
        $ WRITE SYS$OUTPUT "  2. VALCP SHOW RAME 102     program + EB cause"
        $ WRITE SYS$OUTPUT "  3. RUN LRU_LOOKUP          suspect board"
        $ WRITE SYS$OUTPUT "  4. Restore: SET RAME 102 /SIGNAL=OFF, then START RAME 102,"
        $ WRITE SYS$OUTPUT "     then ACKNOWLEDGE ALARM ALL."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Self-check: the EB cause reads SF; the lookup names CPFS-A"
        $ WRITE SYS$OUTPUT "(vehicle) and the WCU AFSC/PP board."
        $ EXIT
        $FR:
        $ WRITE SYS$OUTPUT "=== TP2: DIAGNOSTIC D'UN DECLENCHEMENT FU (CARTE) ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Un defaut vient d'etre injecte sur la rame 102. Trouvez-le,"
        $ WRITE SYS$OUTPUT "nommez la carte suspecte, puis retablissez le service."
        $ VALCP SET RAME 102 /CTC=ON
        $ WAIT 00:00:02
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Demarche :"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             quel point ?"
        $ WRITE SYS$OUTPUT "  2. VALCP SHOW RAME 102     programme + cause FU"
        $ WRITE SYS$OUTPUT "  3. RUN LRU_LOOKUP          carte suspecte"
        $ WRITE SYS$OUTPUT "  4. Retablir : SET RAME 102 /CTC=OFF, puis START RAME 102,"
        $ WRITE SYS$OUTPUT "     puis ACKNOWLEDGE ALARM ALL."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Auto-verification : la cause FU indique SF ; la recherche"
        $ WRITE SYS$OUTPUT "nomme CPFS-A (vehicule) et la carte AFSC/PP du WCU."
        $ EXIT
        """)
        seed(name: "TP3.COM", body: """
        $ ! [TPKIT V3] TP3.COM -- Adhesion and the anti-skid function
        $ !                      Adherence et fonction anti-patinage
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ WRITE SYS$OUTPUT "=== TP3: ADHESION AND THE ANTI-SKID FUNCTION ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Rame 103 now runs over a low-adhesion patch under traction."
        $ VALCP SET RAME 103 /SLIP=ON
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Observe:"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             PATINAGE raises (advisory)."
        $ WRITE SYS$OUTPUT "  2. The affected car's effort is cancelled then ramped back:"
        $ WRITE SYS$OUTPUT "     the anti-skid trips on an 8 km/h motor-speed spread and"
        $ WRITE SYS$OUTPUT "     cannot act per wheel -- the differential forbids it."
        $ WRITE SYS$OUTPUT "  3. MONITOR DYNAMICS        speed vs setpoint under slip."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Restore & acknowledge: SET RAME 103 /SLIP=OFF, then"
        $ WRITE SYS$OUTPUT "ACKNOWLEDGE ALARM ALL."
        $ EXIT
        $FR:
        $ WRITE SYS$OUTPUT "=== TP3: ADHERENCE ET FONCTION ANTI-PATINAGE ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "La rame 103 franchit desormais une zone glissante en traction."
        $ VALCP SET RAME 103 /PATINAGE=ON
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Observez :"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             PATINAGE apparait (advisory)."
        $ WRITE SYS$OUTPUT "  2. L'effort de la voiture touchee est annule puis retabli en"
        $ WRITE SYS$OUTPUT "     rampe : l'anti-patinage detecte un ecart moteur de 8 km/h"
        $ WRITE SYS$OUTPUT "     et ne peut agir par roue -- le differentiel l'interdit."
        $ WRITE SYS$OUTPUT "  3. MONITOR DYNAMICS        vitesse vs consigne en patinage."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Retablissez et acquittez : SET RAME 103 /PATINAGE=OFF, puis"
        $ WRITE SYS$OUTPUT "ACKNOWLEDGE ALARM ALL."
        $ EXIT
        """)
        seed(name: "TP4.COM", body: """
        $ ! [TPKIT V3] TP4.COM -- Programmed-stop (berthing) accuracy
        $ !                      Precision d'arret programme (accostage)
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ WRITE SYS$OUTPUT "=== TP4: PROGRAMMED-STOP ACCURACY ==="
        $ SET LINE /SERVICE=ON
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Platform stop markers:"
        $ WRITE SYS$OUTPUT "   CHU-Eurasante 50.0   Gambetta 200.0   Flandres 350.0"
        $ WRITE SYS$OUTPUT "   Fives 550.0   Pont de Bois 700.0   4 Cantons 850.0"
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Procedure:"
        $ WRITE SYS$OUTPUT "  1. SHOW RAMES              catch a rame at DWELL."
        $ WRITE SYS$OUTPUT "  2. VALCP SHOW RAME <n>     read its Position."
        $ WRITE SYS$OUTPUT "  3. Compare with the marker above. Repeat for 3 berths."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Self-check: every stop lands within 1.5 m of the marker"
        $ WRITE SYS$OUTPUT "(the real system demonstrated +/-0.30 m at the door sill --"
        $ WRITE SYS$OUTPUT "DOT report, section 4.11)."
        $ EXIT
        $FR:
        $ WRITE SYS$OUTPUT "=== TP4: PRECISION D'ARRET PROGRAMME ==="
        $ SET LIGNE /SERVICE=ON
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Points d'arret des quais :"
        $ WRITE SYS$OUTPUT "   CHU-Eurasante 50,0   Gambetta 200,0   Flandres 350,0"
        $ WRITE SYS$OUTPUT "   Fives 550,0   Pont de Bois 700,0   4 Cantons 850,0"
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Demarche :"
        $ WRITE SYS$OUTPUT "  1. SHOW RAMES              attrapez une rame A QUAI."
        $ WRITE SYS$OUTPUT "  2. VALCP SHOW RAME <n>     relevez sa position."
        $ WRITE SYS$OUTPUT "  3. Comparez au point d'arret. Repetez sur 3 accostages."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Auto-verification : chaque arret tombe a moins de 1,5 m du"
        $ WRITE SYS$OUTPUT "point (le systeme reel a demontre +/-0,30 m -- rapport DOT,"
        $ WRITE SYS$OUTPUT "section 4.11)."
        $ EXIT
        """)
        seed(name: "TP5.COM", body: """
        $ ! [TPKIT V3] TP5.COM -- KACOP vigilance discipline
        $ !                      Discipline de vigilance KACOP
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ WRITE SYS$OUTPUT "=== TP5: KACOP VIGILANCE DISCIPLINE ==="
        $ VALCP SET RAME 101 /MANUAL
        $ VALCP SET RAME 101 /SPEED=6
        $ VALCP SET RAME 101 /KG=ON
        $ VALCP SET RAME 101 /REVERSER=AV
        $ VALCP SET RAME 101 /LEVER=40
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Rame 101 is driving manually. Do NOT acknowledge, and watch:"
        $ WRITE SYS$OUTPUT "  1. At 14 s: VIGILANCE alarm + KACOP voyant (detail window)."
        $ WRITE SYS$OUTPUT "  2. At 20 s: the EB trips, cause KACOP."
        $ WRITE SYS$OUTPUT "  3. At a stand, one acknowledgment releases it:"
        $ WRITE SYS$OUTPUT "       SET RAME 101 /KACOP"
        $ WRITE SYS$OUTPUT "  4. Drive again, acknowledging inside 14 s this time."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Finish:  @TP1_FIN"
        $ EXIT
        $FR:
        $ WRITE SYS$OUTPUT "=== TP5: DISCIPLINE DE VIGILANCE KACOP ==="
        $ VALCP SET RAME 101 /MANUEL
        $ VALCP SET RAME 101 /VITESSE=6
        $ VALCP SET RAME 101 /KG=ON
        $ VALCP SET RAME 101 /INVERSEUR=AV
        $ VALCP SET RAME 101 /MANIPULATEUR=40
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "La rame 101 roule en manuel. N'acquittez PAS, et observez :"
        $ WRITE SYS$OUTPUT "  1. A 14 s : alarme VIGILANCE + voyant KACOP (fenetre detail)."
        $ WRITE SYS$OUTPUT "  2. A 20 s : declenchement FU, cause KACOP."
        $ WRITE SYS$OUTPUT "  3. A l'arret, un acquittement le relache :"
        $ WRITE SYS$OUTPUT "       SET RAME 101 /KACOP"
        $ WRITE SYS$OUTPUT "  4. Reprenez la marche en acquittant sous 14 s cette fois."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Terminer :  @TP1_FIN"
        $ EXIT
        """)
        seed(name: "TP6.COM", body: """
        $ ! [TPKIT V3] TP6.COM -- Tire-pressure triage
        $ !                      Tri d'une degradation pneumatique
        $ IF PCC$LANGUAGE .EQS. "FR" THEN GOTO FR
        $ WRITE SYS$OUTPUT "=== TP6: TIRE-PRESSURE TRIAGE ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Tire 3 of rame 101 is degrading (two steps: low pressure,"
        $ WRITE SYS$OUTPUT "then puncture)."
        $ VALCP SET RAME 101 /TIRE=3
        $ WAIT 00:00:02
        $ VALCP SET RAME 101 /TIRE=3
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Procedure:"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             PNEU severity?"
        $ WRITE SYS$OUTPUT "  2. RUN PNEU_CAL            find the position."
        $ WRITE SYS$OUTPUT "  3. RUN LRU_LOOKUP          running-gear pointer."
        $ WRITE SYS$OUTPUT "  4. DETAIL window: tire gauges + the adhesion contact."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Restore: cycle tire 3 twice more (through BURST -- watch the"
        $ WRITE SYS$OUTPUT "severity climb to CRITICAL, then clear to OK), acknowledge:"
        $ WRITE SYS$OUTPUT "   SET RAME 101 /TIRE=3"
        $ WRITE SYS$OUTPUT "   SET RAME 101 /TIRE=3"
        $ WRITE SYS$OUTPUT "   ACKNOWLEDGE ALARM ALL"
        $ EXIT
        $FR:
        $ WRITE SYS$OUTPUT "=== TP6: TRI D'UNE DEGRADATION PNEUMATIQUE ==="
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Le pneu 3 de la rame 101 se degrade (deux crans : pression"
        $ WRITE SYS$OUTPUT "basse, puis crevaison)."
        $ VALCP SET RAME 101 /PNEU=3
        $ WAIT 00:00:02
        $ VALCP SET RAME 101 /PNEU=3
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Demarche :"
        $ WRITE SYS$OUTPUT "  1. SHOW ALARMS             gravite PNEU ?"
        $ WRITE SYS$OUTPUT "  2. RUN PNEU_CAL            trouvez la position."
        $ WRITE SYS$OUTPUT "  3. RUN LRU_LOOKUP          pointeur organes de roulement."
        $ WRITE SYS$OUTPUT "  4. Fenetre DETAIL : manometres pneus + contact adherence."
        $ WRITE SYS$OUTPUT ""
        $ WRITE SYS$OUTPUT "Retablir : cyclez encore deux fois le pneu 3 (en passant par"
        $ WRITE SYS$OUTPUT "ECLATEMENT -- gravite CRITIQUE, puis retour OK), acquittez :"
        $ WRITE SYS$OUTPUT "   SET RAME 101 /PNEU=3"
        $ WRITE SYS$OUTPUT "   SET RAME 101 /PNEU=3"
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

    /// Training-kit files carry a version tag; a copy WITHOUT the current
    /// tag is stale (or pre-dates the kit) and is replaced on launch.
    /// Operator edits that keep the tag line survive.
    private func reseedKit(name: String, tag: String = "[TPKIT V3]") {
        let u = url(for: name)
        if let existing = try? String(contentsOf: u, encoding: .utf8),
           !existing.contains(tag) {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
