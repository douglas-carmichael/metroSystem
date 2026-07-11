import Foundation

// LANGUAGE DISCIPLINE.
//
// The UI is strictly bilingual: in EN mode no French appears and in FR
// mode no English appears, with three deliberate in-universe exceptions:
//   * OpenVMS SYSTEM messages / tables in the DCL terminal stay English in
//     both modes (real VMS shipped English-only); only LPD layered-product
//     content (VALCP, diagnostics, alarms display) localizes.
//   * Identifiers are language-neutral and identical in both modes: DCL
//     verbs and qualifiers, SCADA source/point tags (RAME 101, PNEU,
//     CTC_RADIO...), VMS process/facility names, and proper nouns
//     (station names, VAL, PCC, LPD).
//   * The FR domain acronyms every French metro document uses (CAI, CML,
//     FU, SP) render as their EN counterparts in EN mode (ATO, MAN, EB,
//     TEMP SERVICE).

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
        "alarm.msg.hwlink",
        "alarm.msg.deloc", "alarm.msg.comms", "alarm.msg.wayside",
        "alarm.msg.pratictransport",
    ]

    private static func buildTable() -> [String: [Lang: String]] {
        var t: [String: [Lang: String]] = [:]
        func add(_ key: String, _ en: String, _ fr: String) {
            t[key] = [.en: en, .fr: fr]
        }

        add("window.control",       "PCC Dispatcher",                      "Régulation PCC")
        add("window.scene",         "Line Synoptic 3D",                    "Synoptique de ligne 3D")
        add("window.dcl",           "DCL Terminal",                        "Terminal DCL")
        add("window.dynamics",      "Train Dynamics",                      "Dynamique des rames")
        add("window.traindetail",   "Train Detail",                        "Détail rame")

        // Per-rame detail window.
        add("detail.signallost",    "SIGNAL LOST — train withdrawn",       "SIGNAL PERDU — rame retirée")
        add("detail.subtitle",      "VEHICLE SYNOPSIS",                    "SYNTHÈSE VÉHICULE")
        add("btn.detail",           "DETAIL",                              "DÉTAIL")
        add("detail.gauge.speed",   "SPEED",                               "VITESSE")
        add("detail.gauge.consigne","SP",                                  "CONS")
        add("detail.gauge.ma",      "MOVEMENT AUTHORITY",                  "AUTORISATION MVT")
        add("detail.gauge.pax",     "PASSENGER LOAD",                      "CHARGE VOYAGEURS")
        add("detail.gauge.traction","TRACTION CURRENT",                    "COURANT TRACTION")
        add("detail.sec.asserv",    "SPEED REGULATION",                    "ASSERVISSEMENT")
        add("detail.asserv.consigne","SETPOINT",                          "CONSIGNE VIT.")
        add("detail.asserv.error",  "SPEED ERROR",                        "ERREUR VIT.")
        add("detail.asserv.accel",  "ACCELERATION",                       "ACCÉLÉRATION")
        add("detail.asserv.dist",   "DISTANCE TO MA",                     "DIST. CIBLE AM")
        add("detail.asserv.target", "LINE SPEED",                         "VITESSE LIGNE")
        add("detail.sec.traction",  "TRACTION / BRAKING",                 "TRACTION / FREINAGE")
        add("detail.traction.current","CURRENT",                          "COURANT")
        add("detail.traction.torque","TORQUE",                            "COUPLE")
        add("detail.traction.motoring","MOTORING",                        "TRACTION")
        add("detail.traction.braking","BRAKING",                          "FREINAGE")
        add("detail.traction.fu",   "EMERGENCY BRAKE",                    "FREINAGE URGENCE")
        add("detail.sec.exploit",   "OPERATIONS",                         "EXPLOITATION")
        add("detail.exploit.dwell", "STATION DWELL",                      "STATIONNEMENT")
        add("detail.exploit.hold",  "DEPARTURE HOLD",                     "RETENUE DÉPART")
        add("detail.sec.atp",       "ATP / SAFETY CHAIN",                 "ATP / CHAÎNE DE SÉCURITÉ")
        add("detail.atp.doorlock",  "DOOR INTERLOCK",                     "ASSERV. PORTES")
        add("detail.atp.overspeed", "OVERSPEED",                          "SURVITESSE")
        add("detail.atp.ma",        "MA MARGIN",                          "MARGE AM")
        add("detail.atp.brake",     "SERVICE BRAKE",                      "FREIN SERVICE")
        add("detail.atp.adhesion",  "ADHESION",                           "ADHÉRENCE")
        add("detail.atp.chain",     "SAFETY CHAIN",                       "CHAÎNE SÉCURITÉ")
        add("detail.atp.ok",        "OK",                                 "OK")
        add("detail.atp.open",      "OPEN",                               "OUVERT")
        add("detail.sec.aux",       "AUXILIARIES",                        "AUXILIAIRES")
        add("detail.aux.mainv",     "LINE VOLTAGE",                       "TENSION LIGNE")
        add("detail.aux.cvs",       "CONVERTER",                          "CONVERTISSEUR")
        add("detail.aux.battery",   "BATTERY",                            "BATTERIE")
        add("detail.aux.lighting",  "LIGHTING",                           "ÉCLAIRAGE")
        add("detail.aux.compressor","MAIN RESERVOIR",                     "RÉSERVOIR PPAL")
        add("detail.aux.comprun",   "COMPRESSOR RUN",                     "COMPRESSEUR ON")
        add("detail.aux.brakebox",  "BRAKE-BOX TEMP",                     "TEMP COFFRE-FREIN")
        add("detail.aux.temp",      "INTERIOR TEMP",                      "TEMP INTÉRIEURE")
        add("detail.sec.pneu",      "TIRES (VAL)",                        "PNEUS (VAL)")
        add("detail.bogie1",        "BOGIE 1",                            "BOGIE 1")
        add("detail.bogie2",        "BOGIE 2",                            "BOGIE 2")
        add("detail.tire.n",        "TIRE %d",                            "PNEU %d")
        add("detail.diag.traction.label","TRACTION DIAGNOSTIC",           "DIAGNOSTIC TRACTION")
        add("detail.diag.auto.label","ATO / ATP DIAGNOSTIC",              "DIAGNOSTIC CAI / PA")
        add("detail.diag.ras",      "NOMINAL",                            "RAS")
        add("detail.diag.traction.engine","TRACTION CHAIN FAULT / BREAKER OPEN",
                                    "DÉFAUT CHAÎNE TRACTION / DISJONCTEUR OUVERT")
        add("detail.diag.traction.brake","BRAKE FAULT / TIRE ISOLATION",  "DÉFAUT FREINAGE / ISOLATION PNEU")
        add("detail.diag.traction.fu","EMERGENCY BRAKE ACTIVE",           "FREINAGE D'URGENCE ACTIVÉ")
        add("detail.diag.auto.manual","IN MANUAL DRIVING",                "EN CONDUITE MANUELLE")
        add("detail.diag.auto.signal","SIGNAL LOSS / INVALID SPEED CODE", "PERTE SIGNAL / CODE VITESSE INVALIDE")
        add("detail.diag.auto.door","DOOR FAULT / SAFETY LOOP OPEN",      "DÉFAUT PORTES / BOUCLE DE SÉCURITÉ OUVERTE")
        add("detail.diag.auto.estop","EMERGENCY STOP FROM PCC",           "ARRÊT D'URGENCE CMD PCC")
        add("detail.diag.auto.nominal","NOMINAL / SAFETY CHAIN MADE",     "NOMINAL / CHAÎNE FS ÉTABLIE")
        // Auxiliary controls (owner-driven telecommands on the train-detail
        // screen) and the electrical-synoptic diagram.
        add("detail.sec.diagram",   "ELECTRICAL SYNOPTIC",                "SYNOPTIQUE ÉLECTRIQUE")
        add("detail.sec.controls",  "AUXILIARY CONTROLS",                 "COMMANDES AUXILIAIRES")
        add("detail.controls.remote","REMOTE RAME — CONTROLS READ-ONLY",  "RAME DISTANTE — COMMANDES EN LECTURE SEULE")
        // Toggle controls.
        add("ctl.delestage",        "LOAD SHEDDING",                      "DÉLESTAGE BT")
        add("ctl.eclairage",        "LIGHTING",                           "ÉCLAIRAGE")
        add("ctl.ventilation",      "VENTILATION",                        "VENTILATION")
        add("ctl.chauffage",        "HEATING",                            "CHAUFFAGE")
        add("ctl.suspension",       "SUSPENSION",                         "SUSPENSION")
        add("ctl.compresseur",      "COMPRESSOR",                         "COMPRESSEUR")
        // Momentary telecommands.
        add("ctl.razmultimedia",    "RESET MULTIMEDIA",                   "RAZ MULTIMÉDIA")
        add("ctl.acquitfu",         "ACK EB COUNTER",                     "ACQUIT. COMPTEUR FU")
        add("ctl.sonorisation",     "PA TEST",                            "TEST SONORISATION")
        add("ctl.videoinit",        "VIDEO INIT",                         "INIT SYSTÈME VIDÉO")
        add("ctl.archivage",        "DAM ARCHIVE REC",                    "ENR ARCHIVAGE DAM")
        // Electrical-synoptic node labels.
        add("detail.node.shoel",    "SHOE L",                             "FROTTEUR G")
        add("detail.node.shoer",    "SHOE R",                             "FROTTEUR D")
        add("detail.node.bus",      "750 V BUS",                          "BUS 750 V")
        add("detail.node.cvs",      "CVS",                                "CVS")
        add("detail.node.battery",  "BATTERY",                            "BATTERIE")
        add("detail.node.compressor","COMPRESSOR",                        "GROUPE MA")
        add("detail.node.reservoir","RESERVOIR",                          "RÉSERVOIR")
        add("detail.node.delestage","LOAD SHED",                          "DÉLESTAGE")
        add("detail.node.lighting", "LIGHTING",                           "ÉCLAIRAGE")
        add("detail.node.ventilation","VENT",                             "VENTIL.")
        // Display-skin toggle (retro phosphor vs ISA-101 high-performance HMI).
        add("theme.label",          "DISPLAY",                            "AFFICHAGE")
        add("theme.retro",          "RETRO",                              "RÉTRO")
        add("theme.iso",            "ISA-101",                            "ISA-101")
        // Passenger exchange (montée / descente) on the detail screen.
        add("detail.exploit.boarding","BOARDING",                         "MONTÉE")
        add("detail.exploit.alighting","ALIGHTING",                       "DESCENTE")
        // Subsystem drill-down panels -- click a node on the electrical synoptic.
        add("sub.hint",             "◄ CLICK A SUBSYSTEM",                "◄ CLIQUER UN SOUS-SYSTÈME")
        add("sub.title.pickup",     "750 V PICKUP",                       "CAPTAGE 750 V")
        add("sub.title.cvs",        "STATIC CONVERTER (CVS)",             "CONVERTISSEUR (CVS)")
        add("sub.title.compressor", "MOTOR-ALTERNATOR GROUP",             "GROUPE MOTO-ALTERNATEUR")
        add("sub.title.battery",    "BATTERY",                            "BATTERIE")
        add("sub.title.delestage",  "LOAD SHEDDING (BT)",                 "DÉLESTAGE BT")
        add("sub.title.lighting",   "LIGHTING",                           "ÉCLAIRAGE")
        add("sub.title.ventilation","VENTILATION / HVAC",                 "VENTILATION / CVCA")
        add("sub.row.linev",        "LINE VOLTAGE",                       "TENSION LIGNE")
        add("sub.row.current",      "CURRENT",                            "INTENSITÉ")
        add("sub.row.shoel",        "SHOE L",                             "FROTTEUR G")
        add("sub.row.shoer",        "SHOE R",                             "FROTTEUR D")
        add("sub.row.input",        "INPUT",                              "ENTRÉE")
        add("sub.row.output",       "OUTPUT",                             "SORTIE")
        add("sub.row.temp",         "TEMPERATURE",                        "TEMPÉRATURE")
        add("sub.row.load",         "LOAD",                               "CHARGE")
        add("sub.row.state",        "STATE",                              "ÉTAT")
        add("sub.row.pressure",     "PRESSURE",                           "PRESSION")
        add("sub.row.oil",          "OIL",                                "HUILE")
        add("sub.row.vibration",    "VIBRATION",                          "VIBRATION")
        add("sub.row.voltage",      "VOLTAGE",                            "TENSION")
        add("sub.row.charge",       "CHARGE",                             "CHARGE")
        add("sub.row.circa",        "CIRCUIT A",                          "CIRCUIT A")
        add("sub.row.circb",        "CIRCUIT B",                          "CIRCUIT B")
        add("sub.row.mode",         "MODE",                               "MODE")
        add("sub.row.setpoint",     "SETPOINT",                           "CONSIGNE")
        add("sub.row.interior",     "INTERIOR TEMP",                      "TEMP INTÉRIEURE")
        add("sub.row.fans",         "FANS",                               "VENTILATEURS")
        add("sub.row.lighting",     "LIGHTING",                           "ÉCLAIRAGE")
        add("sub.row.ventilation",  "VENTILATION",                        "VENTILATION")
        add("sub.val.active",       "ACTIVE",                             "ACTIF")
        add("sub.val.inactive",     "INACTIVE",                           "INACTIF")
        add("sub.val.run",          "RUN",                                "MARCHE")
        add("sub.val.stop",         "STOP",                               "ARRÊT")
        add("sub.val.ok",           "OK",                                 "OK")
        add("sub.val.normal",       "NORMAL",                             "NORMAL")
        add("sub.val.reduced",      "REDUCED",                            "RÉDUIT")
        add("sub.val.on",           "ON",                                 "MARCHE")
        add("sub.val.off",          "OFF",                                "ARRÊT")
        add("sub.val.ac",           "AIR-CONDITIONING",                   "CLIMATISATION")

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
        add("login.lpd.frein",  "  RUN FREIN_TEST       Brake-state audit on every train",
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
        add("status.peers",         "PEERS",                               "PAIRS")
        add("status.peers.none",    "NONE",                                "AUCUN")
        add("status.peers.node",    "NODE",                                "NŒUD")
        add("status.peers.nodes",   "NODES",                               "NŒUDS")
        add("status.rames",         "TRAINS",                              "RAMES")
        add("status.telnet",        "TELNET",                              "TELNET")
        add("status.telnet.none",   "NONE",                                "AUCUNE")
        add("status.telnet.one",    "1 SESSION",                           "1 SESSION")
        add("status.telnet.many",   "%d SESSIONS",                         "%d SESSIONS")
        add("status.modbus",        "MODBUS",                              "MODBUS")
        add("status.modbus.none",   "NONE",                                "AUCUN")
        add("status.modbus.one",    "1 CLIENT",                            "1 CLIENT")
        add("status.modbus.many",   "%d CLIENTS",                          "%d CLIENTS")
        add("status.mode",          "MODE",                                "MODE")
        add("status.mode.stopped",  "SERVICE STOPPED",                     "SERVICE ARRÊTÉ")
        add("status.mode.normal",   "NORMAL (ATO)",                        "NORMAL (CAI)")
        add("status.mode.sp",       "TEMP SERVICE (SP)",                   "SERVICE PROVISOIRE")
        add("status.mode.emergency","EMERGENCY STOP",                      "ARRÊT D'URGENCE")
        add("status.ready",         "READY",                               "PRÊT")
        add("status.alarms",        "ALARMS",                              "ALARMES")
        add("status.alarms.normal", "NORMAL",                              "NORMAL")
        add("status.alarms.summary","%d ACT / %d UNACK",                   "%d ACT / %d N.ACQ")

        // HUD (3D synoptic).
        add("hud.rames",            "TRAINS",                              "RAMES")
        add("hud.mode",             "MODE",                                "MODE")
        add("scene.recenter",       "RECENTER",                            "RECENTRER")
        add("scene.isolate",        "FOLLOW TRAIN",                        "SUIVRE RAME")
        add("scene.isolated.prefix","FOLLOWING:",                          "SUIVI :")

        // Line control panel.
        add("line.panel.title",     "LINE CONTROL",                        "COMMANDE DE LIGNE")
        add("line.service.start",   "START SERVICE",                       "DÉBUT DE SERVICE")
        add("line.service.stop",    "STOP SERVICE",                        "FIN DE SERVICE")
        add("line.emergency",       "EMERGENCY STOP",                      "ARRÊT D'URGENCE")
        add("line.addtrain",        "ADD TRAIN",                           "AJOUTER RAME")
        add("line.sp.label",        "TEMP SERVICE (SP)",                   "SERVICE PROVISOIRE")
        add("line.sp.from",         "FROM",                                "DE")
        add("line.sp.to",           "TO",                                  "À")
        add("line.sp.interval",     "HEADWAY",                             "INTERVALLE")
        add("line.sp.engage",       "ENGAGE",                              "ENGAGER")
        add("line.sp.clear",        "CLEAR",                               "LEVER")
        add("line.sp.active",       "Temp service active: %@ <-> %@  (headway %d s)",
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
        add("alarm.msg.emergency",  "General emergency stop: emergency brake commanded on every train",
                                    "Arrêt d'urgence général : FU commandé sur toutes les rames")
        add("alarm.msg.sp",         "Temporary service in force; ZC barriers protect the barred section",
                                    "Service provisoire en vigueur ; barrières ZC sur la section neutralisée")
        add("alarm.msg.overspeed",  "ATP overspeed: speed above commanded setpoint",
                                    "Survitesse ATP : vitesse au-dessus de la consigne")
        add("alarm.msg.malimit",    "Movement-authority limit encroached",
                                    "Empiètement sur la limite d'autorisation de mouvement")
        add("alarm.msg.fu",         "Emergency brake commanded",
                                    "Freinage d'urgence (FU) commandé")
        add("alarm.msg.doorfault",  "Door fault: interlock chain open",
                                    "Défaut portes : chaîne d'asservissement ouverte")
        add("alarm.msg.enginefault","Traction fault: motoring unavailable",
                                    "Défaut traction : motorisation indisponible")
        add("alarm.msg.brakefault", "Brake fault: service brake degraded",
                                    "Défaut frein : freinage de service dégradé")
        add("alarm.msg.signalfault","CTC radio fault: movement authority lost",
                                    "Défaut radio CTC : autorisation de mouvement perdue")
        add("alarm.msg.patinage",   "Wheel slip detected under traction",
                                    "Patinage détecté en traction")
        add("alarm.msg.enrayage",   "Wheel slide detected under braking",
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
        add("alarm.msg.controller", "PCC controller watchdog fault -- all trains held",
                                    "Défaut chien de garde PCC -- toutes rames retenues")
        add("alarm.msg.hwlink",     "Model-track hardware link down while output armed",
                                    "Liaison matériel voie miniature perdue, sortie armée")
        add("alarm.msg.deloc",      "Train delocalized -- position lost, manual re-reference required",
                                    "Rame délocalisée -- position perdue, re-référencement manuel requis")
        add("alarm.msg.comms",      "Train-to-wayside comms degraded or lost",
                                    "Liaison sol-train dégradée ou perdue")
        add("alarm.msg.wayside",    "Wayside sensor station fault",
                                    "Défaut station de détection au sol")
        add("alarm.msg.pratictransport", "PRATIC telemetry transport down",
                                    "Transport de télémesure PRATIC coupé")
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

        // Per-train panels.
        add("train.rame",           "TRAIN",                               "RAME")
        add("train.tag.local",      "LOCAL",                               "LOCALE")
        add("train.tag.remote",     "REMOTE",                              "DISTANTE")
        add("train.mode.cai",       "ATO",                                 "CAI")
        add("train.mode.cml",       "MAN",                                 "CML")
        add("train.canton",         "BLOCK",                               "CANTON")
        add("block.name",           "Block %d",                            "Canton %d")
        add("block.short",          "B%d",                                 "C%d")
        add("train.speed",          "SPEED",                               "VITESSE")
        add("train.ma",             "MA",                                  "AM")
        add("train.doors",          "DOORS",                               "PORTES")
        add("train.pax",            "PAX",                                 "VOYAGEURS")
        add("train.next",           "NEXT STOP",                           "PROCHAIN ARRÊT")
        add("train.status",         "STATUS",                              "ÉTAT")
        add("train.status.stopped", "STOPPED",                             "ARRÊT")
        add("train.status.moving",  "MOVING",                              "EN MARCHE")
        add("train.status.emergency","EB",                                 "FU")
        add("train.status.docked",  "AT PLATFORM",                         "À QUAI")
        add("train.faults",         "FAULTS",                              "DÉFAUTS")
        add("train.faults.label",   "FAULT INJECTION",                     "INJECTION DE DÉFAUTS")
        add("train.manual.speed",   "MANUAL SPEED",                        "VITESSE MANUELLE")
        add("train.tires.label",    "TIRES",                               "PNEUS")
        add("train.tires.hint",     "(click to cycle)",                    "(cliquer pour changer)")
        add("train.tire.ok",        "OK",                                  "OK")
        add("train.tire.low",       "LOW PRESSURE",                        "PRESSION BASSE")
        add("train.tire.puncture",  "PUNCTURE",                            "CREVAISON")
        add("train.tire.burst",     "BURST",                               "ÉCLATEMENT")

        // Fault names (panel chips, fault summaries, VALCP fault lists).
        add("fault.portes",         "DOORS",                               "PORTES")
        add("fault.traction",       "TRACTION",                            "TRACTION")
        add("fault.frein",          "BRAKE",                               "FREIN")
        add("fault.ctc",            "CTC RADIO",                           "RADIO CTC")
        add("fault.patinage",       "SLIP",                                "PATINAGE")
        add("fault.enrayage",       "SLIDE",                               "ENRAYAGE")

        add("door.open",            "OPEN",                                "OUVERTES")
        add("door.closed",          "CLOSED",                              "FERMÉES")

        add("btn.door.open",        "OPEN DOORS",                          "OUVRIR PORTES")
        add("btn.door.close",       "CLOSE DOORS",                         "FERMER PORTES")
        add("btn.mode.label",       "MODE",                                "MODE")
        add("btn.mode.auto",        "AUTO",                                "AUTO")
        add("btn.mode.manual",      "MANUAL",                              "MANUEL")
        add("btn.fu",               "EB",                                  "FU")
        add("btn.remove",           "WITHDRAW",                            "RETIRER")

        // Footer / help.
        add("hint.line",            "TAB train · O/C doors · A mode · F EB · E emergency · M Modbus · ?/F1 help",
                                    "TAB rame · O/C portes · A mode · F FU · E urgence · M Modbus · ?/F1 aide")
        add("hint.lang",            "LANG",                                "LANGUE")
        add("help.title",           "KEYBOARD HELP",                       "AIDE CLAVIER")
        add("help.dismiss",         "Press ESC, ? or click to dismiss",    "Appuyez ESC, ? ou cliquez pour fermer")
        add("help.focus.hint",      "FOCUSED TRAIN",                       "RAME SÉLECTIONNÉE")
        add("help.k.help",          "Show / hide this help",               "Afficher / masquer cette aide")
        add("help.k.tab",           "Cycle the focused train",             "Changer la rame sélectionnée")
        add("help.k.lang",          "Switch language (EN / FR)",           "Changer de langue (EN / FR)")
        add("help.k.doors",         "Open / close the focused train's doors", "Ouvrir / fermer les portes de la rame")
        add("help.k.mode",          "Toggle AUTO / MANUAL on the focused train",
                                    "Basculer AUTO / MANUEL sur la rame")
        add("help.k.fu",            "Toggle the emergency brake (EB) on the focused train",
                                    "Basculer le FU sur la rame sélectionnée")
        add("help.k.emergency",     "Toggle the line-wide emergency stop", "Basculer l'arrêt d'urgence général")
        add("help.k.modbus",        "Show the Modbus register map",        "Afficher la carte des registres Modbus")
        add("help.k.dcl",           "Open a DCL terminal",                 "Ouvrir un terminal DCL")
        add("help.k.scene",         "Open the 3D line synoptic",           "Ouvrir le synoptique 3D")
        add("help.k.dynamics",      "Open the dynamics scope",             "Ouvrir l'oscilloscope dynamique")
        add("help.k.quit",          "Quit",                                "Quitter")
        add("help.k.esc",           "Dismiss overlays",                    "Fermer les fenêtres superposées")

        // Dynamics window.
        add("dynamics.title",       "TRAIN DYNAMICS — SPEED REGULATION",   "DYNAMIQUE DES RAMES — ASSERVISSEMENT")
        add("dynamics.empty",       "(no trains in service)",              "(aucune rame en service)")
        add("dynamics.select.label","TRAINS",                              "RAMES")
        add("dynamics.select.empty","(none)",                              "(aucune)")
        add("dynamics.select.all",  "ALL",                                 "TOUTES")
        add("dynamics.select.none", "NONE",                                "AUCUNE")
        add("dynamics.col.rame",    "TRAIN",                               "RAME")
        add("dynamics.col.pos",     "POSITION",                            "POSITION")
        add("dynamics.col.vel",     "SPEED",                               "VITESSE")
        add("dynamics.col.consigne","SETPOINT",                            "CONSIGNE")
        add("dynamics.col.acc",     "ACCEL",                               "ACCÉL")
        add("dynamics.col.ma",      "MA",                                  "AM")
        add("dynamics.col.state",   "STATE",                               "ÉTAT")
        add("dynamics.state.accel", "ACCEL",                               "ACCÉL")
        add("dynamics.state.cruise","CRUISE",                              "PALIER")
        add("dynamics.state.decel", "DECEL",                               "DÉCÉL")
        add("dynamics.state.stopping","STOPPING",                          "ARRÊT EN COURS")
        add("dynamics.state.idle",  "IDLE",                                "REPOS")
        add("dynamics.state.dwell", "DWELL",                               "À QUAI")
        add("dynamics.state.manual","MANUAL",                              "CML")
        add("dynamics.state.eb",    "EB",                                  "FU")
        add("dynamics.state.hold",  "HOLD",                                "RETENUE")
        add("dynamics.trace.title", "SPEED TRACE",                         "TRACÉ DE VITESSE")
        add("dynamics.trace.axis",  "60 s window · line speed dashed",     "fenêtre 60 s · vitesse ligne en tirets")
        add("dynamics.trace.empty", "(collecting samples...)",             "(acquisition en cours...)")
        add("dynamics.profile.fmt", "LIMITS  V %.1f m/s · accel %.2f m/s² · service brake %.2f m/s² · EB %.2f m/s²",
                                    "LIMITES  V %.1f m/s · accél %.2f m/s² · frein de service %.2f m/s² · FU %.2f m/s²")
        add("dynamics.refresh",     "Sampling every 500 ms",               "Échantillonnage toutes les 500 ms")

        // Modbus legend (PCC overlay + SHOW MODBUS).
        add("modbus.legend.title",  "MODBUS TCP REGISTER MAP",             "CARTE DES REGISTRES MODBUS TCP")
        add("modbus.legend.endpoint","Endpoint: localhost port 5020 · unit-id ignored · FC 01/02/03/04/05/06/0F/10",
                                    "Point d'accès : localhost port 5020 · unit-id ignoré · FC 01/02/03/04/05/06/0F/10")
        add("modbus.legend.coil",   "COILS (R/W, FC 01/05) — pulse-on commands",
                                    "COILS (L/É, FC 01/05) — commandes à impulsion")
        add("modbus.legend.di",     "DISCRETE INPUTS (RO, FC 02)",         "ENTRÉES TOR (LS, FC 02)")
        add("modbus.legend.hr",     "HOLDING REGISTERS (R/W, FC 03/06)",   "REGISTRES DE MAINTIEN (L/É, FC 03/06)")
        add("modbus.legend.ir",     "INPUT REGISTERS (RO, FC 04)",         "REGISTRES D'ENTRÉE (LS, FC 04)")
        add("modbus.legend.chain",  "SAFETY CHAIN (1 = contact closed / healthy)",
                                    "CHAÎNE DE SÉCURITÉ (1 = contact fermé / sain)")
        add("modbus.reg.dooropen",  "Door OPEN command per train",         "Commande OUVERTURE portes par rame")
        add("modbus.reg.doorclose", "Door CLOSE command per train",        "Commande FERMETURE portes par rame")
        add("modbus.reg.fuset",     "EB SET (command emergency brake)",    "FU SERRÉ (commander le freinage d'urgence)")
        add("modbus.reg.furelease", "EB RELEASE",                          "FU RELÂCHÉ")
        add("modbus.reg.local",     "Train is locally owned",              "Rame pilotée par ce nœud")
        add("modbus.reg.moving",    "Train is moving",                     "Rame en mouvement")
        add("modbus.reg.doorsopen", "Doors open",                          "Portes ouvertes")
        add("modbus.reg.fuapplied", "Emergency brake applied",             "Freinage d'urgence appliqué")
        add("modbus.reg.faultdoor", "Door fault latched",                  "Défaut portes verrouillé")
        add("modbus.reg.faulttraction","Traction fault latched",           "Défaut traction verrouillé")
        add("modbus.reg.faultbrake","Brake fault latched",                 "Défaut frein verrouillé")
        add("modbus.reg.faultctc",  "CTC radio fault latched",             "Défaut radio CTC verrouillé")
        add("modbus.reg.faultslip", "Wheel slip latched",                  "Patinage verrouillé")
        add("modbus.reg.faultslide","Wheel slide latched",                 "Enrayage verrouillé")
        add("modbus.chain.doorinterlock","Door interlock proven",          "Asservissement portes prouvé")
        add("modbus.chain.overspeed","Overspeed governor OK",              "Contrôle de survitesse OK")
        add("modbus.chain.ma",      "MA margin OK (not encroached)",       "Marge d'AM OK (pas d'empiètement)")
        add("modbus.chain.brake",   "Service brake OK",                    "Frein de service OK")
        add("modbus.chain.adhesion","Adhesion OK (no burst tire)",         "Adhérence OK (aucun pneu éclaté)")
        add("modbus.chain.intact",  "Safety chain intact (series loop)",   "Chaîne de sécurité intacte (boucle série)")
        add("modbus.reg.mode",      "Mode (0 = Manual, 1 = Auto)",         "Mode (0 = Manuel, 1 = Auto)")
        add("modbus.reg.setspeed",  "Manual speed setpoint x10 (m/s)",     "Consigne manuelle x10 (m/s)")
        add("modbus.reg.position",  "Position x10 (metres)",               "Position x10 (mètres)")
        add("modbus.reg.speed",     "Speed x100, signed (+fwd / -rev)",    "Vitesse x100, signée (+avant / -arrière)")
        add("modbus.reg.consigne",  "Speed setpoint x100",                 "Consigne de vitesse x100")
        add("modbus.reg.ma",        "Movement-authority distance x10 (m)", "Distance d'autorisation de mouvement x10 (m)")
        add("modbus.reg.pax",       "Passenger count",                     "Nombre de voyageurs")
        add("modbus.reg.status",    "Status (0 stop, 1 run, 2 EB, 3 platform)",
                                    "État (0 arrêt, 1 marche, 2 FU, 3 à quai)")
        add("modbus.reg.canton",    "Canton number",                       "Numéro de canton")
        add("modbus.reg.tire",      "Worst tire (0 OK .. 3 burst)",        "Pire pneu (0 OK .. 3 éclaté)")
        add("modbus.reg.traincount","Trains known (local + remote)",       "Rames connues (locales + distantes)")
        add("modbus.reg.peers",     "Remote peers connected",              "Nœuds pairs connectés")
        add("modbus.reg.cantoncount","Canton count",                       "Nombre de cantons")
        add("modbus.reg.telnet",    "Telnet sessions",                     "Sessions telnet")
        add("modbus.reg.clients",   "Modbus clients connected",            "Clients Modbus connectés")
        add("modbus.reg.linemode",  "Line mode (0 stop, 1 normal, 2 SP, 3 emerg)",
                                    "Mode ligne (0 arrêt, 1 normal, 2 SP, 3 urgence)")
        add("modbus.reg.spfrom",    "Temp-service start station (0 none)", "Station de départ du SP (0 aucun)")
        add("modbus.reg.spto",      "Temp-service end station (0 none)",   "Station d'arrivée du SP (0 aucun)")
        add("modbus.reg.spheadway", "Temp-service headway (s)",            "Intervalle du SP (s)")
        add("modbus.reg.alarms",    "Active SCADA alarms",                 "Alarmes SCADA actives")
        add("modbus.reg.severity",  "Highest severity (0 none .. 4 critical)",
                                    "Gravité maximale (0 aucune .. 4 critique)")
        add("modbus.reg.unack",     "Unacknowledged alarms (UNACK)",       "Alarmes non acquittées (N.ACQ)")
        add("modbus.reg.shelved",   "Shelved alarms (SHLVD)",              "Alarmes suspendues (SUSP)")
        add("modbus.reg.rtn",       "Returned-to-normal, unacked (RTN)",   "Retour à la normale, non acquittées (RAN)")
        add("modbus.reg.tracklen",  "Track length (metres)",               "Longueur de la voie (mètres)")

        // Model-track hardware link (SHOW HARDWARE / SET HARDWARE).
        add("hardware.title",       "MODEL-TRACK HARDWARE LINK",           "LIAISON MATÉRIEL VOIE MINIATURE")
        add("hardware.driver",      "Driver",                              "Pilote")
        add("hardware.link",        "Link",                                "Liaison")
        add("hardware.output",      "Output",                              "Sortie")
        add("hardware.output.enabled","ENABLED",                           "ACTIVÉE")
        add("hardware.output.disabled","DISABLED",                         "DÉSACTIVÉE")
        add("hardware.nodriver",    "none selected",                       "aucun sélectionné")
        add("hardware.endpoint",    "Endpoint: %@ port %d",                "Point d'accès : %@ port %d")
        add("hardware.stats",       "Throttle scale: %.2f   Sensor resync: %@   Frames sent: %d",
                                    "Échelle traction : %.2f   Recalage capteurs : %@   Trames émises : %d")
        add("hardware.unitmap",     "Unit map (rame -> hardware unit):",   "Table des unités (rame -> unité matérielle) :")
        add("hardware.unitmap.default","(unmapped rames use their numeric label as the unit)",
                                    "(les rames non affectées utilisent leur numéro comme unité)")
        add("hardware.drivers.available","Available drivers:",             "Pilotes disponibles :")
        add("hardware.sensors.recent","Recent layout sensor events:",      "Derniers événements capteurs de la voie :")
        add("hardware.sensors.none","none",                                "aucun")
        add("hardware.sensor.active","ACTIVE",                             "ACTIF")
        add("hardware.sensor.clear","CLEAR",                               "LIBRE")
        add("hardware.hint",        "SET HARDWARE /DRIVER=name /HOST=h /PORT=n /CONNECT /ENABLE arms the output",
                                    "SET HARDWARE /DRIVER=nom /HOST=h /PORT=n /CONNECT /ENABLE arme la sortie")
        add("hardware.state.offline","OFFLINE",                            "HORS LIGNE")
        add("hardware.state.connecting","CONNECTING",                      "CONNEXION")
        add("hardware.state.ready", "READY",                               "PRÊTE")
        add("hardware.state.failed","FAILED (%@)",                         "DÉFAUT (%@)")
        add("hardware.set.driver.ok","Driver set to %@.",                  "Pilote réglé sur %@.")
        add("hardware.set.driver.bad","No such driver: %@ -- SHOW HARDWARE lists the available drivers.",
                                    "Pilote inconnu : %@ -- SHOW HARDWARE liste les pilotes disponibles.")
        add("hardware.set.endpoint.ok","Endpoint set to %@ port %d.",      "Point d'accès réglé sur %@ port %d.")
        add("hardware.set.unit.ok", "Rame %@ mapped to hardware unit %d.", "Rame %@ affectée à l'unité matérielle %d.")
        add("hardware.set.unit.clear","Rame %@ unmapped.",                 "Affectation de la rame %@ supprimée.")
        add("hardware.set.unit.bad","Usage: /UNIT=(rame,unit) to map, /UNIT=(rame) to clear.",
                                    "Usage : /UNIT=(rame,unité) pour affecter, /UNIT=(rame) pour supprimer.")
        add("hardware.set.scale.ok","Throttle scale set to %.2f.",         "Échelle de traction réglée à %.2f.")
        add("hardware.set.scale.bad","Scale must be between 0.05 and 2.00.",
                                    "L'échelle doit être comprise entre 0.05 et 2.00.")
        add("hardware.set.resync.on","Sensor position resync ON.",         "Recalage de position par capteurs ACTIVÉ.")
        add("hardware.set.resync.off","Sensor position resync OFF.",       "Recalage de position par capteurs DÉSACTIVÉ.")
        add("hardware.set.connect", "Connecting to %@ port %d ...",        "Connexion à %@ port %d ...")
        add("hardware.set.disconnect","Link closed; stop-all sent first.", "Liaison fermée ; arrêt général envoyé au préalable.")
        add("hardware.set.noconnect","No driver selected -- SET HARDWARE /DRIVER=name first.",
                                    "Aucun pilote sélectionné -- SET HARDWARE /DRIVER=nom d'abord.")
        add("hardware.set.enable.on","Hardware output ENABLED -- local rames now drive the physical units.",
                                    "Sortie matériel ACTIVÉE -- les rames locales pilotent les unités physiques.")
        add("hardware.set.enable.off","Hardware output DISABLED -- stop-all sent to the layout.",
                                    "Sortie matériel DÉSACTIVÉE -- arrêt général envoyé à la voie.")
        add("hardware.set.power.on","Track power ON.",                     "Alimentation de la voie MARCHE.")
        add("hardware.set.power.off","Track power OFF.",                   "Alimentation de la voie ARRÊT.")
        add("hardware.set.power.unsup","The selected driver does not control track power (or the link is down).",
                                    "Le pilote sélectionné ne gère pas l'alimentation de la voie (ou la liaison est coupée).")
        add("hardware.set.missqual","Missing qualifier -- see HELP SET HARDWARE.",
                                    "Qualificatif manquant -- voir HELP SET HARDWARE.")

        // Backend selection (SHOW/SET BACKEND) and the PRATIC network
        // surface (SHOW/SET PRATIC).
        add("backend.title",        "STATE BACKENDS (* = active)",         "MOTEURS D'ÉTAT (* = actif)")
        add("backend.val.summary",  "Self-contained VAL simulation (the classic line)",
                                    "Simulation VAL autonome (la ligne classique)")
        add("backend.sim.summary",  "PRATIC moving-block CBTC, simulated (no hardware)",
                                    "CBTC à canton mobile PRATIC, simulé (sans matériel)")
        add("backend.hw.summary",   "PRATIC real network via telemetry transport (GoA4 supervision)",
                                    "Réseau PRATIC réel via transport de télémesure (supervision GoA4)")
        add("backend.transport",    "Telemetry transport: %@",             "Transport de télémesure : %@")
        add("backend.hint",         "SET BACKEND VAL | PRATIC_SIM | PRATIC_HW switches (replaces the local fleet)",
                                    "SET BACKEND VAL | PRATIC_SIM | PRATIC_HW bascule (remplace la flotte locale)")
        add("backend.set.usage",    "Usage: SET BACKEND VAL | PRATIC_SIM | PRATIC_HW",
                                    "Usage : SET BACKEND VAL | PRATIC_SIM | PRATIC_HW")
        add("backend.set.bad",      "No such backend: %@ -- SHOW BACKEND lists them.",
                                    "Moteur d'état inconnu : %@ -- SHOW BACKEND les liste.")
        add("backend.set.ok",       "Backend switched to %@ -- local fleet replaced.",
                                    "Moteur d'état basculé sur %@ -- flotte locale remplacée.")
        add("backend.set.noworld",  "Backend manager not attached yet.",
                                    "Gestionnaire de moteurs d'état non attaché.")
        add("pratic.title",         "PRATIC NETWORK -- moving-block CBTC picture",
                                    "RÉSEAU PRATIC -- image CBTC à canton mobile")
        add("pratic.notactive",     "No PRATIC backend active -- SET BACKEND PRATIC_SIM or PRATIC_HW first.",
                                    "Aucun moteur PRATIC actif -- SET BACKEND PRATIC_SIM ou PRATIC_HW d'abord.")
        add("pratic.trains.header", "Train   Position   Seg     Speed/Cmd       MA      Link      Confidence    ±Unc",
                                    "Rame    Position   Seg     Vitesse/Cons    AM      Liaison   Confiance     ±Inc")
        add("pratic.trains.none",   "no trains reported yet",              "aucune rame signalée pour l'instant")
        add("pratic.wayside.header","Wayside sensor stations:",            "Stations de détection au sol :")
        add("pratic.wayside.ok",    "OK",                                  "OK")
        add("pratic.wayside.fault", "FAULT",                               "DÉFAUT")
        add("pratic.wayside.seen",  "last detection %d s ago",             "dernière détection il y a %d s")
        add("pratic.wayside.never", "no detection yet",                    "aucune détection pour l'instant")
        add("pratic.turnouts.header","Turnouts:",                          "Aiguillages :")
        add("pratic.turnout.normal","NORMAL",                              "DIRECTE")
        add("pratic.turnout.reverse","REVERSE",                            "DÉVIÉE")
        add("pratic.turnout.locked","LOCKED",                              "VERROUILLÉ")
        add("pratic.balises",       "%d balises (canton-entry reference points)",
                                    "%d balises (points de référence en entrée de canton)")
        add("pratic.hint",          "SET PRATIC /MA= /TARGET= /RELOCALIZE= /TURNOUT= /INJECT= -- see HELP SET PRATIC",
                                    "SET PRATIC /MA= /TARGET= /RELOCALIZE= /TURNOUT= /INJECT= -- voir HELP SET PRATIC")
        add("pratic.link.ok",       "OK",                                  "OK")
        add("pratic.link.degraded", "DEGRADED",                            "DÉGRADÉE")
        add("pratic.link.lost",     "LOST",                                "PERDUE")
        add("pratic.conf.localized","LOCALIZED",                           "LOCALISÉE")
        add("pratic.conf.uncertain","UNCERTAIN",                           "INCERTAINE")
        add("pratic.conf.delocalized","DELOCALIZED",                       "DÉLOCALISÉE")
        add("pratic.set.notrain",   "No such PRATIC train: %@",            "Rame PRATIC inconnue : %@")
        add("pratic.set.ma.ok",     "Movement authority for %@ restricted to %.0f m.",
                                    "Autorisation de mouvement de %@ restreinte à %.0f m.")
        add("pratic.set.ma.off",    "Manual movement-authority restriction on %@ lifted.",
                                    "Restriction manuelle d'autorisation sur %@ levée.")
        add("pratic.set.ma.usage",  "Usage: /MA=(train,limit-m) or /MA=(train,OFF)",
                                    "Usage : /MA=(rame,limite-m) ou /MA=(rame,OFF)")
        add("pratic.set.target.ok", "Target speed for %@ set to %.1f m/s.",
                                    "Vitesse cible de %@ réglée à %.1f m/s.")
        add("pratic.set.target.usage","Usage: /TARGET=(train,m/s)",        "Usage : /TARGET=(rame,m/s)")
        add("pratic.set.reloc.ok",  "Re-localization of %@ commanded against the balise.",
                                    "Re-référencement de %@ commandé sur la balise.")
        add("pratic.set.reloc.usage","Usage: /RELOCALIZE=train or /RELOCALIZE=(train,balise)",
                                    "Usage : /RELOCALIZE=rame ou /RELOCALIZE=(rame,balise)")
        add("pratic.set.turnout.normal","Turnout %d thrown to NORMAL.",    "Aiguillage %d en position DIRECTE.")
        add("pratic.set.turnout.reverse","Turnout %d thrown to REVERSE.",  "Aiguillage %d en position DÉVIÉE.")
        add("pratic.set.turnout.bad","Turnout %d unknown or locked.",      "Aiguillage %d inconnu ou verrouillé.")
        add("pratic.set.turnout.usage","Usage: /TURNOUT=(id,NORMAL|REVERSE)",
                                    "Usage : /TURNOUT=(id,DIRECTE|DÉVIÉE)")
        add("pratic.set.inject.ok", "Failure injected.",                   "Défaillance injectée.")
        add("pratic.set.restore.ok","Injected failure cleared.",           "Défaillance injectée levée.")
        add("pratic.set.inject.usage","Usage: /INJECT=COMMS:train or /INJECT=SENSOR:station",
                                    "Usage : /INJECT=COMMS:rame ou /INJECT=SENSOR:station")
        add("pratic.set.inject.unsup","Injection applies to the simulated backend only.",
                                    "L'injection ne s'applique qu'au moteur simulé.")
        add("pratic.set.transport.ok","Transport configured.",             "Transport configuré.")
        add("pratic.set.transport.bad","Transport unavailable on this backend (or unknown kind).",
                                    "Transport indisponible sur ce moteur (ou type inconnu).")
        add("pratic.set.connect",   "Transport connecting ...",            "Connexion du transport ...")
        add("pratic.set.disconnect","Transport disconnected.",             "Transport déconnecté.")
        add("pratic.set.missqual",  "Missing qualifier -- see HELP SET PRATIC.",
                                    "Qualificatif manquant -- voir HELP SET PRATIC.")

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

        add("valcp.rame.title",     "\nTrain %@ status at %@\n\n",         "\nÉtat de la rame %@ à %@\n\n")
        add("valcp.rame.position",  "  Position:        ",                 "  Position :        ")
        add("valcp.rame.speed",     "  Speed:           ",                 "  Vitesse :         ")
        add("valcp.rame.consigne",  "setpoint",                            "consigne")
        add("valcp.rame.ma",        "  Movement auth.:  ",                 "  Autor. mouvement: ")
        add("valcp.rame.direction", "  Direction:       ",                 "  Sens :            ")
        add("valcp.rame.status",    "  Status:          ",                 "  État :            ")
        add("valcp.rame.mode",      "  Mode:            ",                 "  Mode :            ")
        add("valcp.rame.doors",     "  Doors:           ",                 "  Portes :          ")
        add("valcp.rame.owner",     "  Owner:           ",                 "  Pilotage :        ")
        add("valcp.owner.local",    "THIS NODE",                           "CE NŒUD")
        add("valcp.owner.remote",   "REMOTE NODE",                         "NŒUD DISTANT")
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
        add("valcp.status.emergency","EMERGENCY (EB)",                     "URGENCE (FU)")
        add("valcp.status.docked",  "AT PLATFORM",                         "À QUAI")
        add("valcp.mode.auto",      "AUTOMATIC OPERATION (ATO)",           "CONDUITE AUTOMATIQUE (CAI)")
        add("valcp.mode.manual",    "MANUAL DRIVING (MAN)",                "CONDUITE MANUELLE (CML)")
        add("valcp.door.open",      "OPEN",                                "OUVERTES")
        add("valcp.door.closed",    "CLOSED AND LOCKED",                   "FERMÉES ET VERROUILLÉES")

        add("valcp.fleet.title",    "Fleet status at %@",                  "État du parc à %@")
        add("valcp.fleet.header",   "    Train O Position   Block       Speed        MA  Mode  Status  Drs   Pax\n",
                                    "    Rame  P Position   Canton    Vitesse        AM  Mode  État    Prt   Voy\n")
        add("valcp.fleet.sep",      "    ----- - --------  --------   ------   -------  ----  ------  ---  ----\n",
                                    "    ----- - --------  --------   ------   -------  ----  ------  ---  ----\n")
        add("valcp.fleet.none",     "    (no trains in service)\n",        "    (aucune rame en service)\n")
        add("valcp.fleet.mode.auto","ATO ",                                "CAI ")
        add("valcp.fleet.mode.manual","MAN ",                              "CML ")
        add("valcp.fleet.status.stopped","STOP  ",                         "ARRÊT ")
        add("valcp.fleet.status.moving","RUN   ",                          "MARCHE")
        add("valcp.fleet.status.emergency","EB    ",                       "FU    ")
        add("valcp.fleet.status.docked","DWELL ",                          "À QUAI")
        add("valcp.fleet.doors.open","OPN",                                "OUV")
        add("valcp.fleet.doors.closed","CLS",                              "FER")

        add("valcp.ligne.title",    "\nLine 1 operations at %@\n\n",       "\nExploitation ligne 1 à %@\n\n")
        add("valcp.ligne.mode",     "  Mode:            ",                 "  Mode :            ")
        add("valcp.ligne.mode.stopped","SERVICE STOPPED",                  "SERVICE ARRÊTÉ")
        add("valcp.ligne.mode.normal","NORMAL -- full automatic operation (ATO)",
                                    "NORMAL -- conduite automatique intégrale (CAI)")
        add("valcp.ligne.mode.sp",  "TEMPORARY SERVICE (SP)",              "SERVICE PROVISOIRE")
        add("valcp.ligne.mode.emergency","GENERAL EMERGENCY STOP",         "ARRÊT D'URGENCE GÉNÉRAL")
        add("valcp.ligne.spdetail", "  Temp service:    %@ <-> %@  (headway %d s)",
                                    "  Section SP :      %@ <-> %@  (intervalle %d s)")
        add("valcp.ligne.geometry", "  Track:           %d cantons, %d m loop",
                                    "  Voie :            %d cantons, boucle de %d m")
        add("valcp.ligne.rames",    "  Local trains:    %d in service (max %d)\n",
                                    "  Rames locales :   %d en service (max %d)\n")
        add("valcp.ligne.remote",   "  Remote trains:   %d\n",             "  Rames distantes : %d\n")
        add("valcp.ligne.modenormal","%VALCP-S-NORMAL, line returned to normal operation\n",
                                    "%VALCP-S-NORMAL, ligne rendue à l'exploitation normale\n")
        add("valcp.ligne.serviceon","%VALCP-S-SERVICE, line service started\n",
                                    "%VALCP-S-SERVICE, service de ligne démarré\n")
        add("valcp.ligne.serviceoff","%VALCP-S-SERVICE, line service stopped -- trains braking to a stand\n",
                                    "%VALCP-S-SERVICE, service arrêté -- rames en cours d'immobilisation\n")
        add("valcp.ligne.emeron",   "%VALCP-S-EMERGENCY, general emergency stop -- emergency brake on every train\n",
                                    "%VALCP-S-EMERGENCY, arrêt d'urgence général -- FU sur toutes les rames\n")
        add("valcp.ligne.emeroff",  "%VALCP-S-EMERGENCY, emergency stop released\n",
                                    "%VALCP-S-EMERGENCY, arrêt d'urgence levé\n")
        add("valcp.ligne.spon",     "%%VALCP-S-SP, temporary service engaged %@ <-> %@ (headway %d s)\n",
                                    "%%VALCP-S-SP, service provisoire engagé %@ <-> %@ (intervalle %d s)\n")
        add("valcp.ligne.spoff",    "%VALCP-S-SP, temporary service cleared -- full line restored\n",
                                    "%VALCP-S-SP, service provisoire levé -- ligne complète rétablie\n")
        add("valcp.ligne.spusage",  "%VALCP-W-IVSP, usage: SET LIGNE /SP=(from,to[,interval-s]) with station ids 1..6\n",
                                    "%VALCP-W-IVSP, usage : SET LIGNE /SP=(de,à[,intervalle-s]) avec des ids de station 1..6\n")
        add("valcp.ligne.missqual", "%VALCP-W-MISSQUAL, expected /SERVICE=, /EMERGENCY=, /SP= or /NORMAL\n",
                                    "%VALCP-W-MISSQUAL, attendu /SERVICE=, /EMERGENCY=, /SP= ou /NORMAL\n")

        add("valcp.stations.title", "Stations of line 1 at %@",            "Stations de la ligne 1 à %@")
        add("valcp.stations.header","     #  Station                 Position    Next train\n",
                                    "     #  Station                 Position    Prochaine rame\n")
        add("valcp.stations.sep",   "    --  ----------------------  ---------   --------------------\n",
                                    "    --  ----------------------  ---------   --------------------\n")
        add("valcp.stations.approach","train %@ at %.0f m",               "rame %@ à %.0f m")
        add("valcp.stations.barred","(barred by temp service)",            "(neutralisée par le SP)")
        add("valcp.stations.none",  "(no trains)",                         "(aucune rame)")

        add("valcp.pax.title",      "\nPassenger load at %@\n\n",          "\nCharge voyageurs à %@\n\n")
        add("valcp.pax.header",     "    Train  Pax   Capacity   Load     State\n",
                                    "    Rame   Voy   Capacité   Charge   État\n")
        add("valcp.pax.sep",        "    ----   ---   --------   ------   -----\n",
                                    "    ----   ---   --------   ------   -----\n")
        add("valcp.pax.none",       "    (no trains in service)\n",        "    (aucune rame en service)\n")
        add("valcp.pax.state.crush","CRUSH LOAD",                          "SURCHARGE")
        add("valcp.pax.state.full", "FULL",                                "COMPLET")
        add("valcp.pax.state.empty","EMPTY",                               "VIDE")
        add("valcp.pax.state.nominal","NOMINAL",                           "NOMINAL")

        add("valcp.rame.missrame",  "%SET-W-MISSPARM, usage: SET RAME <label> /qualifier\n",
                                    "%SET-W-MISSPARM, usage : SET RAME <label> /qualificatif\n")
        add("valcp.rame.nosuch",    "%%SET-W-NOSUCHRAME, no such train \\%@\\\n",
                                    "%%SET-W-NOSUCHRAME, rame inconnue \\%@\\\n")
        add("valcp.rame.man.set",   "%%SET-S-MODE, train %@ now in manual driving (MAN)\n",
                                    "%%SET-S-MODE, rame %@ passée en conduite manuelle (CML)\n")
        add("valcp.rame.man.nochg", "%%SET-I-NOCHG, train %@ already in manual driving\n",
                                    "%%SET-I-NOCHG, rame %@ déjà en conduite manuelle\n")
        add("valcp.rame.auto.set",  "%%SET-S-MODE, train %@ returned to automatic operation (ATO)\n",
                                    "%%SET-S-MODE, rame %@ rendue au pilotage automatique (CAI)\n")
        add("valcp.rame.auto.nochg","%%SET-I-NOCHG, train %@ already in automatic operation\n",
                                    "%%SET-I-NOCHG, rame %@ déjà en pilotage automatique\n")
        add("valcp.rame.speed.set", "%%SET-S-SPEED, train %@ manual speed setpoint %.1f m/s\n",
                                    "%%SET-S-SPEED, consigne manuelle de la rame %@ : %.1f m/s\n")
        add("valcp.rame.speed.notmanual","%%SET-W-NOTMANUAL, train %@ is in automatic operation -- SET RAME /MANUAL first\n",
                                    "%%SET-W-NOTMANUAL, la rame %@ est en pilotage automatique -- SET RAME /MANUAL d'abord\n")
        add("valcp.rame.fu.on",     "%%SET-S-FU, emergency brake commanded on train %@\n",
                                    "%%SET-S-FU, FU commandé sur la rame %@\n")
        add("valcp.rame.fu.off",    "%%SET-S-FU, emergency brake released on train %@\n",
                                    "%%SET-S-FU, FU relâché sur la rame %@\n")
        add("valcp.rame.forwarded", "%%SET-S-FORWARD, request sent to train %@'s owner node\n",
                                    "%%SET-S-FORWARD, demande transmise au nœud pilote de la rame %@\n")
        add("valcp.rame.nolink",    "%%SET-W-NOLINK, train %@ is remote and its owner is unreachable\n",
                                    "%%SET-W-NOLINK, la rame %@ est distante et son nœud pilote est injoignable\n")
        add("valcp.rame.owneronly", "%%SET-W-OWNERONLY, faults and tires on train %@ are managed by its owner node\n",
                                    "%%SET-W-OWNERONLY, les défauts et pneus de la rame %@ sont gérés par son nœud pilote\n")
        add("valcp.rame.fault.portes","%%SET-S-FAULT, train %@ door fault %@\n",
                                    "%%SET-S-FAULT, défaut portes rame %@ %@\n")
        add("valcp.rame.fault.traction","%%SET-S-FAULT, train %@ traction fault %@\n",
                                    "%%SET-S-FAULT, défaut traction rame %@ %@\n")
        add("valcp.rame.fault.frein","%%SET-S-FAULT, train %@ brake fault %@\n",
                                    "%%SET-S-FAULT, défaut frein rame %@ %@\n")
        add("valcp.rame.fault.ctc", "%%SET-S-FAULT, train %@ CTC radio fault %@\n",
                                    "%%SET-S-FAULT, défaut radio CTC rame %@ %@\n")
        add("valcp.rame.fault.patinage","%%SET-S-FAULT, train %@ wheel slip %@\n",
                                    "%%SET-S-FAULT, patinage rame %@ %@\n")
        add("valcp.rame.fault.enrayage","%%SET-S-FAULT, train %@ wheel slide %@\n",
                                    "%%SET-S-FAULT, enrayage rame %@ %@\n")
        add("valcp.rame.fault.set", "latched",                             "activé")
        add("valcp.rame.fault.cleared","cleared",                          "levé")
        add("valcp.rame.pneu.range","%%SET-W-IVPNEU, tire index must be 1..%d\n",
                                    "%%SET-W-IVPNEU, l'index du pneu doit être 1..%d\n")
        add("valcp.rame.pneu.cycled","%%SET-S-PNEU, train %@ tire %d now %@\n",
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
        add("diag.col.rame",        "Train  Test",                         "Rame  Test")
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
        add("diag.step.frein.rame", "Train %@   brake chain",              "Rame %@   chaîne de freinage")
        add("diag.step.frein.fw",   "Brake controller firmware",           "Micrologiciel du contrôleur de frein")
        add("diag.step.portes.cycle","Train %@   door cycle",              "Rame %@   cycle des portes")
        add("diag.step.portes.interlock","Train %@   traction interlock",  "Rame %@   asservissement traction")
        add("diag.step.pneu.read",  "Train %@   pressure sweep",           "Rame %@   relevé des pressions")
        add("diag.step.pneu.span",  "Train %@   span vs nominal",          "Rame %@   écart au nominal")
        add("diag.step.pneu.write", "Write calibration records",           "Écriture des enregistrements")
        add("diag.step.quai.station","%@   lamps + display",               "%@   lampes + afficheur")
        add("diag.step.quai.fw",    "Platform display firmware",           "Micrologiciel des afficheurs")
        add("diag.frein.reading.dragging","EB while moving",               "FU en mouvement")
        add("diag.frein.reading.released","released (moving)",             "desserré (en mvt)")
        add("diag.frein.reading.holding","%.1f kN holding",                "%.1f kN de retenue")
        add("diag.portes.reading.movingSuffix"," (in motion)",             " (en mouvement)")
        add("diag.portes.reading.locked","locked",                         "verrouillé")
        add("diag.portes.reading.violated","INTERLOCK OPEN",               "CHAÎNE OUVERTE")
        add("diag.pneu.reading.records","%d records",                      "%d entrées")
        add("diag.quai.reading.lit","lamps + display lit",                 "lampes + afficheur allumés")
        add("diag.reading.noRame",  "(no train)",                          "(aucune rame)")
        add("diag.reading.noWorld", "(no world)",                          "(aucun monde)")

        return t
    }

    static func lookup(_ key: String, lang: Lang) -> String {
        if let row = table[key], let value = row[lang] { return value }
        if let row = table[key], let fallback = row[.en] { return fallback }
        return key
    }
}
