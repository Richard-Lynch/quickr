import Foundation
import GRDB
import QuickrCore

// Reopen and remove in the local view (timers2.md §5.3, A14, A15): the "resuming" projection of
// a reopen queued from an entry, the entries hidden while their run is open, an entry's timing
// re-projected by its queued removes, and the store's half of `resumable`. The PWA's
// `lib/runs/localView.ts` (`reopenState`, `resumingRun`, `hiddenEntryIds`, `projectedEntryTiming`).

extension RunOverlay {
    // MARK: - Reopened and reverted runs

    /// Whether a reopen in the run's events applied, or was reverted since.
    static func isReopened(_ state: RunState, _ events: [RunEvent]) -> Bool {
        events.contains { event in
            event.type == .reopen
                && [.applied, .void(.reverted)].contains(state.effects[event.id.lowercased()] ?? .void(.stale))
        }
    }

    /// Whether a discard reverted one of the run's reopens (timers2.md §3.4).
    static func isReverted(_ state: RunState, _ events: [RunEvent]) -> Bool {
        events.contains { $0.type == .reopen && state.effects[$0.id.lowercased()] == .void(.reverted) }
    }

    /// Whether a reopened run has its entry (timers2.md §4.1), as far as this device can tell: the
    /// entry is here; or a finish made it (the server's, or this device's, which is sent only once
    /// the run is stopped or finishing); or the stop the reopen named is this device's and carried
    /// answers; or the version has no required question (so any stop made one). Not knowing the
    /// version counts as yes (the server decides; nothing is projected for it either way).
    static func hasEntry(
        _ db: Database, id: String, server: Run?, events: [RunEvent], mine: [(OutboxItem, RunEventPayload)],
        requiresAnswers: Bool?
    ) throws -> Bool {
        if try !ServerLayer.isTombstoned(db, kind: .entry, id: id),
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entry WHERE id = ?)", arguments: [id]) == true
        {
            return true
        }
        if server?.events.contains(where: { $0.event.type == .finish && $0.effect == .applied }) == true { return true }
        if mine.contains(where: { $0.1.type == .finish }) { return true }
        let target = events.first { $0.type == .reopen && $0.target != nil }?.target
        if let target, let stop = mine.first(where: { $0.0.id.lowercased() == target }), stop.1.event.answers != nil {
            return true
        }
        return requiresAnswers != true
    }

    /// `state` (closed: stopped or finishing) reopened by the first of `taps` that reopens it, and
    /// the taps after that one; `state` and `taps` unchanged when none does. For the overlay of a
    /// run whose version isn't stored (no step list): taps queued before the reopen are left to
    /// the server.
    static func reopened(_ state: RunState, taps: [RunEvent]) -> (RunState, [RunEvent]) {
        guard state.status == .stopped || state.status == .finishing,
            let at = taps.firstIndex(where: { tap in
                tap.type == .reopen && state.effects[tap.id.lowercased()] == nil
                    && (tap.target == nil || tap.target?.lowercased() == state.terminalId)
            })
        else { return (state, taps) }
        return (reopenState(state, reopen: taps[at], steps: nil, laps: nil), Array(taps[(at + 1)...]))
    }

    /// `state` (stopped) reopened by `reopen` (timers2.md §3.4): the last segment open again from
    /// its start, the gap from the stop to the reopen a pause carrying the stop's id. What the fold
    /// makes of a reopen with no taps after it, built without the events: for the overlay (no
    /// step list) and for a reopen from an entry (no events at all, §5.3). The approved §5.3
    /// reading (t2-m1-lead, F1-OUTBOX): the run doesn't jump when the ack lands.
    static func reopenState(
        _ state: RunState, reopen: RunEvent, steps: [TopicTimer.Step]?, laps: [TopicTimer.LapType]?
    ) -> RunState {
        guard let last = state.segments.last, let endedAt = state.endedAt else { return state }
        var s = state
        let segments = Array(state.segments.dropLast())
        let lapCount = segments.count { $0.kind == .lap }
        let done = Set(state.segments.compactMap(\.step) + state.skipped)
        s.status = .running
        s.endedAt = nil
        s.open = RunOpenSegment(
            index: segments.count, kind: last.kind, step: last.step, label: last.label, startedAt: last.startedAt,
            lapType: last.lapType)
        s.nextStep = steps?.first { !done.contains($0.key) }?.key
        s.pausedSince = nil
        s.segments = segments
        s.pauses = state.pauses + [RunPause(start: endedAt, end: reopen.at, id: state.terminalId)]
        s.effects[reopen.id.lowercased()] = .applied
        s.terminalId = nil
        if let laps, !laps.isEmpty {
            s.nextLapType = RunFold.lapTyping(lapCount + (last.kind == .lap ? 1 : 0) + 1, laps).lapType
        } else {
            s.nextLapType = nil
        }
        s.lapCount = lapCount
        s.reopenId = reopen.id.lowercased()
        return s
    }

    // MARK: - Resuming (timers2.md §5.3)

    /// A run that only a reopen queued from its entry knows: no run row here, no start queued.
    /// Projected from the entry's timing as the reopen leaves it, "resuming" until the ack
    /// replaces it with the server's run. A discard queued after it reverts it: the entry's state
    /// again, stopped (its entry exists, so nothing is projected for it). Nil without a queued
    /// reopen, or when the entry isn't here.
    static func resuming(_ db: Database, id: String, queued: [OutboxItem], _ book: VersionBook) throws -> LocalRun? {
        let mine = queued.compactMap { item in (try? item.runEventPayload()).map { (item, $0) } }
        guard let at = mine.firstIndex(where: { $0.1.type == .reopen }),
            let reopen = queuedEvent(mine[at].0, mine[at].1),
            let stored = try storedEntry(db, id: id), var timing = stored.timing,
            try topicExists(db, stored.topicId)
        else { return nil }
        let info = try book.info(stored.topicId, stored.version)
        // M1-REVIEW P2-5 (R26): the removes queued before the reopen apply to the entry's timing
        // first, as the server folds them (`entryProjection` skips them once this run is shown).
        for (_, payload) in mine[..<at] where payload.type == .remove {
            guard let target = payload.event.target?.lowercased() else { continue }
            timing = removing(target, from: timing, laps: info.timer?.laps)
        }
        let closed = RunState(
            status: .stopped, startedAt: timing.startedAt, endedAt: timing.endedAt, open: nil, nextStep: nil,
            pausedSince: nil, segments: timing.segments, skipped: timing.skipped, pauses: timing.pauses, effects: [:],
            terminalId: timing.terminalId?.lowercased())
        let discard = mine[(at + 1)...].first { $0.1.type == .discard }
        var state = reopenState(closed, reopen: reopen, steps: info.steps, laps: info.timer?.laps)
        if let discard {
            state = closed
            state.effects = [reopen.id: .void(.reverted), discard.0.id.lowercased(): .applied]
        }
        return LocalRun(
            id: id, topicId: try .wire(stored.topicId, "entry.topic_id"), topic: mine[at].1.topic,
            version: stored.version, status: state.status, state: state,
            events: mine.compactMap { queuedEvent($0.0, $0.1) }, aliases: [], server: nil, queued: queued,
            steps: info.steps, requiresAnswers: info.requiresAnswers, hasQuestions: info.hasQuestions,
            timer: info.timer, resuming: discard == nil)
    }

    /// The server layer's entry `id`: its topic, version and timing. Nil when absent or
    /// tombstoned.
    static func storedEntry(_ db: Database, id: String) throws -> (topicId: String, version: Int, timing: Timing?)? {
        let id = id.lowercased()
        guard try !ServerLayer.isTombstoned(db, kind: .entry, id: id),
            let row = try Row.fetchOne(
                db, sql: "SELECT topic_id, version, timing_json FROM entry WHERE id = ?", arguments: [id])
        else { return nil }
        let timing = try (row["timing_json"] as String?).map { try StoreJSON.decode(TimingDTO.self, $0).toDomain() }
        return (row["topic_id"], row["version"], timing)
    }

    // MARK: - Entries (timers2.md §5.3, A14)

    /// What the local view of runs changes about entries: the ids not to show as entries (a
    /// locally open or finishing run's: the run represents it, OQ-14; counts, due state and stats
    /// still count it), and the timings re-projected by this device's queued removes of a run
    /// that isn't in the view (the entry stays, pending, its revision unchanged, until the ack's
    /// entry replaces it).
    struct EntryProjection: Sendable {
        var hidden: Set<String> = []
        var timings: [String: Timing] = [:]

        var isEmpty: Bool { hidden.isEmpty && timings.isEmpty }

        /// `entry` with its re-projected timing, pending; nil when hidden.
        func apply(_ viewEntry: ViewEntry) -> ViewEntry? {
            let id = viewEntry.entry.id.wireString
            if hidden.contains(id) { return nil }
            guard let timing = timings[id] else { return viewEntry }
            var projected = viewEntry
            projected.entry.timing = timing
            if projected.syncState == .synced { projected.syncState = .pending }
            return projected
        }
    }

    /// The entry projection of one topic, or all.
    static func entryProjection(_ db: Database, topicId: String?) throws -> EntryProjection {
        let runs = try localRuns(db, topicId: topicId)
        var projection = EntryProjection()
        projection.hidden = Set(runs.filter { $0.isOpen || $0.status == .finishing }.map(\.id))
        let filter = topicId == nil ? "" : "AND topic_id = ?"
        let removes = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM outbox_item
                WHERE kind = 'run.event' AND state IN ('pending', 'in_flight', 'uncertain') \(filter)
                ORDER BY seq
                """,
            arguments: StatementArguments(topicId.map { [$0] } ?? [])
        ).map(OutboxItem.init(row:)).compactMap { item -> (String, String)? in
            guard let payload = try? item.runEventPayload(), payload.type == .remove,
                let target = payload.event.target?.lowercased(),
                !runs.contains(where: { $0.answers(to: item.entityId) })
            else { return nil }
            return (item.entityId.lowercased(), target)
        }
        guard !removes.isEmpty else { return projection }
        let book = VersionBook(db)
        for (id, target) in removes {
            guard let stored = try storedEntry(db, id: id), let timing = projection.timings[id] ?? stored.timing else {
                continue
            }
            let laps = try book.info(stored.topicId, stored.version).timer?.laps
            projection.timings[id] = removing(target, from: timing, laps: laps)
        }
        return projection
    }

    /// `timing` with the pause or lap boundary `target` removed (timers2.md §3.4, §6.5): a removed
    /// pause's time becomes active; a removed lap boundary joins its segment to the one before,
    /// and later laps renumber (and so may change type, §3.2). Without the lap types (`laps` nil),
    /// typed laps keep their labels. A target that isn't in the timing changes nothing (the server
    /// answers `no_target`).
    static func removing(_ target: String, from timing: Timing, laps: [TopicTimer.LapType]?) -> Timing {
        var result = timing
        if let pause = timing.pauses.first(where: { $0.id?.lowercased() == target }) {
            result.segments = timing.segments.map { segment in
                let covered = max(0, min(segment.endedAt, pause.end) - max(segment.startedAt, pause.start))
                guard covered > 0 else { return segment }
                var segment = segment
                segment.activeMs += covered
                segment.pausedMs -= covered
                return segment
            }
            result.activeMs += pause.end - pause.start
            result.pausedMs -= pause.end - pause.start
            result.pauses.removeAll { $0 == pause }
            return result
        }
        guard
            let at = timing.segments.indices.first(where: { index in
                index > 0 && timing.segments[index].openedBy == .lap
                    && timing.segments[index].eventId?.lowercased() == target
            })
        else { return timing }
        var merged = timing.segments[at - 1]
        let removed = timing.segments[at]
        merged.endedAt = removed.endedAt
        merged.activeMs += removed.activeMs
        merged.pausedMs += removed.pausedMs
        var joined = timing.segments
        joined.replaceSubrange((at - 1)...at, with: [merged])
        if laps == nil, joined.contains(where: { $0.kind == .lap && $0.lapType != nil }) {
            result.segments = joined
            return result
        }
        var n = 0
        result.segments = joined.map { segment in
            guard segment.kind == .lap else { return segment }
            n += 1
            var segment = segment
            (segment.lapType, segment.label) = RunFold.lapTyping(n, laps ?? [])
            return segment
        }
        return result
    }

    // MARK: - resumable, the store's half

    /// Whether the entry's run is offered "Resume run" on tiles, toasts and the run screen
    /// (timers2.md glossary, OQ-1, A15): `RunPresentation.resumable` (an unedited timed entry
    /// within 15 minutes of its stop), the entry is the topic's latest stop (no later timed entry,
    /// and no later stop of a run still here: a finishing run has no entry yet), and the topic
    /// has no locally open run (a reopen would be refused with 409 `conflict`), the entry's own
    /// run included (already reopened here).
    public static func resumable(_ db: Database, entryId: String, now: Date) throws -> Bool {
        guard let viewEntry = try StoreView.entry(db, id: entryId.lowercased()),
            let end = viewEntry.entry.timing?.endedAt, RunPresentation.resumable(viewEntry.entry, now: now)
        else { return false }
        let id = viewEntry.entry.id
        let topicId = viewEntry.entry.topicId.wireString
        let runs = try localRuns(db, topicId: topicId)
        if runs.contains(where: { $0.isOpen || ($0.answers(to: entryId) && $0.status == .finishing) }) {
            return false
        }
        func later(_ otherId: String, _ otherEnd: Int) -> Bool {
            (otherEnd, otherId) > (end, id.wireString)
        }
        if runs.contains(where: { run in
            !run.answers(to: entryId) && run.status != .discarded && run.state.endedAt.map { later(run.id, $0) } == true
        }) {
            return false
        }
        return try !StoreView.entries(db, topicId: topicId).contains { view in
            view.entry.id != id && view.entry.timing.map { later(view.entry.id.wireString, $0.endedAt) } == true
        }
    }
}
