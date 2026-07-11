# PRATIC — Implementation Brief

*Context for adapting an existing UI codebase into the PRATIC control front end. PRATIC = Projet de Réseau Automatique de Trains Inter-Connectés — a miniature, CBTC-compliant train autopilot (wayside sensing, onboard control, comms link, real traction inverter) built at model scale. This brief describes the domain the front end must represent and control.*

---

## 1. Project context

- **System:** a model-scale train network run under **CBTC** (Communications-Based Train Control) principles — the driverless-metro class of signaling (Lille Metro Line 1 / Alstom Urbalis Fluence, automated Paris lines, SkyTrain, JFK AirTrain).
- **Scope:** full stack — wayside (trackside) sensing, onboard odometry and control, a communication link between them, and a real **traction inverter** (DC-to-AC power stage driving the motors), not a plain DC motor driver.
- **Front end's job:** be the **PCC / dispatcher surface** — a live view over train, track, and movement-authority state, with the controls a supervisor uses to command and recover the network.

---

## 2. CBTC domain model (what the front end is a window onto)

- **Moving block, not fixed block.** There are no fixed track-circuit sections. Each train continuously reports its **own position and speed** over the link; the system computes a safe envelope around it in real time. Trains can run close together.
- **Movement authority (MA).** For each train the system issues a **limit of authority** (how far it may proceed) plus a **speed profile**. The train drives itself to stay inside that authority — accelerate, hold, or brake.
- **Wayside / onboard split.** Wayside devices localize the train against fixed references (balises); the train fuses those fixes with onboard odometry to keep position accurate between references.
- **GoA4 (unattended).** No driver — the autopilot obeys the MA autonomously.
- **The defining failure mode — delocalization.** If the link drops or onboard position goes inconsistent, the system loses continuous awareness of the train (there is no track circuit fallback). Recovery = re-reference the train against a known balise and re-initialize. **This is the single most important behavior for the UI to surface — treat position uncertainty as a first-class state, not an error edge case.**

---

## 3. Front-end entities / state

The UI is a live projection of this state. Model it data-first.

- **Train:** `id`, `position` (segment + offset, or track coordinate), `speed`, `direction`, `target_speed`, `mode` (auto / manual / stopped / emergency), `movement_authority` (limit point + speed profile), `link_status` (ok / degraded / lost), `position_confidence` (localized / uncertain / delocalized), `last_update_ts`.
- **Track topology:** `segments` (id, length, neighbors), `nodes`, `turnouts/switches` (id, state, locked?), `balises` / reference points (id, location).
- **Wayside sensor stations:** `id`, `location`, `last_detection_ts`, `status` (ok / fault).
- **Movement authorities:** per train — limit-of-authority point, speed profile, issued/updated timestamps.
- **Alarms / events:** typed (delocalization, comms-loss, overspeed, authority-violation, sensor-fault, turnout-fault), with severity, timestamp, train/segment reference, ack state.
- **System:** network mode, dispatcher/PCC state, global stop flag.

---

## 4. Real-time data flow

- **Train → system:** position, speed, direction, odometry, link heartbeat.
- **System → train:** movement authority, speed limit, stop command, mode command.
- **Cadence & staleness:** expect frequent updates plus a heartbeat. On heartbeat timeout, mark the train **stale/delocalized** and degrade its display rather than freezing the last value silently. Every rendered train quantity should carry an age so the UI can grey out or flag stale data.
- **Decouple transport from rendering.** The physical link may be RF, serial, or IR; the front end should consume a normalized state stream and not care about the wire.

---

## 5. Views (screens)

- **Network overview / mimic display.** Track schematic with live train positions, direction, and the **moving-block safe envelope** around each train. This is the primary PCC surface.
- **Per-train detail.** Speed vs. limit, current MA, mode, link/confidence status, and controls (below).
- **Wayside / sensor panel.** Station list with last-detection and fault status.
- **Alarm / event log.** Chronological, filterable, acknowledgeable.
- **(Optional) dispatch / injection panel.** Insert/route trains, and toggles to inject failure modes for testing (comms drop, sensor fault) — useful given the simulation side of the project.

---

## 6. Controls / interactions

- Issue or adjust **movement authority**; set **target speed**.
- Switch a train **auto ⇄ manual**; **emergency stop** (single train and network-wide).
- **Throw turnouts** / set routes.
- **Re-localize** a train against a balise (the delocalization recovery action).
- **Acknowledge** alarms.

---

## 7. UI behaviors tied to the domain (the parts that make it read as real CBTC)

- **Delocalization:** on lost continuous position, show last-known position with an **uncertainty region** and require an explicit manual re-reference before returning the train to auto.
- **Comms loss:** heartbeat timeout → degrade the train's display, raise a comms alarm, hold/limit authority.
- **Overspeed / authority violation:** visual flag on the train plus an alarm when measured speed exceeds the profile or the train approaches its limit of authority.
- **Moving-block spacing:** render the safe envelope so a supervisor can see spacing and closing rates between trains at a glance.
- **Uncertainty is a state, not an exception.** Localized / uncertain / delocalized should be a visible, styled status everywhere a train appears.

---

## 8. Notes for the implementer

- Build the **data model first**; the UI is a reactive view over train / track / authority / alarm state.
- Keep the comms/transport layer behind an interface that emits normalized state updates.
- Represent scaled-but-realistic quantities (e.g., cm/s or scaled km/h; segment-relative coordinates).
- Prioritize the staleness / confidence handling early — it is the behavior that distinguishes a real CBTC surface from a generic train-set controller.
