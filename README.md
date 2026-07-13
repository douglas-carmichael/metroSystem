# MetroSystem

A native macOS / SwiftUI **CBTC metro simulator** with a retro VT320 /
OpenVMS aesthetic, built on the
[elevatorSystem](https://github.com/lapatatedouce59/elevatorSystem)
retro harness. One app, four windows, bilingual EN / FR throughout, with a
headless cluster daemon and a Modbus TCP interface for external tooling.

English | Français
:---:|:---:
![PCC Dispatcher, English](docs/pcc-dispatcher-en.png) | ![PCC Dispatcher, French](docs/pcc-dispatcher-fr.png)

## Windows

- **PCC Dispatcher** — the poste de commande centralisé: line service,
  arrêt d'urgence général, service-provisoire configurator, the ISA-18.2
  SCADA annunciator (ack / shelve / clear discipline), and a control panel
  per train (doors, ATO/MAN mode, manual-speed desk, emergency brake, fault
  injection — doors, traction, brake, CTC radio, wheel slip/slide — and the
  eight VAL tires).
- **Line Synoptic 3D** — a SceneKit view of the circular VAL line: 10 blocks
  (cantons), 6 Lille stations, colour-coded trains, service-provisoire
  sections dimmed, camera orbit and a follow-train chase mode.
- **DCL Terminal** — a full OpenVMS DCL shell emulation (the elevatorSystem
  engine) with the **LPD VAL-CTRL** layered product: `VALCP SHOW/SET RAME`,
  `SET LIGNE /SP=(1,3,60)`, `MONITOR DYNAMICS`, `MONITOR CLUSTER`, `SHOW
  MODBUS`, `DIAGNOSE`, EDT, MAIL, command procedures, and an interactive
  VMS HELP library. Also reachable over `telnet localhost 2323`.
- **Train Dynamics** — a commissioning-scope window plotting each train's
  speed against the asservissement setpoint.
- **Train Detail** — a dedicated per-rame TCMS synoptic (double-click a
  train card's DETAIL button): a speed dial with the setpoint needle,
  MA / passenger / traction meters, the diagnostic sections, the ATP
  chaîne-de-sécurité, and the eight VAL tires as two bogies of pressure
  gauges.

See [docs/](docs/README.md) for the detail-window, 3D synoptic and DCL
screenshots.

## Simulation

A 60 Hz PLC-scan `MetroWorld` where
each train runs the asservissement speed regulation (braking curve +
proportional control + emergency-brake envelope + tire-adhesion / patinage
/ enrayage model) against a movement authority recomputed every scan by the
wayside zone controller, with station dwell, passenger exchange, and
service-provisoire shuttle logic.

## Multi-node networking

Every train carries an `ownerPeerId`. The app discovers other PCC nodes on
the LAN over Bonjour (`_metrosys._tcp`) — another Mac running the app, or
headless **ClusterDaemon** nodes — and shows their trains as **REMOTE** on
the same circular line. Each node's zone controller protects its own trains
against the whole shared picture; exploitation commands (doors, emergency
brake, driving mode, manual speed) forward to the owning node.

```bash
cd ClusterDaemon && swift run metro-clusterd --nodes 2 --trains 2
```

See [ClusterDaemon/README.md](ClusterDaemon/README.md) for the daemon and
the app↔daemon wire-mirror pairs.

## Backends — VAL, CBTC and PRATIC

The app is also the PCC front end for **PRATIC** (Projet de Réseau
Automatique de Trains Inter-Connectés), a model-scale CBTC autopilot.
`SET BACKEND` in the terminal switches the engine behind the whole UI:

- **VAL** — the fixed-block simulation built on the real system's
  architecture (default): wayside SF/PP speed programs physically
  "encoded" in the guideway, block occupancy protection, on-board
  AVP/AVO racks, B1/B2/B3 beacon station stops, the image-série
  traction chain, and full console-A22 manual driving (KG, reverser,
  traction/brake lever, KACOP dead-man). Sourced from the UMTA/DOT VAL
  assessment and the VAL 206 thesis in the repo root; details in
  [docs/val-backend.md](docs/val-backend.md).
- **CBTC_SIM** — the moving-block scan that originally drove the app,
  kept as its own engine: continuous movement authority behind the
  leader, the counterpoint to VAL's 1983 fixed blocks.
- **PRATIC_SIM** — a simulated moving-block CBTC network: continuous
  position/heartbeat reporting, balise fixes, link status
  (OK/DEGRADED/LOST), position confidence
  (LOCALIZED/UNCERTAIN/DELOCALIZED), wayside sensor stations, turnouts,
  and injectable failures (`SET PRATIC /INJECT=COMMS:201`).
  Delocalization recovery is the explicit
  `SET PRATIC /RELOCALIZE=(201,4)` re-reference the real system needs.
- **PRATIC_HW** — the real network, supervised over a pluggable
  telemetry transport (newline-JSON TCP works today; a serial/RF stub
  marks the integration point). The trains drive themselves (GoA4);
  the front end issues authorities and commands and treats staleness
  as a first-class state.

`SHOW PRATIC` is the live moving-block picture; details in
[docs/pratic-backends.md](docs/pratic-backends.md).

## Modbus TCP

A Modbus TCP slave on **`localhost:5020`** exposes live train telemetry,
the chaîne-de-sécurité contacts, and control coils/registers so `mbpoll`,
`pymodbus`, OpenPLC or Node-RED can read and drive trains. Press **M** in
the PCC Dispatcher, or `SHOW MODBUS` in the terminal, for the live map.
Full layout: [docs/modbus-register-map.md](docs/modbus-register-map.md).

## Model-track hardware (plugin drivers)

The simulator can drive **physical model trains**: a hardware bridge
mirrors every locally-owned rame onto the layout through a pluggable
driver — a [DCC-EX](https://dcc-ex.com) command station over TCP, a
generic newline-JSON TCP gateway (write a tiny external process in any
language and it becomes the driver), or a console dry-run for rehearsal.
Occupancy detectors can feed back and resync the simulated positions.
Everything is operated from the DCL terminal:

```
$ SET HARDWARE /DRIVER=DCCEX /HOST=192.168.1.50 /UNIT=(101,3)
$ SET HARDWARE /CONNECT /POWER=ON /ENABLE
```

The output is disabled at every launch, stop-all is sent on disable or
disconnect, and an FU becomes the protocol's emergency stop. Details and
the driver-writing guide: [docs/hardware-drivers.md](docs/hardware-drivers.md).
This drives hobby model railways only — it is still a simulator, not a
safety controller.

## Build & run

The `.xcodeproj` is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml` and is `.gitignore`'d:

```bash
brew install xcodegen             # one-time prerequisite
xcodegen generate                 # regenerate MetroSystem.xcodeproj
open MetroSystem.xcodeproj        # run the MetroSystem scheme

# Or build headless:
xcodebuild -project MetroSystem.xcodeproj -scheme MetroSystem \
           -configuration Debug -destination 'platform=macOS' build
```

Target is macOS 15.0. Three trains seed at launch; press **START SERVICE**
(or type `START LINE` in the DCL terminal) to begin operation. First launch
triggers the macOS local-network privacy prompt — accept it for peer
discovery.

## Ten-second tour (DCL)

```
$ FLEET                              ! fleet table (or FLOTTE)
$ RAME 101                           ! per-train status sheet (or TRAIN 101)
$ VALCP SET RAME 101 /MANUAL         ! manual driving (console A22)
$ VALCP SET RAME 101 /KG=ON          ! master power
$ VALCP SET RAME 101 /REVERSER=AV    ! point the reverser
$ VALCP SET RAME 101 /LEVER=50       ! 50% traction (KACOP every 14 s!)
$ VALCP SET RAME 101 /SPEED=8        ! CML governor ceiling
$ STOP RAME 101                      ! emergency brake
$ START RAME 101                     ! release
$ VALCP SET LIGNE /SP=(1,3,60)       ! shuttle CHU <-> Gare, 60 s headway
$ VALCP SET LIGNE /NORMAL
$ MONITOR DYNAMICS                   ! live speed-regulation table (Ctrl/Y exits)
$ MONITOR CLUSTER                    ! per-node CPU/mem/IO across peers
$ SHOW MODBUS                        ! Modbus register map
$ SELFTEST                           ! drive every documented verb
$ HELP METRO                         ! worked example; HELP VALCP for reference
```

## Testing

There is no XCTest target. The app's harness is the `SELFTEST` DCL command
(runs in the DCL window or over telnet); the daemon's is
`swift run metro-clusterd --selftest` (a wire-codec round-trip that locks
compatibility with the app). Both run in CI (`.github/workflows/`).

## Language discipline

The UI is strictly bilingual: EN mode shows no French, FR mode shows no
English, with three deliberate in-universe exceptions — the OpenVMS
*system* banner/messages stay English in both modes (real VMS was
English-only); SCADA source/point tags and the OpenVMS DCL verbs are
language-neutral identifiers; and proper nouns (VAL, PCC, the Lille station
names, the LPD vendor name) are never translated.

The **DCL metro command vocabulary follows the interface language** too:
the English short-form aliases (`TRAIN`, `FLEET`, `LINE`, `STATIONS`,
`EMERGENCY`, `RESUME`) resolve only in English mode and the French ones
(`RAME`, `FLOTTE`, `LIGNE`, `GARES`, `URGENCE`, `REPRISE`, `AIDE`) only in
French mode; likewise the `LINE`/`LIGNE` object keyword and the `SET RAME`
fault qualifiers (`/BRAKE` vs `/FREIN`, `/SLIP` vs `/PATINAGE`, …). The
OpenVMS verbs (`SHOW`, `SET`, `MONITOR`, …) and the VALCP product nouns
(`RAME`, `RAMES`, `STATIONS`, `PAX`) are the installed CLI vocabulary and
work in either mode.

## Credits

- **CBTC metro simulation** — Douglas Carmichael.
- **Retro UI, OpenVMS DCL shell and simulation harness** — adapted from
  [elevatorSystem](https://github.com/lapatatedouce59/elevatorSystem)
  (Amaury Crocquefer; macOS/SwiftUI port Douglas Carmichael).
- VT323 typeface © Peter Hull, SIL Open Font License (`Resources/Fonts/OFL.txt`).

This is a dispatch + visualisation simulator, **not** a safety controller;
nothing here is approved to move a train.
