import Foundation

/// What the OBCU asks of the traction chain each scan -- the DRIVE
/// rack's torque-direction command plus the SAFETY rack's FU state.
struct VALEffortRequest {
    /// Desired acceleration along the running direction (m/s²). Positive
    /// = motoring, negative = service braking, 0 = coast.
    var desiredAcceleration: Double = 0
    /// Spring-applied friction braking, overriding everything.
    var emergencyBrake: Bool = false
    /// False when traction must not be applied (KG off, reverser neutral,
    /// door interlock, défaut traction): braking stays available.
    var motoringAllowed: Bool = true
}

/// The PA embarqué -- one rame's on-board control unit (OBCU), scanned
/// per rame per cycle. Two logically separate racks, as in the vehicle:
///
/// - SAFETY rack (AVP -- boards CPFS-A safe-frequency detection, SSV
///   survitesse, CPPP-A perturbed-program control, SFU FU interface):
///   fail-safe checks that hold off the emergency brake only while every
///   condition proves positive. Event trips latch the FU until the rame
///   is at a stand and the operator releases it.
/// - DRIVE rack (AVO -- boards MP 68K3, REG-A regulation, ASST-A
///   asservissement): the microprocessor computes the speed command from
///   the crossover-encoded program; an analog closed loop chases it
///   within the comfort limits (1.3 m/s², 0.65 m/s³) and runs the
///   B1/B2/B3 beacon station-stopping sequence to +/-30 cm.
///
/// Manual driving (console A22) replaces the DRIVE rack's command with
/// the pupitre lever, under the same SAFETY rack -- plus the KACOP
/// dead-man vigilance that automatic operation deliberately bypasses.
@MainActor
final class VALOnboard {

    // MARK: -- scan entry point

    /// Run one OBCU scan for a locally-owned rame. Mutates the wire-state
    /// `train` (doors, dwell, consigne telemetry, FU latch) and the
    /// backend-private `state`; returns the effort request for the
    /// traction chain. `controllerAlarm` is the PCC watchdog interlock.
    func scan(_ train: inout Train, state: inout VALOnboardState,
              telegram: VALTelegram, world: MetroWorld,
              controllerAlarm: Bool, dt: Double) -> VALEffortRequest {

        // ----- station dwell sequence (DOCU link 1/2) ------------------
        if train.isDwelling {
            runDwell(&train, dt: dt)
            if train.isDwelling {
                publish(&train, state: state, telegram: telegram,
                        vProgram: 0, world: world)
                return VALEffortRequest(desiredAcceleration: 0, motoringAllowed: false)
            }
        }
        train.isDepartureHold = telegram.program == .departureHeld

        // ----- terminus turnback (DOCU route order) --------------------
        if telegram.turnback && train.speed == 0 {
            train.travelDirection = train.travelDirection == .forward ? .reverse : .forward
            state.consigne = 0
            state.consigneAccel = 0
        }

        // ----- SAFETY rack (AVP) ---------------------------------------
        let vitalCeiling = avpCeiling(train: train, telegram: telegram)
        updateSafetyRack(&train, state: &state, telegram: telegram,
                         vitalCeiling: vitalCeiling,
                         controllerAlarm: controllerAlarm,
                         emergencyLine: world.isEmergencyStopped, dt: dt)

        if train.isEmergencyBrakeApplied {
            train.status = .emergency
            state.consigne = min(state.consigne, train.speed)
            state.consigneAccel = 0
            publish(&train, state: state, telegram: telegram,
                    vProgram: 0, world: world)
            return VALEffortRequest(desiredAcceleration: -Sim.emergencyBraking,
                                    emergencyBrake: true, motoringAllowed: false)
        }
        if train.ebCause != VALTripCause.none.rawValue { train.ebCause = VALTripCause.none.rawValue }

        // ----- DRIVE rack / console A22 --------------------------------
        let request: VALEffortRequest
        let vProgram: Double
        if train.mode == .manual {
            (request, vProgram) = manualDrive(&train, state: &state,
                                              telegram: telegram, dt: dt)
        } else {
            (request, vProgram) = automaticDrive(&train, state: &state,
                                                 telegram: telegram, world: world, dt: dt)
        }

        publish(&train, state: state, telegram: telegram,
                vProgram: vProgram, world: world)
        return request
    }

    // MARK: -- AVP (SAFETY rack)

    /// The vital speed ceiling: the crossover interval may never drop
    /// under 0.27 s where the AVO regulates to 0.30 s -- the program
    /// speed times 10/9, plus the documented detection allowance ("a
    /// maximum delay of one crossover before over-speed detection",
    /// DOT §3.5.2.3) -- floored so creeping trains keep a margin.
    private func avpCeiling(train: Train, telegram: VALTelegram) -> Double {
        let program = programSpeed(train: train, telegram: telegram, includeStops: true)
        // Floor: the berthing envelope. Below ~3 m/s the B3 position loop
        // owns the approach and the crossover timing has no resolution.
        return max(program * Sim.avpOverspeedRatio + 0.9, 3.0)
    }

    private func updateSafetyRack(_ train: inout Train, state: inout VALOnboardState,
                                  telegram: VALTelegram, vitalCeiling: Double,
                                  controllerAlarm: Bool, emergencyLine: Bool,
                                  dt: Double) {
        // Condition-driven FU: applied while the condition holds, released
        // by the condition clearing (the operator clears the latched fault
        // flag, or the line emergency ends). This mirrors the old panel
        // workflow: fault chip off -> rame resumes.
        var conditionCause: VALTripCause = .none
        if emergencyLine {
            conditionCause = .lineEmergency
        } else if telegram.program == .absent {
            conditionCause = .sfLoss                    // stranded / unenergized guideway
        } else if train.isSignalFault {
            conditionCause = .sfLoss                    // injected SF-carrier fault
        } else if train.isDoorFault {
            conditionCause = .doorFault
        } else if train.isBrakeFault {
            conditionCause = .brakeFault
        } else if controllerAlarm {
            conditionCause = .controllerAlarm
        } else if train.doorsOpen && train.speed > 0.5 {
            conditionCause = .doorUnlocked              // train line broken while moving
        }

        if conditionCause != .none {
            applyFU(&train, cause: conditionCause)
            return
        }

        // Latched event trips: while the rame stands, re-verify the trip
        // cause; once it clears (the obstructing block released, the
        // overspeed gone), a hold-off matures and Central reinitiates the
        // rame automatically -- the DOT demonstrations restart vehicles
        // exactly this way, and stay held while the cause persists.
        // Operator FU and the KACOP trip stay until operator action.
        if train.isEmergencyBrakeApplied {
            guard train.speed < 0.05,
                  let cause = VALTripCause(rawValue: train.ebCause) else { return }
            let recoverable: Bool
            switch cause {
            case .overspeed, .rollback:
                recoverable = true
            case .ppOverrun, .blockPenetration:
                // Clear only when no perturbed stop applies any more and
                // the rame is not sharing an occupied block.
                recoverable = telegram.program != .perturbed
                    && telegram.penetrationDepth == nil
            default:
                recoverable = false
            }
            if recoverable {
                state.tripHoldoff += dt
                if state.tripHoldoff >= 5.0 {
                    train.isEmergencyBrakeApplied = false
                    train.ebCause = VALTripCause.none.rawValue
                    train.status = .stopped
                    state.tripHoldoff = 0
                }
            } else {
                state.tripHoldoff = 0
            }
            return
        }
        state.tripHoldoff = 0

        // Survitesse (SSV): over the vital ceiling.
        if train.speed > vitalCeiling + 0.3 {
            applyFU(&train, cause: .overspeed)
            return
        }

        // Overpassing the perturbed stopping point (CPPP-A): the PP
        // profile ends d metres before the occupied block -- passing it
        // while still rolling is an immediate FU.
        if telegram.program == .perturbed, let anchor = telegram.stopAnchor {
            let d = VALTrackDatabase.distanceAhead(from: train.position, to: anchor,
                                                   direction: train.travelDirection)
            if d > Sim.trackLength / 2 && train.speed > 0.3 {
                // Anchor now behind us: overrun.
                applyFU(&train, cause: .ppOverrun)
                return
            }
        }

        // Penetration into an occupied block (sequential detection):
        // instant in automatic; manual (ASMD recovery moves) trips after
        // 10 m, per the demonstration tests.
        if let penetration = telegram.penetrationDepth {
            state.blockEntryPenetration = penetration
            let tripAt = train.mode == .manual ? Sim.manualPenetrationTrip : 1.0
            if penetration > tripAt {
                applyFU(&train, cause: .blockPenetration)
                return
            }
        } else {
            state.blockEntryPenetration = 0
        }

        // Rollback: movement against the commanded direction beyond 5 m.
        let commanded = train.mode == .manual && train.pupitreReverser != 0
            ? Double(train.pupitreReverser)
            : train.travelDirection.rawValue
        let along = train.speed * train.travelDirection.rawValue * commanded
        if along < -0.01 {
            state.rollbackDistance += abs(train.speed) * dt
            if state.rollbackDistance > Sim.rollbackTrip {
                applyFU(&train, cause: .rollback)
                state.rollbackDistance = 0
                return
            }
        } else if train.speed > 0.1 {
            state.rollbackDistance = 0
        }

        // KACOP vigilance (manual only; PA bypasses the dead-man).
        if train.mode == .manual && train.pupitreKG {
            train.kacopSecondsSinceAck += dt
            train.kacopWarning = train.kacopSecondsSinceAck >= Sim.kacopWarningDelay
            if train.kacopSecondsSinceAck >= Sim.kacopTripDelay {
                applyFU(&train, cause: .vigilance)
                train.kacopSecondsSinceAck = 0
                train.kacopWarning = false
                return
            }
        } else {
            train.kacopSecondsSinceAck = 0
            train.kacopWarning = false
        }
    }

    private func applyFU(_ train: inout Train, cause: VALTripCause) {
        if !train.isEmergencyBrakeApplied {
            train.emergencyBrakeCounter += 1
        }
        train.isEmergencyBrakeApplied = true
        train.ebCause = cause.rawValue
    }

    // MARK: -- AVO (DRIVE rack)

    /// The encoded program speed at the rame's position: the block code,
    /// tapered onto the next block's code before the boundary, shaped by
    /// the decreasing-speed profiles when a stop anchor is active, and
    /// scaled by the Central proportional restriction. `lead` (metres)
    /// anticipates the code-drop taper -- the driving profile brakes
    /// early so the jerk-limited transition completes before the
    /// boundary, the way the real track's crossover spacing embeds the
    /// transition. The AVP evaluates with lead 0 (the physical
    /// crossovers).
    private func programSpeed(train: Train, telegram: VALTelegram,
                              includeStops: Bool = true,
                              lead: Double = 0) -> Double {
        var v = telegram.blockCode

        // Crossover taper onto a lower downstream code: the encoded
        // spacing shortens ahead of the boundary so arrival speed
        // matches the next block.
        if telegram.nextBlockCode < v, let boundary = telegram.boundaryAhead(of: train) {
            let curve = (telegram.nextBlockCode * telegram.nextBlockCode
                         + 2 * Sim.nominalBraking * max(0, boundary - lead)).squareRoot()
            v = min(v, curve)
        }

        // Decreasing-speed profile to the active stop anchor (PP or SFa).
        if includeStops, let anchor = telegram.stopAnchor {
            var d = VALTrackDatabase.distanceAhead(from: train.position, to: anchor,
                                                   direction: train.travelDirection)
            if d > Sim.trackLength / 2 { d = 0 }    // anchor reached / passed
            let curve = (2 * Sim.nominalBraking * max(0, d - Sim.maDistanceMargin)).squareRoot()
            v = min(v, curve)
        }

        // Departure not authorized: SFb unenergized, command zero.
        if includeStops && telegram.program == .departureHeld { v = 0 }

        return max(0, v * telegram.restriction)
    }

    /// Automatic driving: jerk-limited trajectory chasing the program
    /// speed, with the beacon-staged precision stop at platforms.
    private func automaticDrive(_ train: inout Train, state: inout VALOnboardState,
                                telegram: VALTelegram, world: MetroWorld,
                                dt: Double) -> (VALEffortRequest, Double) {
        // The driving profile anticipates code drops by the jerk
        // transition (b/Jmax = 2 s at full service rate, speed-scaled
        // with reserve), keeping the actual speed inside the AVP's
        // crossover ceiling.
        let taperLead = train.speed * 2.6 + 2.0
        var vProgram = programSpeed(train: train, telegram: telegram, lead: taperLead)

        // Perturbed stopping program: close the last metres on the
        // berthing profile so the rame lands INSIDE the margin d instead
        // of drifting over the CPPP-A trip.
        if telegram.program == .perturbed, let anchor = telegram.stopAnchor {
            var d = VALTrackDatabase.distanceAhead(from: train.position, to: anchor,
                                                   direction: train.travelDirection)
            if d > Sim.trackLength / 2 { d = 0 }
            vProgram = min(vProgram, Self.berthingProfile(d))
        }

        // Station approach: the B1/B2/B3 beacons stage the stop. B1 has
        // already shaped vProgram via the SFa curve; B2 caps the creep,
        // B3 closes a position loop onto the stop marker.
        if telegram.program == .stationArrival, let anchor = telegram.stopAnchor {
            let d = VALTrackDatabase.distanceAhead(from: train.position, to: anchor,
                                                   direction: train.travelDirection)
            if d <= Sim.beaconB3Distance {
                state.beaconPhase = .b3PrecisionStop
            } else if d <= Sim.beaconB2Distance {
                state.beaconPhase = .b2Creep
            } else if d <= Sim.beaconB1Distance {
                state.beaconPhase = .b1Decel
            } else {
                state.beaconPhase = .none
            }
            if d <= Sim.beaconB1Distance {
                vProgram = min(vProgram, Self.berthingProfile(d))
            }

            // Berthed: within the programmed-stop tolerance and at rest.
            if d <= max(Sim.stopPrecision, Sim.stationStopTolerance) && train.speed < 0.1,
               let stationId = telegram.stationId {
                beginDwell(&train, stationId: stationId)
                state.consigne = 0
                state.consigneAccel = 0
                state.beaconPhase = .none
                return (VALEffortRequest(desiredAcceleration: 0, motoringAllowed: false), 0)
            }
        } else {
            state.beaconPhase = .none
        }

        // Jerk-limited command shaping (processors Rc3 / Rc3-1 / Rc2 of
        // the current VAL 206 control): the consigne ramps toward the
        // program speed within gamma-max and J-max. Inside a
        // deceleration zone (the program below the block code -- a
        // taper, a stop profile), the consigne may rise UP TO the
        // descending profile but never ride above it, the way B1
        // "initiates deceleration": chasing a falling curve from above
        // through the jerk transition runs straight into the SSV. A rame
        // stopped under a taper still departs -- it accelerates below
        // the profile.
        let decelZone = vProgram < telegram.blockCode * telegram.restriction - 0.1
            && state.consigne >= vProgram - 0.2
        let accel = shapeConsigne(&state, toward: vProgram, dt: dt,
                                  motoringInhibited: decelZone)

        // Analog closed loop (REG-A): proportional error plus the
        // trajectory feed-forward. Braking authority runs 15% past the
        // nominal rate (the PEPD's proportional reserve) so the loop can
        // hold the 1.3-based curves without riding above them.
        var desired = (state.consigne - train.speed) * 1.6 + accel * 0.9
        desired = max(-Sim.nominalBraking * 1.15, min(Sim.maxAcceleration, desired))

        train.status = train.speed > 0.05 || state.consigne > 0.05 ? .moving : .stopped
        if train.status == .stopped {
            desired = 0
            train.speed = 0
        }

        return (VALEffortRequest(desiredAcceleration: desired,
                                 motoringAllowed: !train.isEngineFault), vProgram)
    }

    /// Manual driving from console A22 (pupitre semantics per
    /// VALPupitreSim): the lever commands traction/braking directly,
    /// under the traction interlocks and the CML speed ceiling. The
    /// SAFETY rack stays fully active above.
    private func manualDrive(_ train: inout Train, state: inout VALOnboardState,
                             telegram: VALTelegram, dt: Double) -> (VALEffortRequest, Double) {
        // Reverser: at a stand, pointing the reverser reorients the rame;
        // while rolling it only gates traction.
        if train.speed < 0.1 && train.pupitreReverser != 0 {
            let dir: TravelDirection = train.pupitreReverser > 0 ? .forward : .reverse
            if dir != train.travelDirection {
                train.travelDirection = dir
                state.consigne = 0
                state.consigneAccel = 0
            }
        }

        // CML ceiling: the limited-manual-driving governor. An explicit
        // /SPEED setpoint lowers it; otherwise the mode maximum applies.
        let ceiling = train.manualSpeedRequest > 0.05
            ? min(train.manualSpeedRequest, Sim.manualSpeedMax)
            : Sim.manualSpeedMax

        let tractionInhibited = !train.pupitreKG
            || train.pupitreReverser == 0
            || train.doorsOpen
            || train.isEngineFault
            || train.speed >= ceiling

        var desired: Double = 0
        let lever = max(-1.0, min(1.0, train.pupitreLever))
        if lever > 0 {
            desired = tractionInhibited ? 0 : lever * Sim.maxAcceleration
        } else if lever < 0 {
            // Service braking is always available, KG or not.
            desired = lever * Sim.nominalBraking
        }

        train.status = train.speed > 0.05 ? .moving
            : (train.doorsOpen ? .docked : .stopped)

        // The consigne telemetry follows the governor ceiling so the
        // scope and the overspeed predicate stay meaningful in manual.
        state.consigne = min(ceiling, avpCeilingDisplay(telegram: telegram, train: train))
        state.consigneAccel = 0

        return (VALEffortRequest(desiredAcceleration: desired,
                                 motoringAllowed: !tractionInhibited),
                state.consigne)
    }

    private func avpCeilingDisplay(telegram: VALTelegram, train: Train) -> Double {
        max(programSpeed(train: train, telegram: telegram, includeStops: false), Sim.asmdSpeed)
    }

    /// The precision-stop law shared by the B3 loop and the PP endpoint:
    /// a soft braking curve (0.9 m/s²) aimed 1.5 m short of the marker.
    /// The proportional loop trails any curve by ~decel/Kp, so aiming
    /// early is what actually lands the rame inside the berth window --
    /// and gentler-than-encoded braking keeps the tracked speed inside
    /// the AVP's collapsing ceiling all the way in.
    static func berthingProfile(_ d: Double) -> Double {
        (2 * 0.9 * max(0, d - Sim.stationStopTolerance)).squareRoot()
    }

    /// Jerk-limited chase of a target speed; returns the shaped
    /// acceleration (the consigne's current slope). The chase constant
    /// is short (0.35 s) so the consigne tracks a descending braking
    /// curve with a lag well inside the AVP's 10 percent margin; the
    /// jerk limit still smooths the transitions.
    private func shapeConsigne(_ state: inout VALOnboardState, toward target: Double,
                               dt: Double, motoringInhibited: Bool = false) -> Double {
        let error = target - state.consigne
        var wanted = max(-Sim.nominalBraking * 1.15, min(Sim.maxAcceleration, error / 0.35))
        // Near the target, decay the slope so the consigne settles.
        if abs(error) < 0.05 { wanted = 0 }
        if motoringInhibited { wanted = min(wanted, 0) }
        let jerkStep = Sim.jerkMax * dt
        state.consigneAccel += max(-jerkStep, min(jerkStep, wanted - state.consigneAccel))
        if motoringInhibited { state.consigneAccel = min(state.consigneAccel, 0) }
        state.consigne += state.consigneAccel * dt
        if state.consigne < 0 { state.consigne = 0; state.consigneAccel = 0 }
        return state.consigneAccel
    }

    // MARK: -- dwell / passenger exchange (unchanged behaviour)

    private func runDwell(_ train: inout Train, dt: Double) {
        train.dwellRemaining -= dt
        if train.dwellRemaining <= 0 {
            train.passengerCount = max(0, train.passengerCount + train.paxRemaining)
            train.paxRemaining = 0
            train.dwellRemaining = 0
            train.isDwelling = false
            train.doorsOpen = false
            train.status = .docked
            train.lastPaxChange = 0
            train.paxBoarding = 0
            train.paxAlighting = 0
            return
        }
        if train.paxRemaining != 0 {
            train.paxExchangeTimer -= dt
            if train.paxExchangeTimer <= 0 {
                if train.paxRemaining > 0 {
                    train.passengerCount += 1
                    train.paxRemaining -= 1
                } else {
                    train.passengerCount = max(0, train.passengerCount - 1)
                    train.paxRemaining += 1
                }
                train.paxExchangeTimer = train.paxExchangeInterval
            }
        }
        train.status = .docked
        train.speed = 0
        train.acceleration = 0
    }

    func beginDwell(_ train: inout Train, stationId: Int) {
        train.isDwelling = true
        let dwell = Double.random(in: Sim.dwellMin...Sim.dwellMax)
        train.dwellRemaining = dwell
        train.doorsOpen = true
        train.status = .docked
        train.speed = 0
        train.acceleration = 0
        train.lastServicedStationId = stationId
        let alighting = Int.random(in: 0...min(Sim.paxAlightMax, train.passengerCount))
        let headroom = max(0, Sim.paxCapacity - (train.passengerCount - alighting))
        let boarding = Int.random(in: 0...min(Sim.paxBoardMax, headroom))
        let change = boarding - alighting
        train.paxBoarding = boarding
        train.paxAlighting = alighting
        train.lastPaxChange = change
        train.paxRemaining = change
        train.paxExchangeInterval = abs(change) > 0 ? (dwell * 0.6) / Double(abs(change)) : 1.0
        train.paxExchangeTimer = 0
    }

    // MARK: -- telemetry projection

    /// Write the scan's OBCU picture onto the wire-state fields every
    /// surface renders (consigne dial, MA distance, program mnemonic,
    /// next station).
    private func publish(_ train: inout Train, state: VALOnboardState,
                         telegram: VALTelegram, vProgram: Double,
                         world: MetroWorld) {
        train.consigneVitesse = state.consigne
        train.speedError = state.consigne - train.speed
        train.targetSpeed = vProgram
        train.speedProgram = telegram.program.rawValue

        // Authority telemetry: the active stop anchor, else the occupied
        // boundary less the PP margin, else a free run of the whole loop.
        let limit: Double
        if let anchor = telegram.stopAnchor {
            limit = anchor
        } else if let boundary = telegram.occupiedBoundary {
            limit = boundary - train.travelDirection.rawValue * Sim.perturbedStopMargin
        } else {
            limit = train.position - train.travelDirection.rawValue * Sim.perturbedStopMargin
        }
        train.movementAuthority = wrapped(limit)
        var d = VALTrackDatabase.distanceAhead(from: train.position, to: train.movementAuthority,
                                               direction: train.travelDirection)
        if telegram.stopAnchor != nil && d > Sim.trackLength / 2 { d = 0 }
        train.distanceToMA = d

        // Next-station display: the SFa target, else the next served
        // platform ahead.
        if let sid = telegram.stationId {
            train.nextStationName = world.stationName(id: sid)
        } else {
            let served = world.activeStations()
            var bestD = Double.greatestFiniteMagnitude
            var bestName = train.nextStationName
            for s in served where s.id != train.lastServicedStationId {
                let ds = VALTrackDatabase.distanceAhead(from: train.position, to: s.position,
                                                        direction: train.travelDirection)
                if ds < bestD { bestD = ds; bestName = s.name }
            }
            train.nextStationName = bestName
        }

        // Leaving a serviced platform's block re-arms it for next lap.
        if let last = train.lastServicedStationId,
           let station = world.stations.first(where: { $0.id == last }) {
            let track = VALTrackDatabase.shared
            if track.block(at: train.position).id != track.block(at: station.position).id,
               !train.isDwelling {
                let ds = VALTrackDatabase.distanceAhead(from: train.position, to: station.position,
                                                        direction: train.travelDirection)
                if ds > Sim.cantonLength { train.lastServicedStationId = nil }
            }
        }
    }

    private func wrapped(_ position: Double) -> Double {
        var p = position.truncatingRemainder(dividingBy: Sim.trackLength)
        if p < 0 { p += Sim.trackLength }
        return p
    }
}

extension VALTelegram {
    /// Distance to the next block boundary in the running direction --
    /// the reference for the crossover taper.
    func boundaryAhead(of train: Train) -> Double? {
        let track = VALTrackDatabase.shared
        let block = track.block(at: train.position)
        let boundary = train.travelDirection == .forward ? block.end : block.start
        return VALTrackDatabase.distanceAhead(from: train.position, to: boundary,
                                              direction: train.travelDirection)
    }
}
