# MetroSystem — Modbus TCP register map

MetroSystem runs a Modbus TCP slave on **`127.0.0.1:5020`** (loopback
only). Any PLC HMI or industrial-automation toolchain — `mbpoll`,
`pymodbus`, OpenPLC, Node-RED, QModMaster — can read live train telemetry
and drive trains over the wire the same way it would talk to a real wayside
gateway. The same map is shown in-app with the **M** key on the PCC
Dispatcher, and by `SHOW MODBUS` in the DCL terminal.

Up to **16 trains** are addressed, in the PCC panel's sort order (by
label). The unit-id (slave address) field is accepted regardless of value
and echoed back — the device is addressed by IP, so masters defaulting to
unit-id 1, 128, or 255 all work.

**Function codes:** 01 (read coils), 02 (read discrete inputs), 03 (read
holding registers), 04 (read input registers), 05 (write single coil), 06
(write single register), 0F (write multiple coils), 10 (write multiple
registers). Anything else returns exception 0x01 (illegal function).

Control writes (door coils, emergency-brake coils, mode/speed registers)
work on **local and remote trains alike**: a write against a peer-owned
train is forwarded to its owning node over the peer link, exactly like the
on-screen buttons.

`train` below is the 0-based index `0..15`; `N = 16`.

## Coils — FC 01 read / FC 05 write (pulse-on commands)

| Address | Meaning |
| --- | --- |
| `0..15`   | Train[i] door **OPEN** command |
| `16..31`  | Train[i] door **CLOSE** command |
| `32..47`  | Train[i] **emergency brake SET** |
| `48..63`  | Train[i] **emergency brake RELEASE** (honoured at a stand) |
| `64..79`  | Train[i] **KACOP acknowledge** (dead-man, VAL manual driving) |
| `80..95`  | Train[i] pupitre **KG ON** (console A22 master power) |
| `96..111` | Train[i] pupitre **KG OFF** |

## Discrete inputs — FC 02 (read-only)

| Address | Meaning |
| --- | --- |
| `0..15`    | Train[i] is locally owned |
| `16..31`   | Train[i] is moving (speed > 0.05 m/s) |
| `32..47`   | Train[i] doors open |
| `48..63`   | Train[i] emergency brake applied |
| `64..79`   | Train[i] door fault latched |
| `80..95`   | Train[i] traction fault latched |
| `96..111`  | Train[i] brake fault latched |
| `112..127` | Train[i] CTC radio fault latched |
| `128..143` | Train[i] patinage (wheel slip) latched |
| `144..159` | Train[i] enrayage (wheel slide) latched |

**Chaîne de sécurité** (safety chain), `1` = contact closed / healthy.
Derived purely from train telemetry, so it is faithful for remote
(ClusterDaemon) trains too:

| Address | Contact |
| --- | --- |
| `160..175` | Door interlock proven |
| `176..191` | Overspeed governor OK |
| `192..207` | MA margin OK (not encroached) |
| `208..223` | Service brake OK |
| `224..239` | Adhesion OK (no burst tire) |
| `240..255` | Safety chain intact (series loop, incl. line mode) |

VAL backend telemetry:

| Address | Meaning |
| --- | --- |
| `256..271` | KACOP vigilance warning (manual driving, acknowledge overdue) |
| `272..287` | Perturbed stopping program (PP) selected |

## Holding registers — FC 03 read / FC 06 write

| Address | Meaning |
| --- | --- |
| `0..15`  | Train[i] mode — read/write, `0` = Manual, `1` = Auto |
| `16..31` | Train[i] manual **CML speed ceiling** ×10 (m/s ×10, `0..200`) |
| `32..47` | Train[i] pupitre **T/F lever**, signed Int16 percent (−100 full brake … +100 full traction; VAL manual mode) |
| `48..63` | Train[i] pupitre **reverser** (`0` = neutral, `1` = AV, `2` = AR) |

## Input registers — FC 04 (read-only)

Per-train telemetry:

| Address | Meaning |
| --- | --- |
| `0..15`    | Position ×10 (metres; 123.4 m → 1234) |
| `16..31`   | Speed ×100, signed Int16 (+forward / −reverse) |
| `32..47`   | Consigne (speed setpoint) ×100 |
| `48..63`   | Movement-authority distance ×10 (m) |
| `64..79`   | Passenger count |
| `80..95`   | Status (0 = stopped, 1 = moving, 2 = emergency brake, 3 = at platform) |
| `96..111`  | Block (canton) number, `1..10` |
| `112..127` | Worst tire (0 = OK, 1 = low, 2 = puncture, 3 = burst) |
| `128..143` | VAL speed program (0 = SF-N normal, 1 = PP perturbed, 2 = SFA arrival, 3 = SFB departure, 4 = HOLD, 5 = ASMD, 6 = ABSENT; `0xFFFF` = not VAL-driven) |
| `144..159` | KACOP seconds since acknowledge ×10 |

Line-wide scalars (base `1000`):

| Address | Meaning |
| --- | --- |
| `1000` | Trains known (local + remote) |
| `1001` | Remote peers connected |
| `1002` | Block (canton) count |
| `1003` | Telnet sessions |
| `1004` | Modbus clients connected |
| `1005` | Line mode (0 = stopped, 1 = normal, 2 = service provisoire, 3 = emergency) |
| `1006` | Service-provisoire start station id (0 = none) |
| `1007` | Service-provisoire end station id (0 = none) |
| `1008` | Service-provisoire headway (seconds) |
| `1009` | Active SCADA alarm count (excludes shelved) |
| `1010` | Highest active severity (0 = none, 1 = Advisory … 4 = Critical) |
| `1011` | Unacknowledged alarm count (ISA-18.2 UNACK) |
| `1012` | Shelved alarm count (ISA-18.2 SHLVD) |
| `1013` | Returned-to-normal, unacknowledged count (ISA-18.2 RTN) |
| `1014` | Track length (metres) |

## Example — read train telemetry with mbpoll

```bash
# Position ×10 of trains 0..2 (input registers 0..2)
mbpoll -m tcp -a 1 -t 3 -r 1 -c 3 127.0.0.1 -p 5020

# Command train 0's doors open (coil 0)
mbpoll -m tcp -a 1 -t 0 -r 1 127.0.0.1 -p 5020 1
```
