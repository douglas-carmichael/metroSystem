# PRATIC backends

MetroSystem is the PCC / dispatcher front end for **PRATIC** (Projet de
Réseau Automatique de Trains Inter-Connectés) — a model-scale,
CBTC-compliant train autopilot: wayside sensing, onboard odometry and
control, a comms link, and a real traction inverter. The front end is a
reactive view over train / track / authority / alarm state; **which
engine puts that state on screen is the backend**, and there are three:

| Backend      | What it is | Selected with |
|--------------|------------|---------------|
| `VAL`        | The original self-contained VAL simulation (default — unchanged behaviour). | `SET BACKEND VAL` |
| `PRATIC_SIM` | A simulation of the PRATIC moving-block network, with every failure mode injectable. | `SET BACKEND PRATIC_SIM` |
| `PRATIC_HW`  | The real PRATIC network, supervised over a pluggable telemetry transport (with stubs for the physical link). | `SET BACKEND PRATIC_HW` |

Switching backends replaces the locally-owned fleet (each backend seeds
or discovers its own trains); trains owned by peer nodes are untouched.
`SHOW BACKEND` shows what is active.

## How the front end stays one front end

Both PRATIC backends publish the domain picture in a `PraticNetwork`
store **and mirror each train into `MetroWorld`** (same UUID). That
mirror is what makes every existing surface work unmodified:

- The PCC panel, 3D synoptic, dynamics scope, Modbus map and peer wire
  all render/serve PRATIC trains as they do VAL rames.
- The panel's FU / mode / manual-speed controls mutate the mirror; the
  backend reads them back as **operator intents** each scan (the
  hardware backend diffs them and forwards only changes as commands).
- PRATIC-specific state — link status, position confidence, MA age,
  wayside stations, turnouts, balises — surfaces through
  `SHOW PRATIC` / `SET PRATIC` and the SCADA annunciator.

## The CBTC domain (what is modelled)

- **Moving block.** No fixed sections: each train's limit of authority
  is computed from the live picture — the nearest obstacle ahead padded
  by *that obstacle's own position uncertainty* plus the safety margin
  (`Sim.praticSafetyMargin`). A delocalized train casts a wide shadow.
- **Position confidence is a state** — `LOCALIZED / UNCERTAIN /
  DELOCALIZED`, visible in `SHOW PRATIC` everywhere a train appears.
  Odometry uncertainty grows with distance travelled
  (`Sim.praticUncertaintyGrowth`) and collapses to zero on a **balise
  fix** (balise *n* sits at canton *n*'s entry boundary).
- **Link status is a state** — `OK / DEGRADED / LOST` from heartbeat
  age (`Sim.praticLinkDegraded` / `praticLinkLost`). Stale data is
  degraded and flagged, never silently frozen.
- **Delocalization** (silence beyond `Sim.praticDelocalized`, or
  uncertainty beyond `praticDelocThreshold`) collapses the train's
  authority and raises the critical **DELOC** alarm. Recovery is the
  explicit manual action the brief prescribes:
  `SET PRATIC /RELOCALIZE=(train,balise)`.
- **Alarms** are typed SCADA points with ISA-18.2 semantics —
  `DELOC` (critical), `COMMS` (major), `OVERSPEED` (critical),
  `WAYSIDE n / SENSOR` (major), `PRATIC / TRANSPORT` (critical, hardware
  backend) — process-driven: they return to normal when the condition
  clears and are not operator-clearable.

## PRATIC_SIM — the simulated network

A 30 Hz scan (`Sim.praticScanHz`) shaped like `MetroWorld.tick()`:
operator-intent sync → wayside MA pass → per-train onboard pass
(heartbeats, drift, balise fixes, confidence, autopilot regulation to
the braking curve) → wayside detections → alarm sampling → mirror
projection. On link loss the simulated autopilot brakes to a stand (the
real MA-timeout behaviour), so the last-known position the PCC shows
stays honest while the uncertainty region conveys the doubt.

Exercise the failure modes from the terminal:

```
$ SET BACKEND PRATIC_SIM
$ SHOW PRATIC
$ SET PRATIC /INJECT=COMMS:201        ! heartbeats stop
$ SHOW PRATIC                         ! DEGRADED -> LOST -> DELOCALIZED
$ SET PRATIC /RELOCALIZE=(201,4)      ! re-reference against balise 4
$ SET PRATIC /INJECT=SENSOR:3         ! wayside station fault
$ SET PRATIC /MA=(202,350) /TARGET=(202,8)
```

## PRATIC_HW — the real network (with stubs)

The trains are autonomous (GoA4); this backend **supervises**. It owns
exactly what the brief assigns to the front end:

- **Staleness watchdog** — link status from heartbeat age; while silent,
  the uncertainty region grows with what the train could have travelled.
- **Intent diffing** — PCC actions (FU, mode, manual speed, target,
  manual MA restriction) are forwarded once per change.
- **Optimistic echo** — commands update the picture immediately; the
  next telemetry confirms or corrects.

MA computation lives wayside in the real system; the dispatcher can
still impose a restriction (`/MA=…`), which is forwarded.

### The transport seam (`Backends/PraticTransport.swift`)

The physical link may be RF, serial or IR — the backend consumes a
normalized `PraticWireMessage` stream and does not care about the wire:

- **`JSONL`** *(works today)* — newline-delimited JSON over TCP, for a
  gateway process (a Pi bridging the radio, a bench laptop):

  ```
  $ SET BACKEND PRATIC_HW
  $ SET PRATIC /TRANSPORT=JSONL /HOST=192.168.1.60 /PORT=4800 /CONNECT
  ```

  Telemetry (gateway → front end), one JSON object per line:

  ```json
  {"type":"train","train":"201","position":123.4,"speed":2.1,
   "forward":true,"confidence":"localized","link":"ok","limit":350.0}
  {"type":"wayside","station":3}
  {"type":"turnout","turnout":1,"reversed":true}
  ```

  Commands (front end → gateway):

  ```json
  {"type":"ma","train":"201","limit":350.0,"target":10.0}
  {"type":"target","train":"201","target":8.0}
  {"type":"mode","train":"201","auto":false}
  {"type":"estop","train":"201","engaged":true}
  {"type":"relocalize","train":"201","balise":4}
  {"type":"turnout","turnout":1,"reversed":true}
  ```

- **`SERIAL`** *(integration stub)* — `PraticSerialTransportStub` fails
  cleanly with a pointer to itself. When the real comms hardware is on
  the bench, implement its `connect`/`send`/read-loop (ORSSerialPort,
  IOKit, or a USB-CDC bridge) and translate frames to and from
  `PraticWireMessage`. Nothing else in the app changes — that is the
  point of the seam.

### Writing a transport

Conform to `PraticTransport` (four members: `state`, `onState`,
`onMessage`, `connect/disconnect/send`), keep everything on the main
actor (`HardwareTCPLink` shows the Network.framework pattern), and wire
a case for it in `PraticHardwareBackend.configureTransport`.

## Relationship to the model-track hardware bridge

`SET HARDWARE` (see [hardware-drivers.md](hardware-drivers.md)) mirrors
*simulated* trains **outward** onto model track — useful under `VAL` or
`PRATIC_SIM`. Under `PRATIC_HW` the physical trains drive themselves,
so the bridge's output scan stands down automatically: the two features
are opposite directions of the same seam and never fight.

## Status / next steps

- The mimic-display polish the brief sketches (moving-block envelopes
  drawn around each train, uncertainty regions and staleness greying in
  the 3D synoptic and train cards) renders today through the mirror at
  parity with VAL trains; the PRATIC-specific overlays are view work
  still to do.
- Turnouts model state and interlocking only — the demo loop has no
  physical branches yet.
- As with everything in this repository: hobby model scale only, not a
  safety controller.
