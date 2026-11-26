import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

// The entry detail's Remove and Resume run (content-display.md §3.2), and OQ-14's hidden rule,
// over a real session and store (offline: everything queues). `EntryActionsModel` goes through
// `RunActions` and the real `RunWrites`; a recording writer in between counts the taps.
extension EntriesModelTests {
    nonisolated static let intervalsId = UUID(uuidString: "00000000-0000-4000-8000-0000000000cc")!
    nonisolated static let intervalTimer = TopicTimer(
        steps: [], laps: [.init(key: "run", label: "Run"), .init(key: "rest", label: "Rest")])
    nonisolated static let lapEvent = "0e000000-0000-4000-8000-000000000001"
    nonisolated static let nextLapEvent = "0e000000-0000-4000-8000-000000000002"
    nonisolated static let pauseEvent = "0e000000-0000-4000-8000-000000000003"
    nonisolated static let terminal = "0e000000-0000-4000-8000-000000000004"

    /// Run 1 (opened by the start), Rest 1 (a `lap`, `lapEvent`), Run 2 (as if a `next` opened it:
    /// `nextLapEvent`), a pause `pauseEvent` inside Rest 1, stopped by `terminal`. An hour ago.
    nonisolated static func intervalsTiming(edited: Bool = false) -> Timing {
        let start = RunInstant.milliseconds(now.addingTimeInterval(-3_600))
        func lap(
            _ label: String, _ type: String, _ a: Int, _ b: Int, _ event: String?, _ by: RunOpenedBy, paused: Int = 0
        )
            -> RunSegment
        {
            RunSegment(
                kind: .lap, step: nil, label: label, startedAt: start + a, endedAt: start + b,
                activeMs: b - a - paused, pausedMs: paused, lapType: type, eventId: event, openedBy: by)
        }
        return Timing(
            startedAt: start, endedAt: start + 300_000, activeMs: 290_000, pausedMs: 10_000, complete: true,
            edited: edited,
            segments: [
                lap("Run 1", "run", 0, 100_000, nil, .start),
                lap("Rest 1", "rest", 100_000, 200_000, lapEvent, .lap, paused: 10_000),
                lap("Run 2", "run", 200_000, 300_000, nextLapEvent, .next),
            ],
            skipped: [], pauses: [RunPause(start: start + 150_000, end: start + 160_000, id: pauseEvent)],
            terminalId: terminal)
    }

    /// Entry 31 is the intervals run above; entry 32 the same, edited.
    nonisolated static func seedIntervals(_ store: LocalStore) async throws {
        let topic = Topic(
            id: intervalsId, slug: "intervals", name: "Intervals", currentVersion: 1, revision: 1, questionCount: 1,
            createdAt: now.addingTimeInterval(-86_400 * 100), updatedAt: now.addingTimeInterval(-86_400 * 100),
            timer: intervalTimer, questions: [effort])
        @Sendable func entry(_ n: Int, _ timing: Timing, capturedAt: Date) -> Entry {
            Entry(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, topicId: intervalsId,
                version: 1, revision: 1, source: "ios", channel: .ios, capturedAt: capturedAt, createdAt: capturedAt,
                updatedAt: capturedAt, answers: [:], timing: timing)
        }
        let timing = intervalsTiming()
        try await store.writer.write { db in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.insert(
                db, version: TopicVersion(version: 1, questions: [effort], timer: intervalTimer, createdAt: now),
                id: UUID(), topicId: intervalsId)
            _ = try ServerLayer.upsert(db, entry: entry(31, timing, capturedAt: RunInstant.date(timing.endedAt)))
            _ = try ServerLayer.upsert(
                db, entry: entry(32, intervalsTiming(edited: true), capturedAt: now.addingTimeInterval(-7_200)))
        }
    }

    nonisolated static func entryId(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    /// `RunActions` over the store's `RunWrites`, recording each tap (type, run id, target).
    final class Recorder: Sendable {
        let taps = Mutex<[(RunTapType, String, RunTapTarget)]>([])

        @MainActor func actions(_ store: LocalStore) -> RunActions {
            let writes = RunWrites(store: store, origin: .app)
            return RunActions(
                writer: {
                    RunActions.Writer(
                        start: { topic, version in try await writes.start(topic: topic, version: version) },
                        tap: { [self] type, runId, target in
                            self.taps.withLock { $0.append((type, runId, target)) }
                            return try await writes.tap(type, runId: runId, target: target)
                        })
                }, cooldown: .zero)
        }

        var count: Int { taps.withLock { $0.count } }
    }

    /// The run events queued, as (type, target).
    static func queued(_ store: LocalStore) async throws -> [(RunEventType?, String?)] {
        try await store.outbox.items().compactMap { item in
            try item.runEventPayload().map { ($0.type, $0.event.target) }
        }
    }

    @MainActor func actionsModel(_ w: World, _ n: Int, recorder: Recorder) async throws
        -> (EntryActionsModel, Task<Void, Never>)
    {
        let store = try #require(w.session.store)
        let found = try await store.entries.entry(id: Self.entryId(n))
        let viewEntry = try #require(found)
        let model = EntryActionsModel(
            entry: viewEntry, store: store, refresh: w.session.refresh, runActions: recorder.actions(store))
        let observing = Task { await model.observe() }
        try await eventually("the runs are read") { await MainActor.run { model.runsRead } }
        return (model, observing)
    }

    // MARK: - Tests

    /// Remove on a lap sends `remove` once, targeting `segments[i].event_id`; on a pause,
    /// `pauses[j].id`. While queued the entry stays, its timing re-projected and pending (A14).
    @Test func removeTargetsTheRowsOwnIds() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedIntervals(store)
        let recorder = Recorder()
        let (model, observing) = try await actionsModel(w, 31, recorder: recorder)
        defer { observing.cancel() }

        let rows = EntryTimingModel.rows(try #require(model.entry.entry.timing))
        let lap = try #require(model.removeAction(rows[1]))  // s0, s1, p0, s2
        #expect(lap.target == Self.lapEvent && lap.enabled && lap.identifier == "entry.timing.remove.1")
        #expect(await model.remove(lap))
        #expect(recorder.count == 1, "one tap")
        #expect(try await Self.queued(store).map(\.0) == [.remove])
        #expect(try await Self.queued(store).map(\.1) == [Self.lapEvent])

        // The store's view: the entry stays, Rest 1 merged into Run 1, pending, same revision.
        try await eventually("the entry is re-projected") {
            try await store.entries.entry(id: Self.entryId(31))?.entry.timing?.segments.count == 2
        }
        let read = try await store.entries.entry(id: Self.entryId(31))
        let projected = try #require(read)
        #expect(projected.syncState == .pending && projected.entry.revision == 1)
        model.entryChanged(projected)
        #expect(model.isPending)
        #expect(!model.offersResume(now: Self.now), "a pending entry offers no Resume")

        // A pause's remove targets its id.
        let reprojected = try #require(model.entry.entry.timing)
        let pause = try #require(
            EntryTimingModel.rows(reprojected).compactMap(model.removeAction)
                .first { $0.identifier.hasPrefix("entry.timing.pause.") })
        #expect(pause.target == Self.pauseEvent && pause.identifier == "entry.timing.pause.remove.0")
        #expect(await model.remove(pause))
        #expect(try await Self.queued(store).map(\.1) == [Self.lapEvent, Self.pauseEvent])
        #expect(recorder.count == 2)
    }

    /// The lap a `next` opened has Remove, disabled: nothing is sent (its remove is `no_target`).
    @Test func removeIsDisabledOnANextOpenedLap() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedIntervals(store)
        let recorder = Recorder()
        let (model, observing) = try await actionsModel(w, 31, recorder: recorder)
        defer { observing.cancel() }

        let rows = EntryTimingModel.rows(try #require(model.entry.entry.timing))
        #expect(model.removeAction(rows[0]) == nil, "never the first segment")
        let next = try #require(model.removeAction(rows[3]))
        #expect(!next.enabled && next.target == Self.nextLapEvent && next.identifier == "entry.timing.remove.2")
        #expect(await model.remove(next) == false)
        #expect(recorder.count == 0)
        #expect(try await Self.queued(store).isEmpty)
    }

    /// Resume run sends `reopen` with the entry's `terminal_id`; the store then projects the run
    /// "resuming" and hides the entry (OQ-14): the list leaves it out, and the detail's model says
    /// it is open here (the route goes to the run). A revert shows it again.
    @Test func resumeReopensFromTheTerminalAndHidesTheEntry() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedIntervals(store)
        let (list, listing) = try await w.model("intervals")
        defer { listing.cancel() }
        #expect(Self.ids(list.rows) == [31, 32])
        let recorder = Recorder()
        let (model, observing) = try await actionsModel(w, 31, recorder: recorder)
        defer { observing.cancel() }

        #expect(model.offersResume(now: Self.now))
        #expect(await model.resume(now: Self.now))
        #expect(recorder.count == 1)
        #expect(try await Self.queued(store).map(\.0) == [.reopen])
        #expect(try await Self.queued(store).map(\.1) == [Self.terminal])

        w.session.refresh.poke()
        try await eventually("the run represents the entry") { await MainActor.run { model.isOpenHere } }
        try await eventually("the list hides it") { await MainActor.run { Self.ids(list.rows) == [32] } }
        #expect(model.topicHasLocalRun)
        #expect(!model.offersResume(now: Self.now), "A15: hidden while the topic has a local open run")
        let local = try await store.runs.localRun(id: Self.entryId(31))
        let run = try #require(local)
        #expect(run.resuming, "\"Resuming…\" until the ack")
        // The detail route still finds the entry (so it can redirect to the run).
        let detail = try await store.entries.entry(id: Self.entryId(31))
        #expect(detail?.entry.id == Self.entryId(31))

        // Revert (the resuming run's discard): the entry is shown again.
        _ = try await RunWrites(store: store, origin: .app).discard(runId: run.id)
        w.session.refresh.poke()
        try await eventually("the entry is back") { await MainActor.run { Self.ids(list.rows) == [31, 32] } }
        try await eventually("not open here") { await MainActor.run { !model.isOpenHere } }
    }

    /// An edited entry offers neither Remove nor Resume run (timers2.md §3.6), and sends nothing.
    @Test func neitherOnAnEditedEntry() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedIntervals(store)
        let recorder = Recorder()
        let (model, observing) = try await actionsModel(w, 32, recorder: recorder)
        defer { observing.cancel() }

        let timing = try #require(model.entry.entry.timing)
        #expect(EntryTimingModel.rows(timing).compactMap(model.removeAction).isEmpty)
        #expect(!model.offersResume(now: Self.now))
        #expect(await model.resume(now: Self.now) == false)
        // A forged Remove of an edited timing's lap isn't sent either.
        let forged = EntryTimingModel.Remove(
            target: Self.lapEvent, enabled: true, title: "", message: "", identifier: "")
        #expect(await model.remove(forged) == false)
        #expect(recorder.count == 0)
        #expect(try await Self.queued(store).isEmpty)
    }

    /// A15: another run of the topic open here hides Resume run on an entry.
    @Test func resumeIsHiddenWhileTheTopicHasALocalRun() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedIntervals(store)
        let recorder = Recorder()
        let (model, observing) = try await actionsModel(w, 31, recorder: recorder)
        defer { observing.cancel() }
        #expect(model.offersResume(now: Self.now))

        _ = try await RunWrites(store: store, origin: .app)
            .start(topic: TopicRef(id: Self.intervalsId, slug: "intervals", name: "Intervals"), version: 1)
        w.session.refresh.poke()
        try await eventually("the open run is seen") { await MainActor.run { model.topicHasLocalRun } }
        #expect(!model.offersResume(now: Self.now))
        #expect(!model.isOpenHere, "another run: the entry itself isn't open")
        #expect(await model.resume(now: Self.now) == false)
        #expect(recorder.count == 0)
    }

    /// OQ-14 whoever queued the reopen (here another surface's Resume, straight through the
    /// façade): the list has no row for the entry, pinned or not, while its run is open here.
    @Test func theHiddenRuleCoversAnOpenRunsEntry() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedIntervals(store)
        let (list, listing) = try await w.model("intervals")
        defer { listing.cancel() }
        #expect(Self.ids(list.rows) == [31, 32])

        _ = try await RunWrites(store: store, origin: .app).reopen(runId: Self.entryId(31).wireString)
        w.session.refresh.poke()
        try await eventually("the list hides it") { await MainActor.run { Self.ids(list.rows) == [32] } }
        #expect(list.pinned.isEmpty, "not pinned either: the run represents it")
    }
}
