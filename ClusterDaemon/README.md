# metro-clusterd

A headless, dependency-free SwiftPM daemon that simulates one or more
peer **PCC nodes**, each with its own fleet of auto-driven rames, and
publishes them over the same Bonjour + newline-JSON wire the MetroSystem
app speaks (`_metrosys._tcp`). Run it next to the app on a single Mac to
demonstrate the multi-node CBTC networking: the daemon's rames appear in
the app as **REMOTE** trains sharing the circular line, and the app's
trains appear to the daemon as foreign traffic its zone controller must
respect.

```bash
swift build
swift run metro-clusterd --nodes 2 --trains 2
swift run metro-clusterd --name OPERA,REPUBLIQUE
swift run metro-clusterd --selftest        # wire-codec round-trip (CI)
```

## Shared-loop CBTC

Unlike separate elevator shafts, every node's trains run on the **same
track**. Each node's ZC therefore computes movement authority for the
trains it OWNS against **every** train it knows about — its own plus the
foreign trains reported over the wire. Exactly one node is authoritative
for each train; `.state` broadcasts (default 60 Hz) carry the results and
the app dead-reckons between snapshots at lower `--rate`s.

The app can drive daemon-owned rames (doors, emergency brake, driving
mode, manual speed) via `.command` messages; fault injection and tire
state remain owner-only by design.

## Mirrored types — keep in sync with the app

The daemon deliberately avoids the app's SwiftUI/SceneKit dependencies,
so the wire types are **hand-mirrored, not cross-imported**. If you
change any of these in the app, update the mirror to match (the app
decodes the daemon's bytes and vice versa):

| App (Sources/MetroSystem/…) | Daemon (Sources/MetroClusterDaemon/…) |
| --- | --- |
| `Networking/Protocol.swift` (PeerMessage, TrainCommand, WireCodec) | `Wire.swift` |
| `Models/Train.swift` (esp. `CodingKeys`) | `Model.swift` |
| `Models/Constants.swift` (`enum Sim`, station layout) | `Model.swift` |
| `Networking/PeerNetwork.swift` discovery rules (service type, TXT `peerId`/`label`, higher-peerId-dials) | `ApplePeerLink.swift` |
| `HostSnapshotWire` | `HostSnapshot` in `Wire.swift` |

`RameSimulator.tick()` is a faithful port of `MetroWorld`'s ZC pass and
`advance()` (asservissement braking curve, station dwell, passenger
exchange, tire-adhesion model). The sim ticks at 60 Hz; the daemon
re-broadcasts `.state` at `--rate` Hz (default 60). Wire compatibility is
the invariant — the app decodes these bytes.
