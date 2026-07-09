import Foundation

enum Strings {
    static let table: [String: [Lang: String]] = buildTable()

    /// Every alarm-message key the world or panel can raise. SHOW ALARMS
    /// and the SCADA panel use this list to localize the (English) stored
    /// message back into the UI language.
    static let alarmMessageKeys: [String] = [
        "alarm.msg.emergency", "alarm.msg.sp",
        "alarm.msg.overspeed", "alarm.msg.malimit", "alarm.msg.fu",
        "alarm.msg.doorfault", "alarm.msg.enginefault", "alarm.msg.brakefault",
        "alarm.msg.signalfault", "alarm.msg.patinage", "alarm.msg.enrayage",
        "alarm.msg.tirelow", "alarm.msg.tirepuncture", "alarm.msg.tireburst",
        "alarm.msg.paxfull", "alarm.msg.doorheld",
        "alarm.msg.controller", "alarm.msg.power", "alarm.msg.track",
        "alarm.msg.platform", "alarm.msg.display", "alarm.msg.switch",
    ]

    private static func buildTable() -> [String: [Lang: String]] {
        var t: [String: [Lang: String]] = [:]
        func add(_ key: String, _ en: String, _ fr: String) {
            t[key] = [.en: en, .fr: fr]
        }

        add("window.control",       "PCC Dispatcher",                      "Poste de commande centralisé")
        add("window.scene",         "Line Synoptic 3D",                    "Synoptique de ligne 3D")
        add("window.dcl",           "DCL Terminal",                        "Terminal DCL")
        add("window.dynamics",      "Dynamics",                            "Dynamiques")

        add("credits.title",        "CREDITS",                             "CRÉDITS")
        add("credits.dismiss",      "Click or press ESC to close",         "Cliquez ou appuyez ESC pour fermer")
        add("credits.role.metro",   "CBTC METRO SIMULATION",               "SIMULATION MÉTRO CBTC")
        add("credits.role.retro",   "RETRO UI & OpenVMS DCL SHELL",        "UI RÉTRO & SHELL DCL OpenVMS")

        add("banner.title",         "PCC — METRO LINE 1",                  "PCC — MÉTRO LIGNE 1")
        add("banner.subtitle",      "VSI OpenVMS V9.2-3   TERMINAL VT320", "VSI OpenVMS V9.2-3   TERMINAL VT320")
        add("banner.copyright",     "(C) 2026  LPD — LIGNES & PILOTAGE DAUPHINÉ",  "(C) 2026  LPD — LIGNES & PILOTAGE DAUPHINÉ")

        // The OpenVMS login banner stays English regardless of app language --
        // real VMS shipped English-only system messages, and only the LPD
        // layered-product splash below would be localised by a French vendor.
        add("dcl.banner.welcome",       "Welcome to %@ (TM) Operating System, Version %@",
                                        "Welcome to %@ (TM) Operating System, Version %@")
        add("dcl.banner.onnode",        "on node %@",                          "on node %@")
        add("dcl.banner.lastinter",     "Last interactive login on %@",        "Last interactive login on %@")
        add("dcl.banner.lastnon",       "Last non-interactive login on %@",    "Last non-interactive login on %@")
        add("dcl.banner.shelltag",      "%@ -- PCC OPERATOR SHELL",            "%@ -- PCC OPERATOR SHELL")

        // LPD VAL-CTRL layered-product splash (localised: the vendor is French).
        add("login.lpd.line1",  "LPD VAL-CTRL for OpenVMS x86-64 V4.2",
                                "LPD VAL-CTRL pour OpenVMS x86-64 V4.2")
        add("login.lpd.ctrl",   "Communication-based train control -- line 1 (VAL 208)",
                                "Contrôle des trains par communication -- ligne 1 (VAL 208)")
        add("login.lpd.line2",  "Diagnostic images available (RUN <image> or DIAGNOSE):",
                                "Images de diagnostic disponibles (RUN <image> ou DIAGNOSE) :")
        add("login.lpd.frein",  "  RUN FREIN_TEST       Brake-state audit on every rame",
                                "  RUN FREIN_TEST       Audit des freins de chaque rame")
        add("login.lpd.portes", "  RUN PORTES_TEST      Door cycle + traction-interlock test",
                                "  RUN PORTES_TEST      Cycle des portes + test d'asservissement traction")
        add("login.lpd.pneu",   "  RUN PNEU_CAL         Tire-pressure calibration (8 positions)",
                                "  RUN PNEU_CAL         Calibration pression pneus (8 positions)")
        add("login.lpd.quai",   "  RUN QUAI_LAMP_TEST   Platform display and lamp test",
                                "  RUN QUAI_LAMP_TEST   Test des afficheurs et lampes de quai")
        add("login.lpd.help",   "Type HELP METRO for a worked example, HELP VALCP for the reference.",
                                "Tapez HELP METRO pour un exemple, HELP VALCP pour la référence.")

        // Status strip.
        add("status.node",          "NODE",                                "NŒUD")
        add("status.rames",         "RAMES",                               "RAMES")
        add("status.telnet",        "TELNET",                              "TELNET")
        add("status.telnet.none",   "NONE",                                "AUCUNE")
        add("status.telnet.one",    "1 SESSION",                           "1 SESSION")
        add("status.telnet.many",   "%d SESSIONS",                         "%d SESSIONS")
        add("status.mode",          "MODE",                                "MODE")
        add("status.mode.stopped",  "SERVICE STOPPED",                     "SERVICE ARRÊTÉ")
        add("status.mode.normal",   "NORMAL (CAI)",                        "NORMAL (CAI)")
        add("status.mode.sp",       "SERVICE PROVISOIRE",                  "SERVICE PROVISOIRE")
        add("status.mode.emergency","EMERGENCY STOP",                      "ARRÊT D'URGENCE")
        add("status.ready",         "READY",                               "PRÊT")
        add("status.alarms",        "ALARMS",                              "ALARMES")
        add("status.alarms.normal", "NORMAL",                              "NORMAL")
        add("status.alarms.summary","%d ACT / %d UNACK",                   "%d ACT / %d N.ACQ")

        // HUD (3D synoptic).
        add("hud.rames",            "RAMES",                               "RAMES")
        add("hud.mode",             "MODE",                                "MODE")
        add("scene.recenter",       "RECENTER",                            "RECENTRER")
        add("scene.isolate",        "FOLLOW RAME",                         "SUIVRE RAME")
        add("scene.isolated.prefix","FOLLOWING",                           "SUIVI DE")

        // Line control panel.
        add("line.panel.title",     "LINE CONTROL",                        "COMMANDE DE LIGNE")
        add("line.service.start",   "START SERVICE",                       "DÉBUT DE SERVICE")
        add("line.service.stop",    "STOP SERVICE",                        "FIN DE SERVICE")
        add("line.emergency",       "EMERGENCY STOP",                      "ARRÊT D'URGENCE")
        add("line.addtrain",        "ADD RAME",                            "AJOUTER RAME")
        add("line.sp.label",        "SERVICE PROVISOIRE",                  "SERVICE PROVISOIRE")
        add("line.sp.from",         "FROM",                                "DE")
        add("line.sp.to",           "TO",                                  "À")
        add("line.sp.interval",     "HEADWAY",                             "INTERVALLE")
        add("line.sp.engage",       "ENGAGE",                              "ENGAGER")
        add("line.sp.clear",        "CLEAR",                               "LEVER")
        add("line.sp.active",       "SP active: %@ <-> %@  (headway %d s)",
                                    "SP actif : %@ <-> %@  (intervalle %d s)")

        // SCADA alarm panel.
        add("alarm.panel.title",    "SCADA ALARMS",                        "ALARMES SCADA")
        add("alarm.active",         "ACTIVE",                              "ACTIVES")
        add("alarm.unack",          "UNACK",                               "N.ACQ")
        add("alarm.inject",         "INJECT",                              "INJECTER")
        add("alarm.ack",            "ACK",                                 "ACQ")
        add("alarm.ack.all",        "ACK ALL",                             "ACQ TOUT")
        add("alarm.clear.all",      "CLEAR ALL",                           "EFFACER TOUT")
        add("alarm.clear.ack",      "CLEAR ACK",                           "EFFACER ACQ")
        add("alarm.none.active",    "-- no active alarms --",              "-- aucune alarme active --")
        add("alarm.col.id",         "ID",                                  "ID")
        add("alarm.col.sev",        "SEVERITY",                            "GRAVITÉ")
        add("alarm.col.state",      "STATE",                               "ÉTAT")
        add("alarm.col.source",     "SOURCE",                              "SOURCE")
        add("alarm.col.point",      "POINT",                               "POINT")
        add("alarm.col.message",    "MESSAGE",                             "MESSAGE")
        add("alarm.sev.advisory",   "ADVISORY",                            "AVIS")
        add("alarm.sev.minor",      "MINOR",                               "MINEURE")
        add("alarm.sev.major",      "MAJOR",                               "MAJEURE")
        add("alarm.sev.critical",   "CRITICAL",                            "CRITIQUE")
        add("alarm.status.ack",     "ACK",                                 "ACQ")
        add("alarm.status.unack",   "UNACK",                               "N.ACQ")
        add("alarm.status.cleared", "CLEARED",                             "EFFACÉE")
        add("alarm.status.rtn",     "RTN",                                 "RAN")
        add("alarm.status.shlvd",   "SHLVD",                               "SUSP")

        // Alarm messages (stored in EN in the log; localized on display).
        add("alarm.msg.emergency",  "General emergency stop: FU commanded on every rame",
                                    "Arrêt d'urgence général : FU commandé sur toutes les rames")
        add("alarm.msg.sp",         "Service provisoire in force; ZC barriers protect the barred section",
                                    "Service provisoire en vigueur ; barrières ZC sur la section neutralisée")
        add("alarm.msg.overspeed",  "ATP overspeed: speed above commanded consigne",
                                    "Survitesse ATP : vitesse au-dessus de la consigne")
        add("alarm.msg.malimit",    "Movement-authority limit encroached",
                                    "Empiètement sur la limite d'autorisation de mouvement")
        add("alarm.msg.fu",         "Emergency brake (FU) commanded",
                                    "Freinage d'urgence (FU) commandé")
        add("alarm.msg.doorfault",  "Door fault: interlock chain open",
                                    "Défaut portes : chaîne d'asservissement ouverte")
        add("alarm.msg.enginefault","Traction fault: motoring unavailable",
                                    "Défaut traction : motorisation indisponible")
        add("alarm.msg.brakefault", "Brake fault: service brake degraded",
                                    "Défaut frein : freinage de service dégradé")
        add("alarm.msg.signalfault","CTC radio fault: movement authority lost",
                                    "Défaut radio CTC : autorisation de mouvement perdue")
        add("alarm.msg.patinage",   "Wheel slip (patinage) detected under traction",
                                    "Patinage détecté en traction")
        add("alarm.msg.enrayage",   "Wheel slide (enrayage) detected under braking",
                                    "Enrayage détecté au freinage")
        add("alarm.msg.tirelow",    "Tire pressure low on at least one position",
                                    "Pression basse sur au moins un pneu")
        add("alarm.msg.tirepuncture","Tire puncture detected",
                                    "Crevaison détectée")
        add("alarm.msg.tireburst",  "TIRE BURST -- adhesion severely degraded",
                                    "ÉCLATEMENT PNEU -- adhérence fortement dégradée")
        add("alarm.msg.paxfull",    "Passenger load at or above 80% of capacity",
                                    "Charge voyageurs à 80 % de la capacité ou plus")
        add("alarm.msg.doorheld",   "Doors held open beyond dwell",
                                    "Portes maintenues ouvertes au-delà du stationnement")
        add("alarm.msg.controller", "PCC controller watchdog fault -- all rames held",
                                    "Défaut chien de garde PCC -- toutes rames retenues")
        add("alarm.msg.power",      "750 V traction supply fault",
                                    "Défaut alimentation traction 750 V")
        add("alarm.msg.track",      "Track-circuit inconsistency reported",
                                    "Incohérence de circuit de voie signalée")
        add("alarm.msg.platform",   "Platform door leaf fault",
                                    "Défaut vantail de façade de quai")
        add("alarm.msg.display",    "Platform display offline",
                                    "Afficheur de quai hors service")
        add("alarm.msg.switch",     "Point machine slow to lock",
                                    "Aiguille lente au verrouillage")

        // Per-rame panels.
        add("train.rame",           "RAME",                                "RAME")
        add("train.mode.cai",       "CAI",                                 "CAI")
        add("train.mode.cml",       "CML",                                 "CML")
        add("train.canton",         "CANTON",                              "CANTON")
        add("train.speed",          "SPEED",                               "VITESSE")
        add("train.ma",             "MA",                                  "AM")
        add("train.doors",          "DOORS",                               "PORTES")
        add("train.pax",            "PAX",                                 "VOYAGEURS")
        add("train.next",           "NEXT STOP",                           "PROCHAIN ARRÊT")
        add("train.status",         "STATUS",                              "ÉTAT")
        add("train.status.stopped", "STOPPED",                             "ARRÊT")
        add("train.status.moving",  "MOVING",                              "EN MARCHE")
        add("train.status.emergency","FU",                                 "FU")
        add("train.status.docked",  "AT PLATFORM",                         "À QUAI")
        add("train.faults",         "FAULTS",                              "DÉFAUTS")
        add("train.faults.label",   "FAULT INJECTION",                     "INJECTION DE DÉFAUTS")
        add("train.manual.speed",   "MANUAL SPEED",                        "VITESSE MANUELLE")
        add("train.tires.label",    "TIRES",                               "PNEUS")
        add("train.tires.hint",     "(click to cycle)",                    "(cliquer pour changer)")

        add("door.open",            "OPEN",                                "OUVERTES")
        add("door.closed",          "CLOSED",                              "FERMÉES")

        add("btn.door.open",        "OPEN DOORS",                          "OUVRIR PORTES")
        add("btn.door.close",       "CLOSE DOORS",                         "FERMER PORTES")
        add("btn.mode.label",       "MODE",                                "MODE")
        add("btn.mode.auto",        "AUTO",                                "AUTO")
        add("btn.mode.manual",      "MANUAL",                              "MANUEL")
        add("btn.fu",               "FU",                                  "FU")
        add("btn.remove",           "WITHDRAW",                            "RETIRER")

        // Footer / help.
        add("hint.line",            "TAB rame · O/C doors · A mode · F FU · E emergency · ?/F1 help",
                                    "TAB rame · O/C portes · A mode · F FU · E urgence · ?/F1 aide")
        add("hint.lang",            "LANG",                                "LANGUE")
        add("help.title",           "KEYBOARD HELP",                       "AIDE CLAVIER")
        add("help.dismiss",         "Press ESC, ? or click to dismiss",    "Appuyez ESC, ? ou cliquez pour fermer")
        add("help.focus.hint",      "FOCUSED RAME",                        "RAME SÉLECTIONNÉE")
        add("help.k.help",          "Show / hide this help",               "Afficher / masquer cette aide")
        add("help.k.tab",           "Cycle the focused rame",              "Changer la rame sélectionnée")
        add("help.k.lang",          "Switch language (EN / FR)",           "Changer de langue (EN / FR)")
        add("help.k.doors",         "Open / close focused rame's doors",   "Ouvrir / fermer les portes de la rame")
        add("help.k.mode",          "Toggle AUTO / MANUAL on the focused rame",
                                    "Basculer AUTO / MANUEL sur la rame")
        add("help.k.fu",            "Toggle the FU on the focused rame",   "Basculer le FU sur la rame")
        add("help.k.emergency",     "Toggle the line-wide emergency stop", "Basculer l'arrêt d'urgence général")
        add("help.k.dcl",           "Open a DCL terminal",                 "Ouvrir un terminal DCL")
        add("help.k.scene",         "Open the 3D line synoptic",           "Ouvrir le synoptique 3D")
        add("help.k.dynamics",      "Open the dynamics scope",             "Ouvrir l'oscilloscope dynamique")
        add("help.k.quit",          "Quit",                                "Quitter")
        add("help.k.esc",           "Dismiss overlays",                    "Fermer les fenêtres superposées")

        // Dynamics window.
        add("dynamics.title",       "RAME DYNAMICS — ASSERVISSEMENT",      "DYNAMIQUE DES RAMES — ASSERVISSEMENT")
        add("dynamics.empty",       "(no rames in service)",               "(aucune rame en service)")
        add("dynamics.select.label","RAMES",                               "RAMES")
        add("dynamics.select.empty","(none)",                              "(aucune)")
        add("dynamics.select.all",  "ALL",                                 "TOUTES")
        add("dynamics.select.none", "NONE",                                "AUCUNE")
        add("dynamics.col.rame",    "RAME",                                "RAME")
        add("dynamics.col.pos",     "POSITION",                            "POSITION")
        add("dynamics.col.vel",     "SPEED",                               "VITESSE")
        add("dynamics.col.consigne","CONSIGNE",                            "CONSIGNE")
        add("dynamics.col.acc",     "ACCEL",                               "ACCÉL")
        add("dynamics.col.ma",      "MA",                                  "AM")
        add("dynamics.col.state",   "STATE",                               "ÉTAT")
        add("dynamics.trace.title", "SPEED TRACE",                         "TRACÉ DE VITESSE")
        add("dynamics.trace.axis",  "60 s window · line speed dashed",     "fenêtre 60 s · vitesse ligne en tirets")
        add("dynamics.trace.empty", "(collecting samples...)",             "(acquisition en cours...)")
        add("dynamics.profile.limits","LIMITS",                            "LIMITES")
        add("dynamics.refresh",     "Sampling every 500 ms",               "Échantillonnage toutes les 500 ms")
        add("dynamics.state.gloss", "ACCEL accélération · CRUISE palier · DECEL freinage · A QUAI stationnement · CML conduite manuelle · FU freinage d'urgence · HOLD retenue intervalle",
                                    "ACCEL accélération · CRUISE palier · DECEL freinage · A QUAI stationnement · CML conduite manuelle · FU freinage d'urgence · HOLD retenue intervalle")

        // DCL generic bits.
        add("dcl.page.more",        "  -- more (%d/%d) -- RETURN for next page, Q to quit --\n",
                                    "  -- suite (%d/%d) -- ENTRÉE page suivante, Q pour quitter --\n")
        add("dcl.ack.nosystem",     "%ACK-W-NOSYSTEM, alarm system not attached",
                                    "%ACK-W-NOSYSTEM, système d'alarmes non attaché")
        add("dcl.ack.missalarm",    "%ACK-W-MISSPARM, usage: ACKNOWLEDGE ALARM {id | ALL}",
                                    "%ACK-W-MISSPARM, usage : ACKNOWLEDGE ALARM {id | ALL}")
        add("dcl.ack.missid",       "%ACK-W-MISSID, supply an alarm id or ALL",
                                    "%ACK-W-MISSID, précisez un id d'alarme ou ALL")
        add("dcl.ack.invalid",      "%%ACK-W-IVID, invalid alarm id \\%@\\",
                                    "%%ACK-W-IVID, id d'alarme invalide \\%@\\")
        add("dcl.ack.alarm",        "%%ACK-S-ACKED, alarm %@ acknowledged",
                                    "%%ACK-S-ACKED, alarme %@ acquittée")
        add("dcl.ack.alarms.one",   "%ACK-S-ACKED, 1 alarm acknowledged",
                                    "%ACK-S-ACKED, 1 alarme acquittée")
        add("dcl.ack.alarms.many",  "%%ACK-S-ACKED, %d alarms acknowledged",
                                    "%%ACK-S-ACKED, %d alarmes acquittées")
        add("dcl.ack.notfound",     "%%ACK-W-NOTFOUND, no active alarm %@",
                                    "%%ACK-W-NOTFOUND, aucune alarme active %@")
        add("dcl.shelve.missalarm", "%SHELVE-W-MISSPARM, usage: SHELVE ALARM <id>",
                                    "%SHELVE-W-MISSPARM, usage : SHELVE ALARM <id>")
        add("dcl.shelve.missid",    "%SHELVE-W-MISSID, supply an alarm id",
                                    "%SHELVE-W-MISSID, précisez un id d'alarme")
        add("dcl.shelve.ok",        "%%SHELVE-S-SHELVED, alarm %@ shelved (ISA-18.2 SHLVD)",
                                    "%%SHELVE-S-SHELVED, alarme %@ suspendue (ISA-18.2 SHLVD)")
        add("dcl.unshelve.missalarm","%UNSHELVE-W-MISSPARM, usage: UNSHELVE ALARM <id>",
                                    "%UNSHELVE-W-MISSPARM, usage : UNSHELVE ALARM <id>")
        add("dcl.unshelve.missid",  "%UNSHELVE-W-MISSID, supply an alarm id",
                                    "%UNSHELVE-W-MISSID, précisez un id d'alarme")
        add("dcl.unshelve.ok",      "%%UNSHELVE-S-RESTORED, alarm %@ restored to the annunciator",
                                    "%%UNSHELVE-S-RESTORED, alarme %@ rétablie à l'annonciateur")
        add("dcl.alarm.title",      "SCADA alarm journal at %@",           "Journal des alarmes SCADA à %@")
        add("dcl.alarm.title.active","Standing SCADA alarms at %@",        "Alarmes SCADA actives à %@")
        add("dcl.alarm.header",     "  Id    Time                         Severity   State    Source     Point          Message",
                                    "  Id    Heure                        Gravité    État     Source     Point          Message")
        add("dcl.alarm.none",       "  (journal is empty)",                "  (journal vide)")
        add("dcl.alarm.none.active","  (no standing alarms -- SHOW ALARMS/ALL for history)",
                                    "  (aucune alarme active -- SHOW ALARMS/ALL pour l'historique)")
        add("dcl.alarm.ackhint",    "  ACKNOWLEDGE ALARM <id|ALL> acknowledges; SHELVE/UNSHELVE manage nuisance alarms.",
                                    "  ACKNOWLEDGE ALARM <id|ALL> acquitte ; SHELVE/UNSHELVE gèrent les alarmes parasites.")
        add("dcl.alarm.allhint",    "  SHOW ALARMS/ALL lists the full journal including cleared history.",
                                    "  SHOW ALARMS/ALL liste le journal complet, historique effacé inclus.")
        add("dcl.status.standard",  "  CBTC standard: %@  (%@)",           "  Norme CBTC : %@  (%@)")
        add("dcl.set.standard.usage","%SET-W-MISSKEYW, usage: SET STANDARD {IEEE | EN62290 | AUTO}",
                                    "%SET-W-MISSKEYW, usage : SET STANDARD {IEEE | EN62290 | AUTO}")
        add("dcl.set.standard.bad", "%%SET-W-IVKEYW, unknown standard \\%@\\ (IEEE, EN62290 or AUTO)",
                                    "%%SET-W-IVKEYW, norme inconnue \\%@\\ (IEEE, EN62290 ou AUTO)")
        add("dcl.set.standard.ok",  "%%SET-S-STANDARD, terminology now follows %@ (%@)",
                                    "%%SET-S-STANDARD, la terminologie suit désormais %@ (%@)")
        add("dcl.set.standard.followlang","follows the interface language", "suit la langue de l'interface")
        add("dcl.set.standard.override","operator override",               "forçage opérateur")

        // Safety terms (differ by CBTC standard).
        add("safety.sp.ieee",       "TEMPORARY SHUTTLE (IEEE 1474 work zone)",
                                    "NAVETTE PROVISOIRE (zone de travaux IEEE 1474)")
        add("safety.sp.en62290",    "SERVICE PROVISOIRE (EN 62290 restricted section)",
                                    "SERVICE PROVISOIRE (section restreinte EN 62290)")

        // VALCP layered product.
        add("valcp.synopsis",       "VALCP -- LPD VAL Control Program.  Usage: VALCP {SHOW|SET|HELP} <object>",
                                    "VALCP -- programme de contrôle LPD VAL.  Usage : VALCP {SHOW|SET|HELP} <objet>")
        add("valcp.help.body",      "  SHOW: RAME [label] | RAMES | LIGNE | STATIONS | PAX\n  SET:  RAME <label> /qualifiers   |   LIGNE /qualifiers\n  See HELP VALCP in the DCL shell for the full reference.",
                                    "  SHOW : RAME [label] | RAMES | LIGNE | STATIONS | PAX\n  SET :  RAME <label> /qualificatifs   |   LIGNE /qualificatifs\n  Voir HELP VALCP dans le shell DCL pour la référence complète.")
        add("valcp.err.ivverb",     "%%VALCP-W-IVVERB, unknown subcommand \\%@\\ (SHOW, SET or HELP)\n",
                                    "%%VALCP-W-IVVERB, sous-commande inconnue \\%@\\ (SHOW, SET ou HELP)\n")
        add("valcp.err.show.missqual","%VALCP-W-MISSKEYW, usage: VALCP SHOW {RAME|RAMES|LIGNE|STATIONS|PAX}\n",
                                    "%VALCP-W-MISSKEYW, usage : VALCP SHOW {RAME|RAMES|LIGNE|STATIONS|PAX}\n")
        add("valcp.err.show.ivkeyw","%%VALCP-W-IVKEYW, unknown SHOW object \\%@\\\n",
                                    "%%VALCP-W-IVKEYW, objet SHOW inconnu \\%@\\\n")
        add("valcp.err.set.missqual","%VALCP-W-MISSKEYW, usage: VALCP SET {RAME|LIGNE} ...\n",
                                    "%VALCP-W-MISSKEYW, usage : VALCP SET {RAME|LIGNE} ...\n")
        add("valcp.err.set.ivkeyw", "%%VALCP-W-IVKEYW, unknown SET object \\%@\\\n",
                                    "%%VALCP-W-IVKEYW, objet SET inconnu \\%@\\\n")
        add("valcp.cmd.noworld",    "%VALCP-F-NOWORLD, metro world not attached\n",
                                    "%VALCP-F-NOWORLD, monde métro non attaché\n")
        add("valcp.cmd.sysnoworld", "%SYSTEM-F-NOWORLD, metro world not attached\n",
                                    "%SYSTEM-F-NOWORLD, monde métro non attaché\n")

        add("valcp.rame.title",     "\nRame %@ status at %@\n\n",          "\nÉtat de la rame %@ à %@\n\n")
        add("valcp.rame.position",  "  Position:        ",                 "  Position :        ")
        add("valcp.rame.speed",     "  Speed:           ",                 "  Vitesse :         ")
        add("valcp.rame.consigne",  "consigne",                            "consigne")
        add("valcp.rame.ma",        "  Movement auth.:  ",                 "  Autor. mouvement: ")
        add("valcp.rame.direction", "  Direction:       ",                 "  Sens :            ")
        add("valcp.rame.status",    "  Status:          ",                 "  État :            ")
        add("valcp.rame.mode",      "  Mode:            ",                 "  Mode :            ")
        add("valcp.rame.doors",     "  Doors:           ",                 "  Portes :          ")
        add("valcp.rame.pax",       "  Passengers:      %d / %d",          "  Voyageurs :       %d / %d")
        add("valcp.rame.nextstop",  "  Next stop:       ",                 "  Prochain arrêt :  ")
        add("valcp.rame.voltage",   "  Line voltage:  ",                   "  Tension ligne : ")
        add("valcp.rame.traction",  "  traction ",                         "  traction ")
        add("valcp.rame.faults",    "  Faults:          ",                 "  Défauts :         ")
        add("valcp.rame.nofault",   "(none)",                              "(aucun)")
        add("valcp.rame.tires",     "  Tires:",                            "  Pneus :")
        add("valcp.dir.forward",    "FORWARD",                             "SENS NORMAL")
        add("valcp.dir.reverse",    "REVERSE",                             "SENS INVERSE")
        add("valcp.status.stopped", "STOPPED",                             "ARRÊT")
        add("valcp.status.moving",  "MOVING",                              "EN MARCHE")
        add("valcp.status.emergency","EMERGENCY (FU)",                     "URGENCE (FU)")
        add("valcp.status.docked",  "AT PLATFORM",                         "À QUAI")
        add("valcp.mode.auto",      "AUTOMATIC (CAI)",                     "CONDUITE AUTOMATIQUE (CAI)")
        add("valcp.mode.manual",    "MANUAL (CML)",                        "CONDUITE MANUELLE (CML)")
        add("valcp.door.open",      "OPEN",                                "OUVERTES")
        add("valcp.door.closed",    "CLOSED AND LOCKED",                   "FERMÉES ET VERROUILLÉES")

        add("valcp.fleet.title",    "Fleet status at %@",                  "État du parc à %@")
        add("valcp.fleet.header",   "    Rame  Position   Canton      Speed        MA  Mode  Status  Drs   Pax\n",
                                    "    Rame  Position   Canton    Vitesse        AM  Mode  État    Prt   Voy\n")
        add("valcp.fleet.sep",      "    ----  --------  --------   ------   -------  ----  ------  ---  ----\n",
                                    "    ----  --------  --------   ------   -------  ----  ------  ---  ----\n")
        add("valcp.fleet.none",     "    (no rames in service)\n",         "    (aucune rame en service)\n")

        add("valcp.ligne.title",    "\nLine 1 exploitation at %@\n\n",     "\nExploitation ligne 1 à %@\n\n")
        add("valcp.ligne.mode",     "  Mode:            ",                 "  Mode :            ")
        add("valcp.ligne.mode.stopped","SERVICE STOPPED",                  "SERVICE ARRÊTÉ")
        add("valcp.ligne.mode.normal","NORMAL -- conduite automatique intégrale",
                                    "NORMAL -- conduite automatique intégrale")
        add("valcp.ligne.mode.sp",  "SERVICE PROVISOIRE",                  "SERVICE PROVISOIRE")
        add("valcp.ligne.mode.emergency","GENERAL EMERGENCY STOP",         "ARRÊT D'URGENCE GÉNÉRAL")
        add("valcp.ligne.spdetail", "  SP section:      %@ <-> %@  (headway %d s)",
                                    "  Section SP :      %@ <-> %@  (intervalle %d s)")
        add("valcp.ligne.geometry", "  Track:           %d cantons, %d m loop",
                                    "  Voie :            %d cantons, boucle de %d m")
        add("valcp.ligne.rames",    "  Rames:           %d in service (max %d)\n",
                                    "  Rames :           %d en service (max %d)\n")
        add("valcp.ligne.modenormal","%VALCP-S-NORMAL, line returned to normal exploitation\n",
                                    "%VALCP-S-NORMAL, ligne rendue à l'exploitation normale\n")
        add("valcp.ligne.serviceon","%VALCP-S-SERVICE, line service started\n",
                                    "%VALCP-S-SERVICE, service de ligne démarré\n")
        add("valcp.ligne.serviceoff","%VALCP-S-SERVICE, line service stopped -- rames braking to a stand\n",
                                    "%VALCP-S-SERVICE, service arrêté -- rames en cours d'immobilisation\n")
        add("valcp.ligne.emeron",   "%VALCP-S-EMERGENCY, general emergency stop -- FU on every rame\n",
                                    "%VALCP-S-EMERGENCY, arrêt d'urgence général -- FU sur toutes les rames\n")
        add("valcp.ligne.emeroff",  "%VALCP-S-EMERGENCY, emergency stop released\n",
                                    "%VALCP-S-EMERGENCY, arrêt d'urgence levé\n")
        add("valcp.ligne.spon",     "%%VALCP-S-SP, service provisoire engaged %@ <-> %@ (headway %d s)\n",
                                    "%%VALCP-S-SP, service provisoire engagé %@ <-> %@ (intervalle %d s)\n")
        add("valcp.ligne.spoff",    "%VALCP-S-SP, service provisoire cleared -- full line restored\n",
                                    "%VALCP-S-SP, service provisoire levé -- ligne complète rétablie\n")
        add("valcp.ligne.spusage",  "%VALCP-W-IVSP, usage: SET LIGNE /SP=(from,to[,interval-s]) with station ids 1..6\n",
                                    "%VALCP-W-IVSP, usage : SET LIGNE /SP=(de,à[,intervalle-s]) avec des ids de station 1..6\n")
        add("valcp.ligne.missqual", "%VALCP-W-MISSQUAL, expected /SERVICE=, /EMERGENCY=, /SP= or /NORMAL\n",
                                    "%VALCP-W-MISSQUAL, attendu /SERVICE=, /EMERGENCY=, /SP= ou /NORMAL\n")

        add("valcp.stations.title", "Stations of line 1 at %@",            "Stations de la ligne 1 à %@")
        add("valcp.stations.header","     #  Station                 Position    Next rame\n",
                                    "     #  Station                 Position    Prochaine rame\n")
        add("valcp.stations.sep",   "    --  ----------------------  ---------   --------------------\n",
                                    "    --  ----------------------  ---------   --------------------\n")
        add("valcp.stations.approach","rame %@ at %.0f m",                 "rame %@ à %.0f m")
        add("valcp.stations.barred","(barred by SP)",                      "(neutralisée par SP)")
        add("valcp.stations.none",  "(no rames)",                          "(aucune rame)")

        add("valcp.pax.title",      "\nPassenger load at %@\n\n",          "\nCharge voyageurs à %@\n\n")
        add("valcp.pax.header",     "    Rame   Pax   Capacity   Load     State\n",
                                    "    Rame   Voy   Capacité   Charge   État\n")
        add("valcp.pax.sep",        "    ----   ---   --------   ------   -----\n",
                                    "    ----   ---   --------   ------   -----\n")
        add("valcp.pax.none",       "    (no rames in service)\n",         "    (aucune rame en service)\n")
        add("valcp.pax.state.crush","CRUSH LOAD",                          "SURCHARGE")
        add("valcp.pax.state.full", "FULL",                                "COMPLET")
        add("valcp.pax.state.empty","EMPTY",                               "VIDE")
        add("valcp.pax.state.nominal","NOMINAL",                           "NOMINAL")

        add("valcp.rame.missrame",  "%SET-W-MISSPARM, usage: SET RAME <label> /qualifier\n",
                                    "%SET-W-MISSPARM, usage : SET RAME <label> /qualificatif\n")
        add("valcp.rame.nosuch",    "%%SET-W-NOSUCHRAME, no such rame \\%@\\\n",
                                    "%%SET-W-NOSUCHRAME, rame inconnue \\%@\\\n")
        add("valcp.rame.man.set",   "%%SET-S-MODE, rame %@ now in manual driving (CML)\n",
                                    "%%SET-S-MODE, rame %@ passée en conduite manuelle (CML)\n")
        add("valcp.rame.man.nochg", "%%SET-I-NOCHG, rame %@ already in manual driving\n",
                                    "%%SET-I-NOCHG, rame %@ déjà en conduite manuelle\n")
        add("valcp.rame.auto.set",  "%%SET-S-MODE, rame %@ returned to automatic pilot (CAI)\n",
                                    "%%SET-S-MODE, rame %@ rendue au pilotage automatique (CAI)\n")
        add("valcp.rame.auto.nochg","%%SET-I-NOCHG, rame %@ already in automatic pilot\n",
                                    "%%SET-I-NOCHG, rame %@ déjà en pilotage automatique\n")
        add("valcp.rame.speed.set", "%%SET-S-SPEED, rame %@ manual speed setpoint %.1f m/s\n",
                                    "%%SET-S-SPEED, consigne manuelle de la rame %@ : %.1f m/s\n")
        add("valcp.rame.speed.notmanual","%%SET-W-NOTMANUAL, rame %@ is in automatic pilot -- SET RAME /MANUAL first\n",
                                    "%%SET-W-NOTMANUAL, la rame %@ est en pilotage automatique -- SET RAME /MANUAL d'abord\n")
        add("valcp.rame.fu.on",     "%%SET-S-FU, rame %@ FU commanded\n",
                                    "%%SET-S-FU, FU commandé sur la rame %@\n")
        add("valcp.rame.fu.off",    "%%SET-S-FU, rame %@ FU released\n",
                                    "%%SET-S-FU, FU relâché sur la rame %@\n")
        add("valcp.rame.fault.portes","%%SET-S-FAULT, rame %@ door fault %@\n",
                                    "%%SET-S-FAULT, défaut portes rame %@ %@\n")
        add("valcp.rame.fault.traction","%%SET-S-FAULT, rame %@ traction fault %@\n",
                                    "%%SET-S-FAULT, défaut traction rame %@ %@\n")
        add("valcp.rame.fault.frein","%%SET-S-FAULT, rame %@ brake fault %@\n",
                                    "%%SET-S-FAULT, défaut frein rame %@ %@\n")
        add("valcp.rame.fault.ctc", "%%SET-S-FAULT, rame %@ CTC radio fault %@\n",
                                    "%%SET-S-FAULT, défaut radio CTC rame %@ %@\n")
        add("valcp.rame.fault.patinage","%%SET-S-FAULT, rame %@ wheel slip (patinage) %@\n",
                                    "%%SET-S-FAULT, patinage rame %@ %@\n")
        add("valcp.rame.fault.enrayage","%%SET-S-FAULT, rame %@ wheel slide (enrayage) %@\n",
                                    "%%SET-S-FAULT, enrayage rame %@ %@\n")
        add("valcp.rame.fault.set", "latched",                             "activé")
        add("valcp.rame.fault.cleared","cleared",                          "levé")
        add("valcp.rame.pneu.range","%%SET-W-IVPNEU, tire index must be 1..%d\n",
                                    "%%SET-W-IVPNEU, l'index du pneu doit être 1..%d\n")
        add("valcp.rame.pneu.cycled","%%SET-S-PNEU, rame %@ tire %d now %@\n",
                                    "%%SET-S-PNEU, pneu %2$d de la rame %1$@ : %3$@\n")
        add("valcp.rame.missqual",  "%SET-W-MISSQUAL, expected /MANUAL /AUTOMATIC /SPEED= /FU= /PORTES= /TRACTION= /FREIN= /CTC= /PATINAGE= /ENRAYAGE= or /PNEU=\n",
                                    "%SET-W-MISSQUAL, attendu /MANUAL /AUTOMATIC /SPEED= /FU= /PORTES= /TRACTION= /FREIN= /CTC= /PATINAGE= /ENRAYAGE= ou /PNEU=\n")

        // Diagnostics (LPD-DIAG).
        add("diag.suite",           "VAL-CTRL DIAGNOSTIC SUITE (LPD-DIAG)", "SUITE DE DIAGNOSTIC VAL-CTRL (LPD-DIAG)")
        add("diag.menu.copyright",  "LPD -- Lignes & Pilotage Dauphiné",   "LPD -- Lignes & Pilotage Dauphiné")
        add("diag.menu.title",      "Select a test and press RETURN",      "Sélectionnez un test et appuyez ENTRÉE")
        add("diag.menu.nav",        "Arrows select · RETURN runs · CTRL/Y exits",
                                    "Flèches : choisir · ENTRÉE : lancer · CTRL/Y : quitter")
        add("diag.operator",        "Operator",                            "Opérateur")
        add("diag.elapsed",         "Elapsed:",                            "Écoulé :")
        add("diag.col.rame",        "Rame  Test",                          "Rame  Test")
        add("diag.col.station",     "Station  Test",                       "Station  Test")
        add("diag.col.reading",     "Reading",                             "Mesure")
        add("diag.col.status",      "Status",                              "État")
        add("diag.status.running",  "RUNNING",                             "EN COURS")
        add("diag.status.queued",   "QUEUED",                              "EN ATTENTE")
        add("diag.status.pass",     "PASS",                                "CONFORME")
        add("diag.status.ok",       "OK",                                  "OK")
        add("diag.status.fail",     "FAIL",                                "DÉFAUT")
        add("diag.step.of",         "Step %d of %d",                       "Étape %d sur %d")
        add("diag.complete",        "Complete: %d/%d",                     "Terminé : %d/%d")
        add("diag.allpass",         "ALL TESTS PASS",                      "TOUS LES TESTS CONFORMES")
        add("diag.seeresults",      "SEE RESULTS ABOVE",                   "VOIR RÉSULTATS CI-DESSUS")
        add("diag.abort.hint",      "CTRL/Y aborts ",                      "CTRL/Y interrompt ")
        add("diag.exit.hint",       "CTRL/Y returns to the DCL prompt ",   "CTRL/Y revient à l'invite DCL ")
        add("diag.test.frein",      "FREIN_TEST -- brake-state audit",     "FREIN_TEST -- audit des freins")
        add("diag.test.portes",     "PORTES_TEST -- door cycle + interlock","PORTES_TEST -- cycle portes + asservissement")
        add("diag.test.pneu",       "PNEU_CAL -- tire-pressure calibration","PNEU_CAL -- calibration pression pneus")
        add("diag.test.quai",       "QUAI_LAMP_TEST -- platform lamp test", "QUAI_LAMP_TEST -- test lampes de quai")
        add("diag.step.frein.rame", "Rame %@   brake chain",               "Rame %@   chaîne de freinage")
        add("diag.step.frein.fw",   "Brake controller firmware",           "Micrologiciel du contrôleur de frein")
        add("diag.step.portes.cycle","Rame %@   door cycle",               "Rame %@   cycle des portes")
        add("diag.step.portes.interlock","Rame %@   traction interlock",   "Rame %@   asservissement traction")
        add("diag.step.pneu.read",  "Rame %@   pressure sweep",            "Rame %@   relevé des pressions")
        add("diag.step.pneu.span",  "Rame %@   span vs nominal",           "Rame %@   écart au nominal")
        add("diag.step.pneu.write", "Write calibration records",           "Écriture des enregistrements")
        add("diag.step.quai.station","%@   lamps + display",               "%@   lampes + afficheur")
        add("diag.step.quai.fw",    "Platform display firmware",           "Micrologiciel des afficheurs")
        add("diag.frein.reading.dragging","FU while moving",               "FU en mouvement")
        add("diag.frein.reading.released","released (moving)",             "desserré (en mvt)")
        add("diag.frein.reading.holding","%.1f kN holding",                "%.1f kN de retenue")
        add("diag.portes.reading.movingSuffix"," (in motion)",             " (en mouvement)")
        add("diag.portes.reading.locked","locked",                         "verrouillé")
        add("diag.portes.reading.violated","INTERLOCK OPEN",               "CHAÎNE OUVERTE")
        add("diag.pneu.reading.records","%d records",                      "%d entrées")
        add("diag.quai.reading.lit","lamps + display lit",                 "lampes + afficheur allumés")
        add("diag.reading.noRame",  "(no rame)",                           "(aucune rame)")
        add("diag.reading.noWorld", "(no world)",                          "(aucun monde)")

        return t
    }

    static func lookup(_ key: String, lang: Lang) -> String {
        if let row = table[key], let value = row[lang] { return value }
        if let row = table[key], let fallback = row[.en] { return fallback }
        return key
    }
}
