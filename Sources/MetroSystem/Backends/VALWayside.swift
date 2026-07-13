import Foundation

/// The PA fixe -- VAL's fixed wayside equipment, condensed to one loop:
///
/// - Vehicle detection (WCU boards INTUSA / DCIS): a fail-safe
///   check-in/check-out picture of which blocks are occupied. Continuous
///   positive detection (PD) comes from every train's presence signal on
///   the downlink loop; the tail of a rame keeps its previous block
///   registered until it has fully cleared -- so occupancy covers the
///   train's length, not just its antenna.
/// - Speed-program selection (WCU board AFSC/PP): per local rame, energize
///   the normal SF program when the downstream block is free, the
///   perturbed PP program when it is occupied, and withdraw the SF
///   entirely (-> on-board FU) for line emergencies or a rame stranded
///   outside a service-provisoire section.
/// - Dwell operation (DOCU, per station): the station stopping sequence,
///   departure authorization (withheld while the downstream block is
///   occupied, while platform doors are open, or while the SP headway
///   pacing holds the rame), and the terminus turnback order.
///
/// Peer-owned rames are detection inputs only -- their own node runs
/// their wayside. Exactly one authority per train, as before.
@MainActor
final class VALWayside {
    let track = VALTrackDatabase.shared

    /// Physical length of a rame (two married cars) for tail occupancy.
    private let rameLength: Double = 26.0

    /// DOCU departure clocks per terminus station (SP headway pacing).
    private var lastTerminusDeparture: [Int: Date] = [:]

    // MARK: -- vehicle detection

    /// Blocks occupied by each known train (local AND remote), keyed by
    /// block id, with the occupying train ids. A rame registers the block
    /// under its position and the block containing its tail.
    func detectOccupancy(trains: [Train]) -> [Int: Set<UUID>] {
        var occupancy: [Int: Set<UUID>] = [:]
        for t in trains {
            let head = track.block(at: t.position)
            occupancy[head.id, default: []].insert(t.id)
            let tailPos = t.position - t.travelDirection.rawValue * rameLength
            let tail = track.block(at: tailPos)
            if tail.id != head.id {
                occupancy[tail.id, default: []].insert(t.id)
            }
        }
        return occupancy
    }

    private func isOccupied(_ block: VALBlock, by others: [Int: Set<UUID>],
                            excluding me: UUID) -> Bool {
        guard let ids = others[block.id] else { return false }
        return !ids.subtracting([me]).isEmpty
    }

    // MARK: -- program selection + DOCU

    /// Assemble the uplink telegram for one locally-owned rame.
    func telegram(for train: Train, occupancy: [Int: Set<UUID>],
                  world: MetroWorld, now: Date) -> VALTelegram {
        var tg = VALTelegram()
        tg.direction = train.travelDirection

        // Line-wide arrêt d'urgence: the SF carrier is withdrawn for all
        // guideway sections (DOT §3.5.2.13) -- every rame takes FU.
        if world.isEmergencyStopped {
            tg.program = .absent
            return tg
        }

        // A rame stranded outside the active SP section sits on
        // unenergized guideway: no SF, vital stop in place.
        if let sp = world.activeSP, world.isStranded(train, sp: sp) {
            tg.program = .absent
            return tg
        }

        let block = track.block(at: train.position)
        tg.blockCode = block.normalCode
        tg.nextBlockCode = track.nextBlock(after: block.id,
                                           direction: train.travelDirection).normalCode

        // Sequential presence detection: entering a block that is already
        // occupied registers a penetration. Only the entry zone counts --
        // a leader's tail dropping back into a deeply-occupied block is
        // the follower's PP problem, not a check-in violation.
        if isOccupied(block, by: occupancy, excluding: train.id) {
            let entry = train.travelDirection == .forward ? block.start : block.end
            let depth = VALTrackDatabase.distanceAhead(from: entry, to: train.position,
                                                       direction: train.travelDirection)
            if depth < 30 { tg.penetrationDepth = depth }
        }

        // Central-control zero-speed order: line service off is a
        // restrictive speed command, not an FU (trains brake to a stand
        // with service brakes and hold).
        if !world.isRunning { tg.restriction = 0 }

        // Nearest occupied block boundary ahead -- the AVP penetration
        // reference in every mode, and the PP anchor when it is the very
        // next block. Scan up to a full loop of blocks ahead.
        var probe = block
        for step in 0..<track.blocks.count {
            let next = track.nextBlock(after: probe.id, direction: train.travelDirection)
            if isOccupied(next, by: occupancy, excluding: train.id) {
                let boundary = train.travelDirection == .forward ? next.start : next.end
                tg.occupiedBoundary = boundary
                if step == 0 {
                    // Downstream block occupied: the WCU modulates f2 --
                    // follow the perturbed stopping program to a
                    // service-brake stop d metres before the boundary.
                    tg.program = .perturbed
                    tg.stopAnchor = wrapped(boundary - train.travelDirection.rawValue * Sim.perturbedStopMargin)
                }
                break
            }
            probe = next
        }

        // SP barriers: the guideway beyond the section termini is not
        // energized. When the very next block lies outside the section,
        // treat its boundary as a perturbed stop (margin 0 -- the old
        // "virtual barrier" behaviour, now expressed as the WCU refusing
        // to energize the next SF section).
        if let sp = world.activeSP, tg.program != .perturbed {
            let served = Set(world.activeStations(sp: sp).map(\.id))
            let next = track.nextBlock(after: block.id, direction: train.travelDirection)
            let nextServed = next.stationId.map { served.contains($0) } ?? blockInsideSP(next, sp: sp, world: world)
            if !nextServed {
                let boundary = train.travelDirection == .forward ? next.start : next.end
                tg.program = .perturbed
                tg.stopAnchor = boundary
                tg.occupiedBoundary = tg.occupiedBoundary ?? boundary
            }
        }

        // Station sequence (DOCU): a station block splits into SFa
        // (arrival, up to the stop point) and SFb (departure).
        if let stationId = block.stationId, let stop = block.stopPoint,
           tg.program != .perturbed {
            let served = world.activeStations()
            let isServedStation = served.contains { $0.id == stationId }
            let distToStop = VALTrackDatabase.distanceAhead(from: train.position, to: stop,
                                                            direction: train.travelDirection)
            let approaching = distToStop < block.length && train.lastServicedStationId != stationId
            if isServedStation && approaching {
                // SFa energized: decelerate onto the platform stop point.
                tg.program = .stationArrival
                tg.stopAnchor = stop
                tg.stationId = stationId
            } else if train.lastServicedStationId == stationId {
                // At or past the stop point: departure side. The DOCU
                // authorizes SFb only when the dwell is complete, the
                // doors are closed and locked, the downstream block is
                // free, and no headway hold applies.
                let hold = departureHold(for: train, stationId: stationId,
                                         block: block, occupancy: occupancy,
                                         world: world, now: now)
                tg.program = hold ? .departureHeld : .stationDeparture
            }
        }

        // Terminus turnback order under SP (DOCU route function): a rame
        // docked at a section terminus pointing at the barrier receives
        // the opposite direction bits once its exchange is complete.
        if let sp = world.activeSP,
           train.status == .docked, train.speed == 0, train.paxRemaining == 0,
           let last = train.lastServicedStationId {
            if (last == sp.startStationId && train.travelDirection == .reverse) ||
               (last == sp.endStationId && train.travelDirection == .forward) {
                tg.turnback = true
            }
        }

        return tg
    }

    /// DOCU departure authorization. Returns true while departure must be
    /// withheld. Also advances the terminus departure clocks.
    private func departureHold(for train: Train, stationId: Int, block: VALBlock,
                               occupancy: [Int: Set<UUID>], world: MetroWorld,
                               now: Date) -> Bool {
        // Doors open or exchange still running: not authorized (the SFa/
        // SFb signals are off while the platform doors are open).
        if train.doorsOpen || train.isDwelling { return true }

        // Downstream block occupied: departure withheld (DOT §4.5.4).
        let next = track.nextBlock(after: block.id, direction: train.travelDirection)
        if isOccupied(next, by: occupancy, excluding: train.id) { return true }

        // SP headway pacing at the section termini.
        guard let sp = world.activeSP else { return false }
        let isTerminus = stationId == sp.startStationId || stationId == sp.endStationId
        guard isTerminus else { return false }
        let lastDep = lastTerminusDeparture[stationId] ?? .distantPast
        if lastDep != .distantPast && now.timeIntervalSince(lastDep) < sp.intervalle {
            return true
        }
        lastTerminusDeparture[stationId] = now
        return false
    }

    /// Whether an interstation block lies inside the active SP section.
    private func blockInsideSP(_ block: VALBlock, sp: ServiceProvisoire,
                               world: MetroWorld) -> Bool {
        guard let s1 = world.stations.first(where: { $0.id == sp.startStationId }),
              let s2 = world.stations.first(where: { $0.id == sp.endStationId }) else { return true }
        let mid = block.start + block.length / 2
        let (lo, hi) = (min(s1.position, s2.position), max(s1.position, s2.position))
        if s1.position <= s2.position {
            return mid >= lo && mid <= hi
        } else {
            return mid >= s1.position || mid <= s2.position
        }
    }

    /// Reset the DOCU clocks when the SP is cleared.
    func clearDepartureClocks() {
        lastTerminusDeparture.removeAll()
    }

    private func wrapped(_ position: Double) -> Double {
        var p = position.truncatingRemainder(dividingBy: Sim.trackLength)
        if p < 0 { p += Sim.trackLength }
        return p
    }
}
