import Foundation

/// The HR car's traction chain (Verhille thesis, Ch. 1) plus the brake
/// blending of DOT §3.2.6, integrated per rame per scan:
///
///   750 V bars -> input filter -> per car: GTO armature chopper (300 Hz,
///   the two cars interleaved) feeding two series-wired DC motors, one
///   per bogie -> transmission shaft -> differential (4.3) -> wheel
///   reducers (2.0) -> tires -> the tire/track adhesion law mu(lambda).
///
/// "Image série": the separately-excited machines are driven so the rame
/// behaves like the series-excited first generation -- full field
/// iex = 0.059 ii until the armature modulation saturates, then weakened
/// to 0.034 ii for the run to top speed (phases 1/3 of Fig. 1.32).
///
/// Braking blends regenerative (chopper, down to ~5 km/h, line-
/// receptivity-limited) with the PEPD-controlled friction disks; the
/// emergency brake is spring-applied friction only.
///
/// Adhesion runs per bogie: demanded rim force beyond mu.N lets the
/// wheel speed run away from the vehicle (patinage) or lock under
/// braking (enrayage); the anti-skid function compares the two motor
/// speeds of a car and cancels that car's effort above an 8 km/h spread,
/// restoring it on a controlled ramp (thesis §2.4).
@MainActor
final class VALTractionChain {

    // MARK: -- per-scan integration

    func integrate(_ train: inout Train, state: inout VALOnboardState,
                   request: VALEffortRequest, dt: Double) {
        var ts = state.traction
        defer { state.traction = ts }

        let mass = Sim.tareMass + Double(train.passengerCount) * Sim.passengerMass
        let v = train.speed
        let resistance = davis(v, mass: mass)

        // ----- force demand from the OBCU's acceleration request -------
        var demand: Double   // N at the rims, along the running direction
        if request.emergencyBrake {
            demand = -(mass * Sim.emergencyBraking)
        } else {
            demand = mass * request.desiredAcceleration
            // Closed-loop resistance compensation: the analog loop holds
            // the commanded acceleration against drag.
            if abs(request.desiredAcceleration) > 0.01 || v > 0.1 {
                demand += resistance
            }
        }
        if demand > 0 && !request.motoringAllowed { demand = 0 }

        // ----- capability limits ---------------------------------------
        if demand > 0 {
            demand = min(demand, tractiveCapability(at: v, ts: &ts))
        } else if demand < 0 {
            let serviceMax = mass * Sim.nominalBraking * 1.15
            demand = max(demand, -serviceMax)
        }

        // ----- anti-patinage authority (per car) -----------------------
        updateAntiSkid(&ts, train: train, dt: dt)
        if demand > 0 {
            let perCar = demand / 2
            demand = perCar * ts.carAuthority[0] + perCar * ts.carAuthority[1]
        }

        // ----- adhesion transfer per bogie ------------------------------
        let applied = transferThroughContact(&ts, train: train, demand: demand,
                                             emergency: request.emergencyBrake,
                                             mass: mass, dt: dt)

        // ----- longitudinal dynamics ------------------------------------
        var accel = (applied - resistance) / mass
        // At rest, resistance cannot pull the rame backwards.
        if v <= 0.01 && accel < 0 && demand >= 0 { accel = 0 }
        train.acceleration = accel
        train.speed = max(0, v + accel * dt)
        train.position += train.speed * train.travelDirection.rawValue * dt
        train.position = train.position.truncatingRemainder(dividingBy: Sim.trackLength)
        if train.position < 0 { train.position += Sim.trackLength }

        // Wheel speeds relax toward the vehicle when not slipping.
        for i in ts.wheelSpeed.indices where abs(ts.wheelSpeed[i] - train.speed) < 0.05 {
            ts.wheelSpeed[i] = train.speed
        }

        // ----- electrical telemetry -------------------------------------
        publishElectrical(&train, ts: ts, demand: demand, applied: applied,
                          speed: train.speed, dt: dt)
    }

    // MARK: -- image série traction curve

    /// Peak rim force the chain can produce at speed `v`. Emergent
    /// three-phase behaviour: constant torque at full field, the
    /// armature-voltage ceiling, then field weakening.
    private func tractiveCapability(at v: Double, ts: inout VALTractionState) -> Double {
        let omega = motorSpeed(at: v)
        // Full field first: iex = 0.059 ii, torque per motor km.le.iex.ii.
        var ii = Sim.armatureCurrentMax
        var ratio = Sim.imageSerieFullField
        var weakened = false
        // Armature loop voltage: two motors in series plus the smoothing
        // resistance -- must fit under the filter voltage.
        func loopVoltage(_ ii: Double, _ ratio: Double) -> Double {
            2 * Sim.motorTorquePerAmp2 * ratio * ii * omega + ii * Sim.armatureResistance
        }
        if loopVoltage(ii, ratio) > Sim.lineVoltage {
            // Phase 3: weaken the field.
            ratio = Sim.imageSerieWeakField
            weakened = true
            if loopVoltage(ii, ratio) > Sim.lineVoltage {
                // Back-EMF-limited: shed armature current to fit.
                ii = Sim.lineVoltage /
                    (2 * Sim.motorTorquePerAmp2 * ratio * omega + Sim.armatureResistance)
            }
        }
        ts.armatureCurrent = [ii, ii]
        ts.fieldWeakened = [weakened, weakened]
        let torquePerMotor = Sim.motorTorquePerAmp2 * ratio * ii * ii
        let rimForce = Double(Sim.motorCount) * torquePerMotor * Sim.gearRatio / Sim.wheelRadius
        return rimForce
    }

    private func motorSpeed(at v: Double) -> Double {
        max(v, 0.1) / Sim.wheelRadius * Sim.gearRatio
    }

    // MARK: -- adhesion (contact roue-piste)

    /// Adhesion coefficient vs. slip ratio: zone 1 (pseudo-glissement)
    /// rising to the peak at lambda ~0.15, zone 2 falling away toward the
    /// gross-sliding tail (Fig. 1.26). The base curve is dry guideway;
    /// injected PATINAGE/ENRAYAGE stand for a wet/icy patch degraded
    /// enough that the comfort-limited effort exceeds the contact.
    private let lambdaPeak = 0.15

    private func muPeak(degraded: Bool) -> Double { degraded ? 0.14 : 0.55 }

    private func mu(lambda: Double, degraded: Bool) -> Double {
        let peak = muPeak(degraded: degraded)
        let tail = degraded ? 0.06 : 0.35
        let l = abs(lambda)
        if l <= lambdaPeak {
            // Zone 1: near-linear rise (initial slope ka).
            return peak * (l / lambdaPeak) * (2 - l / lambdaPeak)
        }
        // Zone 2: decay toward the sliding tail.
        let decay = (l - lambdaPeak) / (1 - lambdaPeak)
        return peak - (peak - tail) * min(1, decay)
    }

    /// Per-tire share of the load path: degraded tires shrink the
    /// transmittable effort and add drag (kept from the previous model so
    /// PNEU faults keep their operational meaning).
    private func tireFactors(_ train: Train, bogie: Int) -> (grip: Double, drag: Double) {
        // 8 tires, 2 per bogie: bogie i uses tires 2i, 2i+1.
        var grip = 0.0, drag = 0.0
        for k in 0..<2 {
            let idx = bogie * 2 + k
            guard train.tires.indices.contains(idx) else { grip += 1; continue }
            switch train.tires[idx].status {
            case .ok:          grip += 1.0
            case .lowPressure: grip += 0.9;  drag += 0.05
            case .puncture:    grip += 0.5;  drag += 0.2
            case .burst:       grip += 0.15; drag += 0.5
            }
        }
        return (grip / 2, drag)
    }

    /// Push the demanded rim force through the four bogie contacts.
    /// Returns the force actually applied to the chassis. Wheel speeds
    /// integrate their own dynamics when the contact saturates.
    private func transferThroughContact(_ ts: inout VALTractionState, train: Train,
                                        demand: Double, emergency: Bool,
                                        mass: Double, dt: Double) -> Double {
        let v = train.speed
        let axleLoad = mass * 9.81 / 4
        let wheelMassEq = Sim.bogieInertia / (Sim.wheelRadius * Sim.wheelRadius)
        var applied = 0.0
        var tireDrag = 0.0
        ts.slipping = false
        ts.sliding = false

        for bogie in 0..<4 {
            let car = bogie / 2
            var share = demand / 4
            if demand > 0 { share *= ts.carAuthority[car] }
            let factors = tireFactors(train, bogie: bogie)
            tireDrag += factors.drag * axleLoad / 100      // small N-scale drag

            let degraded = (demand > 0 && train.isPatinage) || (demand < 0 && train.isEnrayage)
            var vR = ts.wheelSpeed[bogie]
            let synced = abs(vR - v) < 0.05
            let peakLimit = muPeak(degraded: degraded) * axleLoad * factors.grip
            if synced && abs(share) <= peakLimit {
                // Zone 1 (pseudo-glissement): the contact transmits the
                // whole effort; the wheel stays with the vehicle.
                applied += share
                vR = v
            } else {
                // Contact saturated: the wheel integrates its own speed
                // against the slip curve; the chassis only receives the
                // contact force. Zone 2's falling characteristic makes
                // the runaway (emballement) self-reinforcing until the
                // effort is cut.
                let lambda = share >= 0
                    ? (vR - v) / max(vR, 0.5)
                    : (v - vR) / max(v, 0.5)
                let contactLimit = mu(lambda: max(lambda, 0.02), degraded: degraded)
                    * axleLoad * factors.grip
                let contact = (share >= 0 ? 1.0 : -1.0) * contactLimit
                applied += contact
                let wheelNet = share - contact
                vR = max(0, vR + wheelNet / wheelMassEq * dt)
                if share >= 0 { ts.slipping = ts.slipping || vR > v + 0.3 }
                else { ts.sliding = ts.sliding || vR < v - 0.3 }
            }
            ts.wheelSpeed[bogie] = vR
        }

        // Emergency braking is friction at the calipers: adhesion caps it
        // too (an enrayage under FU lengthens the stop -- the real hazard).
        if emergency {
            let cap = 4 * mu(lambda: 0.1, degraded: train.isEnrayage) * axleLoad
            applied = max(applied, -cap)
        }

        return applied - tireDrag * (v > 0.05 ? 1 : 0)
    }

    // MARK: -- anti-patinage (thesis §2.4)

    /// Compare the two motor speeds of each car; a spread beyond the
    /// 8 km/h threshold cancels that car's effort, ramping it back once
    /// the wheels re-synchronize.
    private func updateAntiSkid(_ ts: inout VALTractionState, train: Train, dt: Double) {
        for car in 0..<2 {
            let a = ts.wheelSpeed[car * 2], b = ts.wheelSpeed[car * 2 + 1]
            let spread = abs(a - b)
            let vehicleSpread = max(abs(a - train.speed), abs(b - train.speed))
            if spread > Sim.patinageDetectSpread || vehicleSpread > Sim.patinageDetectSpread {
                ts.antiSkidActive[car] = true
                ts.carAuthority[car] = 0
            } else if ts.antiSkidActive[car] {
                ts.carAuthority[car] += dt / Sim.patinageRampTime
                if ts.carAuthority[car] >= 1 {
                    ts.carAuthority[car] = 1
                    ts.antiSkidActive[car] = false
                }
            } else {
                ts.carAuthority[car] = min(1, ts.carAuthority[car] + dt / Sim.patinageRampTime)
            }
        }
    }

    // MARK: -- resistance & electrical telemetry

    /// Résistance à l'avancement Fr = A + B.v + C.v² (thesis eq. 1.52),
    /// with the constant term scaled by the actual train mass -- rubber
    /// tires make rolling resistance the dominant share.
    private func davis(_ v: Double, mass: Double) -> Double {
        Sim.davisA * mass + Sim.davisB * v + Sim.davisC * v * v
    }

    private func publishElectrical(_ train: inout Train, ts: VALTractionState,
                                   demand: Double, applied: Double,
                                   speed: Double, dt: Double) {
        let motoring = demand > 500
        let braking = demand < -500
        if motoring {
            let ii = ts.armatureCurrent.reduce(0, +)
            // Scale the displayed line current with the actual effort share.
            let cap = tractiveCapabilityDisplay(ts: ts)
            let share = cap > 0 ? min(1, demand / cap) : 0
            train.tractionCurrent = max(60, ii * share)
            train.mainVoltage = Sim.lineVoltage - train.tractionCurrent * 0.02
        } else if braking && speed > Sim.regenMinSpeed {
            // Regeneration lifts the line a little (receptivity-limited).
            let regen = min(400, abs(demand) / 100) * Sim.regenReceptivity
            train.tractionCurrent = regen
            train.mainVoltage = min(825, Sim.lineVoltage + regen * 0.15)
        } else {
            train.tractionCurrent = 40
            train.mainVoltage = Sim.lineVoltage - 0.8
        }
        train.tractionTorque = max(-100, min(100,
            applied / (Sim.tareMass * Sim.maxAcceleration) * 100))
    }

    private func tractiveCapabilityDisplay(ts: VALTractionState) -> Double {
        let ii = ts.armatureCurrent.first ?? 0
        let ratio = (ts.fieldWeakened.first ?? false)
            ? Sim.imageSerieWeakField : Sim.imageSerieFullField
        let torque = Sim.motorTorquePerAmp2 * ratio * ii * ii
        return Double(Sim.motorCount) * torque * Sim.gearRatio / Sim.wheelRadius
    }
}
