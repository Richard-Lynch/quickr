import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// R4 (timers.md §4.5, §8.3): the local view. A queued start is an open run at once; a queued
/// Next folds over the server's events; an alias response re-keys the local run; a queued stop
/// projects an optimistic entry; a start for a topic with a local open run enqueues nothing.
@Suite(.timeLimit(.minutes(5))) struct RunLocalViewTests {
    @Test("R4 · a queued start is an open run at once, offline")
    func queuedStartIsOpen() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let runId = try await h.start()
        let run = try #require(try h.localRun(runId))
        #expect(run.status == .running)
        #expect(run.server == nil)
        #expect(run.topic == h.ref)
        let open = try #require(run.state.open)
        #expect(open.label == "Shower")
        #expect(run.state.startedAt == ms())
        #expect(h.server.requests.isEmpty)
    }

    @Test("R4 · a queued Next folds over the server's events, in arrival order then outbox order")
    func queuedNextFoldsOverTheServer() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let server = try h.seedServerRun(events: [RunEvent(id: UUID().wireString, type: .next, at: ms(60), seg: 0)])
        h.wall.advance(by: 120)
        let result = try await h.runs().next(runId: server.id.wireString)
        #expect(result != nil)
        let run = try #require(try h.localRun(server.id.wireString))
        let open = try #require(run.state.open)
        #expect(open.index == 2)
        #expect(open.label == "Out")
        #expect(run.state.segments.map(\.label) == ["Shower", "Breakfast"])
        let stored = try #require(run.server?.state.open)
        #expect(stored.index == 1, "the server layer is unchanged")
    }

    @Test("R4 · a merged start's response re-keys the local run to the run it joined")
    func aliasRekeys() async throws {
        let h = try OutboxHarness()
        try h.timed()
        // Another device started R1 a minute ago; this one hasn't pulled it.
        let r1 = UUID().wireString
        let other = APIClient(
            baseURL: FakeServer.base, transport: h.server,
            identity: StaticServerIdentity(ServerIdentity(serverId: "server-1", epoch: "E1")), origin: .app)
        _ = try await other.recordRunEvent(
            runId: UUID(uuidString: r1)!,
            RunEventInDTO(
                id: r1, type: "start", at: RunInstant.format(ms(-60)), topicId: h.topic.id.wireString, version: 1))
        let writes = h.runs()
        let r2 = try await h.start(writes)
        _ = try await writes.next(runId: r2)
        let before = try h.localRuns()
        #expect(before.map(\.id) == [r2])

        h.server.inject(
            where: { $0.url.path.hasSuffix("/events") && $0.json?["type"] as? String == "next" },
            .respond(header(FakeServer.problem(503, "unavailable"))))
        _ = try await h.outbox().flushNow()
        let runs = try h.localRuns()
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.id == r1)
        #expect(run.aliases == [r2])
        #expect(run.state.startedAt == ms(-60), "R1's start is kept")
        let open = try #require(run.state.open)
        #expect(open.index == 1, "the queued Next sent to R2 folds into R1")
        let routed = try #require(try h.localRun(r2))
        #expect(routed.id == r1)

        _ = try await h.outbox().flushNow()
        let merged = try #require(h.server.run(r1)?.state.open)
        #expect(merged.index == 1)
        #expect(try h.runItems.isEmpty)
    }

    @Test("R4 · a queued stop projects an optimistic entry with the run's id until the server's replaces it")
    func optimisticEntry() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 90)
        _ = try await writes.next(runId: runId)
        h.wall.advance(by: 30)
        _ = try await writes.stop(runId: runId)
        let run = try #require(try h.localRun(runId))
        #expect(run.status == .stopped)

        let entries = try h.viewEntries()
        let entry = try #require(entries.only)
        #expect(entry.entry.id.wireString == runId)
        #expect(entry.syncState == .pending)
        #expect(entry.entry.capturedAt == Make.t0.addingTimeInterval(120))
        let timing = try #require(entry.entry.timing)
        #expect(timing.segments.map(\.activeMs) == [90_000, 30_000])
        let derived = try h.read { db in try StoreView.derived(db, topicId: h.topic.id.wireString) }
        let count = try #require(derived[h.topic.id.wireString]).entryCount
        #expect(count == 1)
        let last = try h.read { db in try StoreView.lastCapturedAt(db) }
        let lastCaptured = try #require(last[h.topic.id.wireString])
        #expect(lastCaptured == Make.t0.addingTimeInterval(120))

        _ = try await h.outbox().flushNow()
        let synced = try h.viewEntries()
        let replaced = try #require(synced.only)
        #expect(replaced.syncState == .synced)
        let replacedTiming = try #require(replaced.entry.timing)
        #expect(replacedTiming == timing)
        let gone = try h.localRun(runId)
        #expect(gone == nil)
    }

    @Test("R4 · a stop that leaves the run finishing projects nothing; its finish projects the entry")
    func finishingProjectsNothing() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 60)
        _ = try await writes.stop(runId: runId)
        let run = try #require(try h.localRun(runId))
        #expect(run.status == .finishing)
        #expect(try h.viewEntries().isEmpty)

        _ = try await h.outbox().flushNow()
        let finishing = try #require(try h.localRun(runId))
        #expect(finishing.status == .finishing)
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(4)], notes: "fine")
        let entry = try #require(try h.viewEntries().only)
        #expect(entry.entry.answers == ["mood": .int(4)])
        #expect(entry.entry.notes == "fine")
        #expect(entry.syncState == .pending)
        _ = try await h.outbox().flushNow()
        let saved = try #require(try h.viewEntries().only)
        #expect(saved.syncState == .synced)
        #expect(saved.entry.answers == ["mood": .int(4)])
    }

    @Test("R4 · a start for a topic with an open local run enqueues nothing and routes to it")
    func noSecondStart() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let first = try await writes.start(topic: h.ref, version: 1)
        let second = try await writes.start(topic: h.ref, version: 1)
        #expect(first.started)
        #expect(!second.started)
        #expect(second.runId == first.runId)
        #expect(try h.runItems.count == 1)

        // A reminder's Start (a given id) also routes to the open run.
        let reminder = try await writes.start(topic: h.ref, version: 1, id: UUID())
        #expect(reminder.runId == first.runId)
        #expect(!reminder.started)

        // Once the run is stopped here, a new start is a new run.
        _ = try await writes.stop(runId: first.runId)
        let third = try await writes.start(topic: h.ref, version: 1)
        #expect(third.started)
    }

    @Test("R4 · a reminder's Start whose id is known (queued, failed, on the server or closed) writes nothing")
    func knownIds() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let id = UUID()
        h.server.inject(
            where: { $0.url.path.hasSuffix("/events") }, .respond(header(FakeServer.problem(409, "topic_not_timed"))))
        let first = try await writes.start(topic: h.ref, version: 1, id: id)
        #expect(first.started)
        _ = try await h.outbox().flushNow()
        #expect(try h.item(id)?.state == .failed)
        #expect(try h.localRuns().isEmpty, "a failed start makes no open run")
        let again = try await writes.start(topic: h.ref, version: 1, id: id)
        #expect(!again.started, "but its id is known")
        let fresh = try await writes.start(topic: h.ref, version: 1)
        #expect(fresh.started, "and a start with a new id is allowed")

        let closed = UUID()
        try h.write { db in
            try ServerLayer.applyDeletion(db, kind: .run, id: closed, topicId: h.topic.id, seq: nil)
        }
        _ = try await writes.stop(runId: fresh.runId)
        let tombstoned = try await writes.start(topic: h.ref, version: 1, id: closed)
        #expect(!tombstoned.started)
    }

    @Test("R4 · a start of a version not stored here folds over no steps: it still shows its clock")
    func unknownSteps() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let result = try await h.runs().start(topic: h.ref, version: 7)
        let run = try #require(try h.localRun(result.runId))
        #expect(run.steps == nil)
        #expect(run.requiresAnswers == nil)
        #expect(run.status == .running)
        let open = try #require(run.state.open)
        #expect(open.kind == .lap)
        #expect(run.state.startedAt == ms())
        h.wall.advance(by: 10)
        let stop = try await h.runs().stop(runId: result.runId)
        #expect(stop != nil, "it can be stopped offline")
        #expect(try h.viewEntries().isEmpty, "with no steps known, no optimistic entry")
    }

    @Test("R4 · the local view folds the run's pinned version's steps, never the topic's current ones")
    func pinnedVersion() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try h.timed(version: 2, steps: [TopicTimer.Step(key: "a", label: "A")])
        try h.write { db in try db.execute(sql: "UPDATE topic SET current_version = 2") }
        let server = try h.seedServerRun()
        h.wall.advance(by: 30)
        _ = try await h.runs().next(runId: server.id.wireString)
        let run = try #require(try h.localRun(server.id.wireString))
        #expect(run.version == 1)
        #expect(run.state.segments.map(\.label) == ["Shower"])
        let open = try #require(run.state.open)
        #expect(open.label == "Breakfast")
    }

    @Test("R4 · a double tap: with the screen's expectation the second Next is dropped; as shown, both queue")
    func doubleTaps() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        let seen = RunTapExpect(try #require(try h.localRun(runId)))
        let first = try await writes.next(runId: runId, target: .expect(seen))
        let second = try await writes.next(runId: runId, target: .expect(seen))
        #expect(first != nil)
        #expect(second == nil)
        let paused = try await writes.pause(runId: runId, target: .expect(seen))
        #expect(paused != nil)
        let again = try await writes.pause(runId: runId, target: .expect(seen))
        #expect(again == nil)
        let pausedView = RunTapExpect(try #require(try h.localRun(runId)))
        let resumed = try await writes.resume(runId: runId, target: .expect(pausedView))
        #expect(resumed != nil)
        let resumedTwice = try await writes.resume(runId: runId, target: .expect(pausedView))
        #expect(resumedTwice == nil)

        // A Live Activity's Next sends the segment it showed, whatever the view says now.
        let shown = try await writes.next(runId: runId, target: .shown(seg: 0, step: nil, pauseId: nil))
        let item = try #require(
            shown.flatMap { result -> OutboxItem? in
                if case .appended(let item) = result { return item }
                return nil
            })
        let seg = try #require(try h.payload(item).event.seg)
        #expect(seg == 0)
        let run = try #require(try h.localRun(runId))
        let effect = try #require(run.state.effects[item.id])
        #expect(effect == .void(.stale))
    }

    @Test("R4 · Auto: idle → Start; a named step remains → Next; on the last step → Stop")
    func auto() async throws {
        let h = try OutboxHarness()
        try h.timed(steps: Array(OutboxHarness.steps.prefix(2)))
        let writes = h.runs()
        guard case .started(let start) = try await writes.auto(topic: h.ref, version: 1) else {
            Issue.record("not started")
            return
        }
        #expect(start.started)
        guard case .tapped(let next, _, _) = try await writes.auto(topic: h.ref, version: 1) else {
            Issue.record("not tapped")
            return
        }
        #expect(next == .next)
        guard case .tapped(let stop, _, _) = try await writes.auto(topic: h.ref, version: 1) else {
            Issue.record("not tapped")
            return
        }
        #expect(stop == .stop)
        let run = try #require(try h.localRun(start.runId))
        #expect(run.status == .stopped)
    }

    @Test("R12 · the tap's time is read at the tap, not after waiting for the store's write lock")
    func tapTimeIsReadAtTheTap() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let runId = try await h.start()
        let other = try StoreDatabase.openPool(at: h.url)
        // Another process holds the write lock, on a thread of its own (never a cooperative one).
        let held = Mutex(false)
        let finished = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            try? other.write { _ in
                held.withLock { $0 = true }
                release.wait()
            }
            finished.withLock { $0 = true }
        }
        holder.start()
        while !held.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        h.wall.advance(by: 5)
        let tap = Task { try await h.runs().next(runId: runId) }
        try await Task.sleep(for: .milliseconds(200))
        h.wall.advance(by: 55)  // the lock is held a minute; the tap was at +5 s
        release.signal()
        while !finished.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let result = try await tap.value
        guard case .appended(let item) = result else {
            Issue.record("not appended: \(String(describing: result))")
            return
        }
        let at = try h.at(item)
        #expect(at == ms(5))
    }
}

extension Array {
    /// The single element, or nil.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
