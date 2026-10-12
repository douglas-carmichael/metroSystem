# Pupitre link — VALPupitreSim cabs on the line

MetroSystem can act as the PCC of **VALPupitreSim** cabs. VALPupitreSim
simulates the VAL 206 manual-driving cab — console A22, the pupitre this
app's VAL backend models — and offers a PCC link. Every cab on the network is
found, taken in hand once its operator hands it to the PCC, and run on this
node's loop among its trains: protected by the fixed-block wayside like a
local rame, shown on every surface, and driven with the same exploitation
commands. The cab end of the link is specified in VALPupitreSim's
`PCC_API.md`. This is a dispatch simulator talking to a cab simulator, not a
safety controller.

## Architecture

```
VALPupitreSim cab  (Bonjour _valpupitre._tcp, TCP 5206)
   │ hello · state 10 Hz · events              ▲ hello · acquire · ping 1 Hz
   ▼                                           │ line · command · limit · traffic 5 Hz
PupitreLink  (main actor, 10 Hz scan) ─────────┘
   · discovery   NWBrowser + PUPITRE.JSON addresses
   · control     acquire every free cab
   · the line    lend the loop, mirror the cab into MetroWorld
   · protection  stopping point from the wayside's occupancy
   · traffic     every other rame on the loop
   · SCADA       FU / VIGILANCE / PUPITRE points
   ▲
   │ PeerNetwork.control(...) for cab-owned rames
MetroWorld · PCC windows · DCL · Modbus
```

- **`Networking/PupitreWire.swift`** — the PCC side of the wire: what this
  node decodes from a cab (`CabHello`, `CabState`, `CabEvent`, `CabResult`)
  and what it sends (`CabRequest`, `CabLineOut`, `CabTrafficTrain`). It
  decodes only what it uses and ignores the rest, as the specification asks,
  so additive changes on the cab side never break the link.
- **`Networking/PupitreLink.swift`** — the singleton link: discovery,
  connections, the 10 Hz scan, the mirror, protection, traffic, SCADA and the
  command mapping. Attached in `bootstrap()`, after the backend.
- **`DCL/DCLPupitre.swift`** — `SHOW PUPITRE` and `SET PUPITRE`.

## How a cab joins the line

1. **Discovery.** The link browses `_valpupitre._tcp` and connects to every
   cab whose TXT `proto` is 1, plus any address added with
   `SET PUPITRE /ADD`. A cab reachable both ways is served by the first link
   to say hello.
2. **Control.** It acquires every free cab — one PCC per cab, as one owner
   per rame — and pings each one every second. On a multi-node line every
   node finds every cab, but only the first to acquire one controls it; the
   others watch. `SET PUPITRE rame /RELEASE` gives a cab back and stops the
   link taking it again; `/ACQUIRE` takes it again, `/FORCE` from another PCC.
3. **The line.** When the cab's operator turns its COMMANDE selector to PCC
   and the rame stands still, the controlling node lends it the loop — 10
   cantons, 6 stations, and an id derived from the layout, so it is the same
   on every node — at the station farthest from every train.
4. **The mirror.** From then on the cab's rame is a train in MetroWorld,
   labelled with the cab's rame number and owned by `pupitre:<cab id>`: not
   local, not a peer's. Every window, DCL verb and Modbus register shows it;
   `PeerNetwork` routes its controls to the link; the wayside counts it as
   block occupancy, so this node's rames stop behind it. Cab rames never go
   out on the peer wire: every node that reaches the cab mirrors it for
   itself.
5. **Leaving.** When the cab's operator takes it back (LOCALE), the cab
   returns to its own test track and its rame leaves the line.

## Protection

A cab drives itself — its own PA, or the commands it is sent — so the link
gives it the stopping point (*point d'arrêt*) this node's fixed-block wayside
would give a local rame. It is recomputed on every scan and sent again when
it moves by 25 cm or more:

- 8 m (`Sim.perturbedStopMargin`) short of the first occupied block ahead,
  or right where the rame is if it shares its block with a rame ahead;
- 8 m short of a switch zone whose points are moving or set against the
  route (VAL backend);
- with line service off, where the rame can stop — latched, so the point
  doesn't run ahead of it.

The cab's PA stops on the point; running past it trips the cab's FU, which
shows here as `ebCause` `ppOverrun`. The program shown for the rame
(`speedProgram`, the movement authority, the consigne) follows the same
point: perturbed while a rame ahead holds it, normal otherwise. A **general
emergency stop** applies the FU of every cab this node controls, and releases
the ones it applied when the stop ends.

## Traffic

Five times a second, every cab this node runs on the loop is told where every
other rame is — this node's, its peers', other cabs' — with its number, speed
and sense of travel. The cab draws them in its chase and cab views and on its
map, and carries them forward between reports. On the cab this is display
only: the stopping point is what keeps it clear.

## Telemetry

The link asks each cab for its state 20 times a second. A cab streams its
rame's instruments with it — the traction chain (line voltage and current,
armature and field currents, chopper duty, torque) and the auxiliaries
(converter, battery, lighting, compressor, main reservoir, brake box) —
computed with the same VAL 206 traction-chain constants as the VAL backend.
They go straight onto the mirrored rame, so the train-detail synoptic, the
traction bench, `VALCP SHOW RAME` and the Modbus bench registers read the
cab's own figures. (A cab too old to send them gets a plausible picture
painted from its voyants instead.)

The PCC window lists cab rames first, ahead of the fleet: someone is at
those pupitres. Only the window's order changes; DCL listings and the Modbus
rame indices keep label order.

## Geometry

MetroWorld places a rame by its **head**, the end leading in its direction of
travel, and gives it 26 m behind that. A cab reports the centre of its car 1,
at its AV end, and its `hello.geometry` says how far each end lies from it:
6.4 m to the AV end, 19.6 m to the AR end. The link converts both ways. The
cab's rame enters MetroWorld by its head, so its occupancy covers exactly the
26 m it fills; stopping points and traffic go back to the cab in its own
reference. A cab joins the line with its reference point on a station mark,
so its head stands 6.4 m past the mark.

## Commands

Exploitation commands on a cab's rame go to the cab:

| Action | Cab command |
|--------|-------------|
| Doors open / close | `doorsOpen both` / `doorsClose` |
| FU set / release | `emergencyBrake true` / `false` |
| Automatic | `kg true` and `reverser AV` when needed, then `pa true` |
| Manual | `pa false` |
| Pupitre KG, reverser, lever, KIBS, KPH | `kg`, `reverser`, `masterController`, `kibs`, `kph` |
| KACOP | `kacop`; at a stand after a vigilance trip, `emergencyBrake false` too |
| Manual speed, AVP string / voting | none: the cab has no CML governor and no AVP strings |

`START RAME` / `STOP RAME`, `SET RAME /AUTOMATIC`, `/MANUAL` and `/LEVER=`,
the PCC window's train controls and Modbus writes all reach a cab this way,
but only from the node that controls it, and only while the cab is under PCC
command (`PupitreLink.canControl`). Fault injection and tires stay with the
owner, as for a peer's rame.

## SCADA

The samplers only watch local rames, so the link raises the cab rames'
points itself:

| Source / point | Severity | Raised while |
|----------------|----------|--------------|
| `RAME n` / `FU` | major | the cab's emergency brake is latched |
| `RAME n` / `VIGILANCE` | minor | the cab's dead-man warning is on |
| `RAME n` / `PUPITRE` | major | the link to the cab is down |

When a cab falls silent, its rame is held where it was last seen, stopped,
as an obstacle, for 30 s (`PupitreLink.staleHold`). Then it is dropped.

## Operating it (DCL)

```
$ SHOW PUPITRE                           ! discovery, the line, every cab
$ SET PUPITRE /ADD=(192.168.1.42,5206)   ! a cab Bonjour can't reach
$ SET PUPITRE 301 /RELEASE               ! give rame 301's cab back
$ SET PUPITRE 301 /ACQUIRE /FORCE        ! take it from another PCC
$ SET PUPITRE /REMOVE=(192.168.1.42,5206)
```

Added addresses persist in
`~/Library/Application Support/MetroSystem/PUPITRE.JSON`, next to
HARDWARE.JSON. `HELP SET PUPITRE` and `HELP SHOW PUPITRE` have the details.
Under `SELFTEST`, `SET PUPITRE` is a dry run.

## Setting up a cab

1. Run VALPupitreSim on a Mac on the same network (this one will do). When
   macOS asks, allow it local network access, or it can't be discovered; you
   can still add it by address.
2. Give each cab a rame number of its own, one this node's rames don't use
   (the cab's PCC panel).
3. Turn the cab's COMMANDE selector to PCC. Within a couple of seconds the
   rame appears on the loop; `SHOW PUPITRE` shows it `ON THIS LINE`.
4. Put it in service like any rame: `START RAME 301` releases the FU the cab
   latched while it waited for a PCC, and `SET RAME 301 /AUTOMATIC` sets it
   running under its own PA.

MetroSystem needs local network access too, to browse for cabs; its
Info.plist lists `_valpupitre._tcp` under `NSBonjourServices`.

## Limits

- Only a node that reaches the cab mirrors its rame. A node that can't reach
  it doesn't see it, and its rames won't stop for it.
- The PRATIC backends keep their own picture of the line, so their trains
  don't stop for a cab's rame (the cab still stops for theirs). Run cabs with
  the VAL or CBTC_SIM backend.
- The reverser of a cab moves only at a stand, so `SET RAME /LEVER` and the
  pupitre controls can't reverse a moving cab.
