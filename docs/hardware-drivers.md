# Model-track hardware drivers

MetroSystem can mirror its simulated rames onto **physical model trains**:
the simulation stays authoritative (movement authorities, dwell, the
asservissement), and a hardware bridge streams each locally-owned rame's
state to a driver that speaks your equipment's protocol. This is strictly
a hobby model-railway interface — the app remains a dispatch simulator,
not a safety controller, and nothing in it is approved to move a real
train.

## Architecture

```
MetroWorld (60 Hz sim)                         physical layout
      │ locally-owned rames                          ▲
      ▼                                              │
HardwareBridge (10 Hz output scan)             command station /
  · rame → RameActuation frame                 motor controller
  · unit map, throttle scale, dedupe                 ▲
  · full refresh every 1 s                           │
      ▼                                              │
RameHardwareDriver  ─────────────────────────────────┘
  CONSOLE | JSONL | DCCEX | (your driver)
      ▲
      │ HardwareSensorEvent (occupancy detectors)
      └── optional position resync back into the sim
```

- **`Hardware/HardwareTypes.swift`** — `RameActuation` (the per-rame
  "output image": 126-step throttle, direction, emergency stop, doors,
  lights), `HardwareSensorEvent`, `HardwareLinkState`, `HardwareConfig`.
- **`Hardware/HardwareDriver.swift`** — the `RameHardwareDriver`
  protocol, the driver registry, and `HardwareTCPLink` (shared
  Network.framework plumbing).
- **`Hardware/HardwareBridge.swift`** — the singleton output stage:
  samples the sim at `Sim.hardwareOutputHz`, dedupes unchanged frames,
  resends the full picture every `Sim.hardwareRefreshInterval`, and
  applies layout feedback.
- **`Hardware/Drivers/`** — the built-in drivers (below).

Only **locally-owned** rames are driven — on a multi-node line each PCC
node drives its own physical stock, mirroring how movement authority
already works. Remote rames never produce hardware output.

## Safety posture

- The output is **disabled at every launch**; driver, endpoint and
  mapping persist (`~/Library/Application Support/MetroSystem/HARDWARE.JSON`),
  but the arming does not. `SET HARDWARE /ENABLE` re-arms it each session.
- `/DISABLE`, disconnect and driver swap all send the driver's
  **stop-all** first.
- A rame under FU or an arrêt d'urgence général emits an
  `emergencyStop` frame; drivers map it to their protocol's vital stop
  (DCC-EX: speed −1), not a plain zero.
- A withdrawn rame's unit receives a stop rather than coasting forever.
- If the link fails while the output is armed, the SCADA annunciator
  raises **SYS / HW_LINK** (process-driven; returns to normal with the
  link).
- Track power is never switched implicitly — `SET HARDWARE /POWER=ON`
  is a deliberate operator action.

## Operating it (DCL)

```
$ SHOW HARDWARE                          ! status, drivers, mapping, sensors
$ SET HARDWARE /DRIVER=DCCEX /HOST=192.168.1.50 /PORT=2560
$ SET HARDWARE /UNIT=(101,3)             ! rame 101 -> DCC cab 3
$ SET HARDWARE /SCALE=0.60               ! tame a scale-fast loco
$ SET HARDWARE /CONNECT /POWER=ON /ENABLE
...
$ SET HARDWARE /DISABLE                  ! stop-all, stand down
```

Unmapped rames fall back to their numeric label as the unit (rame 101 →
address 101). `HELP SET HARDWARE` has the full qualifier list. Rehearse
with `/DRIVER=CONSOLE` first — it logs every frame that would have gone
to the track.

## Built-in drivers

### CONSOLE — dry run
No equipment; logs frames via `NSLog`. The template for new in-process
drivers and the way to verify a mapping before anything moves.

### DCCEX — DCC-EX command station (TCP)
Speaks the [DCC-EX](https://dcc-ex.com) native protocol to an
EX-CommandStation over TCP (default port 2560): `<t 1 cab speed dir>`
throttles, `<F cab fn state>` functions (F0 = lights, F1 = doors cue),
`<!>` stop-all, `<1>`/`<0>` track power. Sensors defined on the station
(`<Q id>`/`<q id>` broadcasts) surface as `HardwareSensorEvent`s.

### JSONL — generic newline-JSON TCP bridge
The out-of-process plug point. The app streams one JSON object per line
to any TCP listener:

```json
{"type":"actuation","frames":[{"unit":101,"label":"101","speedSteps":63,
 "forward":true,"emergencyStop":false,"doorsOpen":false,"lightsOn":true}]}
{"type":"stopAll"}
{"type":"power","on":true}
```

and accepts sensor events back on the same socket:

```json
{"type":"sensor","sensorId":3,"active":true}
```

A ~30-line gateway in Python/Node/whatever adapts this to hardware the
app has never heard of — Märklin CS3, LEGO Powered Up, a bench of ESCs —
with no Swift and no recompile.

## Position resync (closing the loop)

Sensor ids `1..Sim.cantonCount` conventionally mark each canton's entry
boundary. With `SET HARDWARE /RESYNC=ON`, an active canton sensor snaps
the nearest locally-owned rame (within one canton length) to that
boundary, so the simulated position — and therefore the movement
authorities protecting the other trains — tracks where the physical
train actually is instead of drifting on dead reckoning. Leave it OFF
until the layout's detectors are wired and trustworthy.

## Writing a new driver

**Out of process (preferred):** run a gateway that accepts the JSONL
stream. The process is the plugin; any language works. This is
deliberately the primary extension point — loading third-party
dylibs/bundles into a signed app fights code signing and Swift ABI
pinning for no gain over a socket.

**In process:** conform to `RameHardwareDriver` (see
`ConsoleHardwareDriver.swift` for the minimal shape, `DCCEXDriver.swift`
for a real TCP protocol), then register a descriptor:

```swift
HardwareDriverRegistry.shared.register(HardwareDriverDescriptor(
    id: "Z21",
    name: "Roco/Fleischmann z21",
    summary: "z21 LAN protocol (UDP port 21105).",
    makeDriver: { Z21Driver() }))
```

Rules a driver must honour:

- Stay on the main actor; hop Network.framework callbacks over
  (`HardwareTCPLink` does this for you).
- `apply(_:)` receives pre-deduped frames — send everything you get.
- `stopAll()` must be cheap, unconditional, and use the protocol's
  emergency stop where one exists.
- Report health through `onStateChange`; the bridge gates output on
  `.ready` and drives the SYS/HW_LINK alarm from it.
