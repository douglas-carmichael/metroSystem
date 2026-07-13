# The VAL backend — the real architecture, in miniature

The `VAL` backend (the default; `SET BACKEND VAL`) is built on the
architecture of the real VAL system as documented in three primary
sources kept in `docs/sources/` (provenance and redistribution notes in
[docs/sources/README.md](sources/README.md)):

- **`VAL_Assessment.pdf`** — G. Anagnostopoulos, *Interim Assessment of
  the VAL Automated Guideway Transit System*, US DOT/UMTA report
  UMTA-MA-06-0069-81-3, November 1981. §3.5 (Command and Control) is the
  authority for the AVP/AVO/AVS split, the fixed blocks, the SF/PP speed
  programs, the WCCU/DOCU/DTU equipment, and the demonstration-test
  behaviour in §4 (trip distances, braking rates, stopping accuracy,
  dwell and headway).
- **`These_Verhille.pdf`** — J.-N. Verhille, *Représentation énergétique
  macroscopique du métro VAL 206 et structures de commande déduites par
  inversion*, thesis, 2007 (HAL). The authority for the traction chain
  (input filter → GTO choppers → series-wired DC motors → differential →
  wheel reducers → tire/track contact), the "image série" control, the
  comfort limits (γmax 1.3 m/s², Jmax 0.65 m/s³), the μ(λ) adhesion law
  and the anti-patinage strategy.
- **`SiemensTransportationSystemsInc_03152007.pdf`** — City of Chicago
  sole-source package for the O'Hare ATS (VAL 256), STS 2007. The
  authority for the equipment nomenclature: the OBCU racks (DRIVE,
  SAFETY, TMTC, POWER, TRACTION SAFETY, EXTENSION and their boards —
  REG-A, ASST-A, SSV, SFU, CPFS-A, CPPP-A, APEP…), the WCU and its
  AFSC/PP program board, the DOCU, and the manual control console
  **A22**.

The moving-block scan that previously drove the app is preserved
unchanged as the **`CBTC_SIM`** backend (`Backends/CBTCSimBackend.swift`)
— the modern-CBTC counterpoint to VAL's 1983 fixed blocks.

## File map

| File | Real-world counterpart |
| --- | --- |
| `Backends/VALArchitecture.swift` | The guideway database (blocks, encoded speed codes, station stop points, B1/B2/B3 beacons), the speed-program and FU-cause vocabularies, console A22 state, per-rame OBCU state. |
| `Backends/VALWayside.swift` | The PA fixe: vehicle detection (check-in/check-out block occupancy, tail included), WCU speed-program selection (SF normal f1 / PP perturbed f2 / SF withdrawn), DOCU dwell + departure authorization + SP turnback and headway pacing. |
| `Backends/VALOnboard.swift` | The PA embarqué: SAFETY rack (AVP trips holding off the FU) and DRIVE rack (jerk-limited AVO regulation, beacon-staged precision stop), or console-A22 manual driving with KACOP vigilance. |
| `Backends/VALTraction.swift` | The HR car: image-série chopper/motor capability curve, regen/friction brake blending, per-bogie μ(λ) adhesion with anti-patinage, Davis resistance, electrical telemetry. |
| `Backends/VALSimBackend.swift` | The 60 Hz orchestrator: wayside → OBCU → traction per locally-owned rame, dead reckoning for peer rames, aux telemetry, SCADA alarm samplers. |

## The scan, step by step

1. **Vehicle detection** (`VALWayside.detectOccupancy`). Every known rame
   — local or peer-owned — registers the block under its antenna and the
   block containing its 26 m tail. This is the PD/ND picture the real
   WCCUs assemble from the downlink loops and ultrasonic detectors
   (DOT §3.5.2.2).

2. **Program selection** (`VALWayside.telegram`). Per locally-owned rame:
   - Downstream block free → **SF normal** (f1): proceed at the block's
     encoded code (15 m/s plain blocks, 8 m/s station blocks, tapered
     onto a lower next-block code before the boundary).
   - Downstream block occupied → **PP perturbed** (f2): a decreasing
     speed profile anchored `d` = 8 m before the occupied boundary
     (DOT §3.5.2.3, §4.5.1).
   - Station blocks carry **SFa** (arrival, onto the platform stop
     point) and **SFb** (departure). The DOCU withholds SFb while doors
     are open, the exchange runs, the downstream block is occupied, or
     the service-provisoire headway holds the rame; under SP it issues
     the terminus **turnback** order (DOT §3.5.3.2, §4.5.4).
   - Line emergency, or a rame stranded outside the SP section →
     **SF withdrawn**: fail-safe by absence, on-board FU (DOT §3.5.2.13).
   - Line service off → a Central **zero-speed restriction** (a
     restrictive speed command, not an FU).

3. **SAFETY rack** (`VALOnboard.updateSafetyRack`). Emergency braking is
   held off only while every check proves positive:
   - **Survitesse**: the AVO regulates to a 0.30 s crossover interval,
     the AVP trips below 0.27 s — program speed × 10/9 (DOT §3.5.2.6).
   - **PP overrun**: passing the perturbed stopping point while rolling.
   - **Block penetration**: instant in automatic; 10 m in manual (the
     §4.5.6 demonstration).
   - **Rollback** beyond 5 m (§4.5.8); direction per the reverser in
     manual.
   - **Door train-line** broken while moving; latched door/brake faults;
     the PCC watchdog interlock; loss of SF (injected CTC fault included).
   - **KACOP vigilance** (manual only): warning at 14 s without an
     acknowledgment, FU at 20 s.
   Condition-driven causes release with their condition (clear the fault
   chip and the rame resumes); event trips latch until the rame stands
   and the operator releases the FU — `fuRelease` is honoured at a stand
   only. The cause is published as `Train.ebCause` (mnemonics:
   SURVITESSE, PP-LIMIT, CANTON, ROLLBACK, KACOP, SF, …).

4. **DRIVE rack** (`VALOnboard.automaticDrive`). The consigne chases the
   program speed under the comfort envelope (1.3 m/s², 0.65 m/s³ — the
   Rc3/Rc3⁻¹/Rc2 cascade of the thesis §2.1.1); an analog proportional
   loop with trajectory feed-forward produces the effort request.
   Station stops stage through the **B1/B2/B3 beacons** (100 m / 16 m /
   8 m before the stop marker): deceleration on the SFa profile, then
   the berthing law — a softer 0.9 m/s² curve aimed just short of the
   marker so the loop's tracking lag lands the rame inside the berth
   window (DOT §3.5.3.1's closed-loop stop). Two regulation rules keep
   the driven speed inside the vital ceiling: the profile *anticipates*
   code-drop tapers by the jerk-transition distance (the real track's
   crossover spacing embeds the transition), and motoring is inhibited
   whenever the consigne would ride above a descending program — a rame
   stopped under a taper still departs by accelerating below the
   profile. The AVP ceiling adds the documented one-crossover detection
   allowance on top of the 10 % ratio. After an event trip brings the
   rame to a stand and its cause has cleared (the obstructing block
   released, the overspeed gone), a 5 s hold-off matures and Central
   reinitiates the rame automatically — vehicles in the DOT
   demonstrations restart exactly this way, and stay held while the
   cause persists. Operator FU stays until released (at a stand);
   a KACOP trip releases on a dead-man acknowledgment at a stand.

5. **Console A22** (`VALOnboard.manualDrive`) — manual mode, semantics
   per the VALPupitreSim project:
   - **KG** master power; **reverser** AV/0/AR (sense changes at a stand
     only); **T/F lever** −1…+1 (full service brake … full traction).
   - Traction inhibited by KG off, reverser neutral, doors open, FU
     latched, or the **CML ceiling** (the `/SPEED` setpoint, default
     20 m/s); **service braking is always available**.
   - **KACOP** dead-man: rising-edge acknowledgment, 14 s warning
     (SCADA point VIGILANCE + pupitre voyant), 20 s auto-FU. Bypassed
     entirely in automatic — the point of a driverless metro.
   - The wayside AVP stays active: manual penetration of an occupied
     block still trips the FU after 10 m.

6. **Traction chain** (`VALTractionChain.integrate`). The effort request
   becomes force through the image-série capability: full field
   (iex = 0.059·ii) until the armature loop voltage hits the 750 V
   filter ceiling, then weakened field (0.034·ii) — the three phases of
   thesis Fig. 1.32 emerge from the voltage constraint. Braking blends
   regenerative (above ~5 km/h, receptivity-limited, it lifts the line
   voltage) with the PEPD friction disks; the FU is spring-applied
   friction only. Per bogie, demanded rim force beyond μ(λ)·N lets the
   wheel speed integrate away from the vehicle — zone 2's falling
   characteristic makes patinage self-reinforcing — and the anti-skid
   function cancels the affected car's effort above an 8 km/h motor-
   speed spread, ramping it back over 3 s (thesis §2.4). Injected
   PATINAGE/ENRAYAGE stand for a wet/icy patch (degraded μ curve); tire
   faults shrink grip and add drag as before. Davis resistance
   `Fr = A + B·v + C·v²` and the passenger-dependent mass (31 t tare +
   70 kg/pax) close the longitudinal dynamics.

## What the surfaces show

- `Train.speedProgram` carries the received program (`SF-N`, `PP`,
  `SFA`, `SFB`, `HOLD`, `ASMD`, `ABS`) — the PCC card, the detail
  window's ATP section, VALCP SHOW RAME, MONITOR DYNAMICS (state
  `PERT`) and Modbus input registers 128..143 render it. It is empty
  under the other backends, which is how the views gate the VAL-specific
  rows.
- `Train.ebCause` carries the FU trip cause while the brake is in.
- The pupitre state (`pupitreKG`, `pupitreReverser`, `pupitreLever`,
  `kacopSecondsSinceAck`, `kacopWarning`) rides the peer wire, so a
  remote rame's cab renders identically everywhere; the pupitre
  *commands* (`pupitreKG/…/kacopAck` TrainCommands) forward to the
  owning node like every exploitation action.
- Operator surfaces: the PCC card's pupitre strip and the detail
  window's CONSOLE A22 section (voyants TRAC/FREIN/PM/URG/KACOP);
  `SET RAME /KG= /REVERSER= /LEVER= /KACOP` in DCL (FR: `/INVERSEUR`,
  `/MANIPULATEUR`); Modbus coils 64..111 and holding registers 32..63.

## Maintenance-training surfaces

- **Bench telemetry** (thesis notation): the actual armature current
  `II`, line current `IL` (signed — negative while regenerating),
  field current `IEX` and chopper duty `MHI` are backed out of the
  force demand each scan and published on the wire
  (`Train.armatureCurrent/lineCurrent/excitationCurrent/
  modulationRatio`). Shown in the detail window's TRACTION section and
  `VALCP SHOW RAME`'s "Traction chain" line; polled over Modbus input
  registers 160..223. The chopper relationship `IL = MHI × II`, the
  image-série ratio change at base speed (0.059 → 0.034) and the FU
  cutting traction power are all directly observable.
- **LRU lookup** (`RUN LRU_LOOKUP`, also on the DIAGNOSE menu): maps
  every locally-owned rame's latched faults and EB cause to the suspect
  board(s) in the STS parts-list nomenclature — the board-swap
  maintenance model of the O'Hare contract. The detail window's ATP
  section shows the same suspect line while an FU is in.
- **Self-paced exercises** `TP1..TP6.COM` seeded in the COM store
  (`@TP1` — bench reading; `@TP2` — EB-trip diagnosis to the board;
  `@TP3` — adhesion/anti-skid; `@TP4` — programmed-stop accuracy
  against the DOT §4.11 figures; `@TP5` — KACOP vigilance discipline;
  `@TP6` — tire-pressure triage). Each sets up its own scenario, prints
  bilingual instructions and the expected observations for self-check,
  and never needs an instructor station or a second node. Because the
  SET RAME qualifiers follow the interface language, the scripts issue
  gated commands in both spellings — one of each pair reports a benign
  qualifier error, which the scripts explain. The detail window's
  TRACTION BENCH strip (II / signed IL / IEX / MHI meters) is the
  visual companion to TP1.

## Deliberate simplifications

- One berth per station, no switches: the loop has no diverging routes,
  so switch interlocking (DOT §3.5.2.9) reduces to the SP barriers.
- The AVP's redundant A/B strings and AND/OR voting are not modelled —
  this is a dispatch simulator, not a safety case.
- Blocks are the ten 100 m cantons of `Sim`; the real Lille blocks vary
  in length with the civil profile.
- The uplink/downlink data links (1.333 s frames, DOT §3.5.4) are
  abstracted into the per-scan telegram; the peer wire plays the role of
  the vehicle data link.

`ClusterDaemon/…/RameSimulator.swift` is the hand-mirrored headless port
of this scan (see `ClusterDaemon/README.md` for what it omits).
