import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// Ordering between runs (timers.md §8.1, review H1 and M1), and one case for each rule a review
/// mutation showed untested.
@Suite(.timeLimit(.minutes(5))) struct RunReviewTests {
    static func isEvent(_ request: HTTPRequest) -> Bool { request.url.path.hasSuffix("/events") }

    static func type(_ request: HTTPRequest) -> String? { request.json?["type"] as? String }

    static func sent(_ h: OutboxHarness) -> [String] { h.server.requests.filter(isEvent).compactMap(type) }

    static func unavailable(_ h: OutboxHarness, _ type: String) {
        h.server.inject(
            where: { isEvent($0) && Self.type($0) == type }, .respond(header(FakeServer.problem(503, "unavailable"))))
    }

    // MARK: - A start waits for the topic's earlier active stop or discard (H1)

    @Test("H1 · a new start waits for the previous run's retrying stop, so it isn't merged into that run")
    func startWaitsForARetryingStop() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let r2 = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        h.wall.advance(by: 60)
        _ = try await writes.stop(runId: r2)
        Self.unavailable(h, "stop")
        _ = try await h.outbox().flushNow()  // the stop is uncertain, waiting for its backoff
        h.wall.advance(by: 5)
        let r3 = try await writes.start(topic: h.ref, version: 1)
        #expect(r3.started)
        _ = try await h.outbox().flushNow(force: false)
        #expect(Self.sent(h) == ["start", "stop"], "the new start waits")
        _ = try await h.outbox().flushNow()  // the stop goes through, then the start
        #expect(Self.sent(h) == ["start", "stop", "stop", "start"])
        let merged: String? = h.server.with { $0.runAliases[r3.runId] }
        #expect(merged == nil)
        let created = try #require(h.server.run(r3.runId))
        #expect(created.id == r3.runId)
    }

    @Test("H1 · a stop in flight (in another process) holds the topic's next start")
    func inFlightStopHolds() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let r2 = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        guard case .appended(let stop) = try await writes.stop(runId: r2) else {
            Issue.record("no stop")
            return
        }
        try h.write { db in
            try db.execute(sql: "UPDATE outbox_item SET state = 'in_flight' WHERE id = ?", arguments: [stop.id])
        }
        let r3 = try await writes.start(topic: h.ref, version: 1)
        #expect(r3.started)
        _ = try await h.outbox().flushNow()
        #expect(Self.sent(h) == ["start"])
        let held = try #require(try h.item(r3.runId))
        #expect(held.state == .pending)
    }

    @Test("H1 · an active discard of the previous run also holds the next start")
    func activeDiscardHolds() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let r2 = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        _ = try await writes.discard(runId: r2)
        Self.unavailable(h, "discard")
        _ = try await h.outbox().flushNow()
        let r3 = try await writes.start(topic: h.ref, version: 1)
        _ = try await h.outbox().flushNow(force: false)
        #expect(Self.sent(h) == ["start", "discard"])
        let held = try #require(try h.item(r3.runId))
        #expect(held.attempts == 0)
    }

    @Test("H1 · a failed stop doesn't hold the next start: it goes, and the server merges it if it must")
    func failedStopDoesNotHold() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let r2 = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        _ = try await writes.stop(runId: r2)
        let r3 = try await writes.start(topic: h.ref, version: 1)
        #expect(r3.started)
        h.server.inject(
            where: { Self.isEvent($0) && Self.type($0) == "stop" },
            .respond(header(FakeServer.problem(422, "run_too_long"))))
        _ = try await h.outbox().flushNow()
        #expect(Self.sent(h) == ["start", "stop", "start"], "once the stop failed, the start went")
        let merged: String? = h.server.with { $0.runAliases[r3.runId] }
        #expect(merged == r2, "into the run still open on the server")
    }

    @Test("H1 · a stop of a run whose start failed doesn't hold another run's start")
    func stopOfAFailedStartDoesNotHold() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let r2 = try await h.start(writes)
        _ = try await writes.stop(runId: r2)
        h.server.inject(
            where: { Self.isEvent($0) && Self.type($0) == "start" },
            .respond(header(FakeServer.problem(409, "topic_not_timed"))))
        _ = try await h.outbox().flushNow()
        #expect(Self.sent(h) == ["start"])
        let r3 = try await writes.start(topic: h.ref, version: 1)
        #expect(r3.started)
        _ = try await h.outbox().flushNow()
        #expect(Self.sent(h) == ["start", "start"])
        let created = try #require(h.server.run(r3.runId))
        #expect(created.status == .running)
    }

    // MARK: - Run ids resolve through aliases (M1)

    @Test("M1 · a finish after a merge waits for the stop that was sent to the alias")
    func finishWaitsForTheAliasStop() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let r1 = UUID().wireString
        let other = APIClient(
            baseURL: FakeServer.base, transport: h.server,
            identity: StaticServerIdentity(ServerIdentity(serverId: "server-1", epoch: "E1")), origin: .app)
        _ = try await other.recordRunEvent(
            runId: try #require(UUID(uuidString: r1)),
            RunEventInDTO(
                id: r1, type: "start", at: RunInstant.format(ms(-60)), topicId: h.topic.id.wireString, version: 1))
        let writes = h.runs()
        let r2 = try await h.start(writes)
        h.wall.advance(by: 30)
        _ = try await writes.stop(runId: r2)
        Self.unavailable(h, "stop")
        _ = try await h.outbox().flushNow()
        let run = try #require(try h.localRun(r2))
        #expect(run.id == r1)
        #expect(run.status == .finishing)
        let finish = try await writes.finish(runId: r2, answers: ["mood": .int(3)])
        #expect(finish != nil)
        _ = try await h.outbox().flushNow(force: false)
        #expect(!Self.sent(h).contains("finish"), "the finish waits for the stop")
        _ = try await h.outbox().flushNow()
        let last: String? = Self.sent(h).last
        #expect(last == "finish")
        let entry = try #require(h.server.run(r1)?.entry)
        let mood = try #require(entry.answers["mood"])
        #expect(mood == .int(3))
    }

    // MARK: - One case per surviving mutant (M2)

    @Test("M7 · K6 needs the run's own start in the queue: a discard of a server run is appended")
    func k6OnAServerRunKeepsTheDiscard() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let run = try h.seedServerRun()
        let writes = h.runs()
        _ = try await writes.next(runId: run.id.wireString)
        let result = try await writes.discard(runId: run.id.wireString)
        guard case .appended = result else {
            Issue.record("a discard of a server run must be appended: \(String(describing: result))")
            return
        }
    }

    @Test("M6 · K6 needs every item never attempted: a start retried after a 401 keeps its discard")
    func k6AfterARetriedStart() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.server.inject(where: Self.isEvent, .respond(header(FakeServer.problem(401, "unauthorized"))))
        _ = try await h.outbox().flushNow()
        let start = try #require(try h.item(runId))
        #expect(start.state == .pending)
        #expect(start.attempts == 1)
        let result = try await writes.discard(runId: runId)
        guard case .appended = result else {
            Issue.record("not appended: \(String(describing: result))")
            return
        }
    }

    @Test("M11 · an ack records the id the event was sent to as an alias, even if the run doesn't list it")
    func ackRecordsTheAlias() throws {
        let h = try OutboxHarness()
        try h.timed()
        let run = try h.seedServerRun()
        let sentTo = UUID()
        let result = RunEventResult(eventId: sentTo.wireString, effect: .void(.merged), run: run, entry: nil)
        try h.write { db in _ = try ServerLayer.apply(db, runEvent: result, sentTo: sentTo) }
        let stored = try h.read { db in try StoreView.run(db, id: sentTo.wireString) }
        let target = try #require(stored)
        #expect(target.id == run.id)
        let local = try #require(try h.localRun(sentTo.wireString))
        #expect(local.id == run.id.wireString)
    }

    @Test("M14 · a Resume shown for one pause is dropped once another pause is the open one")
    func resumeOfAnOlderPause() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.pause(runId: runId)
        let firstPause = RunTapExpect(try #require(try h.localRun(runId)))
        h.wall.advance(by: 10)
        _ = try await writes.resume(runId: runId)
        h.wall.advance(by: 10)
        _ = try await writes.pause(runId: runId)
        let stale = try await writes.resume(runId: runId, target: .expect(firstPause))
        #expect(stale == nil)
        let current = RunTapExpect(try #require(try h.localRun(runId)))
        let resumed = try await writes.resume(runId: runId, target: .expect(current))
        #expect(resumed != nil)
    }

    @Test("M16 · a Skip shown for one step is dropped once that step was skipped")
    func skipOfAnotherStep() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        let seen = RunTapExpect(try #require(try h.localRun(runId)))
        #expect(seen.step == "shower")
        let first = try await writes.skip(runId: runId, target: .expect(seen))
        #expect(first != nil)
        let second = try await writes.skip(runId: runId, target: .expect(seen))
        #expect(second == nil, "same segment, but the step it named is gone")
    }

    @Test("M15 · an optimistic entry gives way to a server row with the run's id")
    func optimisticEntryDedupesTheServerRow() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 60)
        _ = try await writes.stop(runId: runId)
        let id = try #require(UUID(uuidString: runId))
        try h.write { db in _ = try ServerLayer.upsert(db, entry: Make.entry(id: id, topicId: h.topic.id)) }
        let entries = try h.viewEntries()
        let only = try #require(entries.count == 1 ? entries.first : nil)
        #expect(only.syncState == .synced)
        let derived = try h.read { db in try StoreView.derived(db, topicId: h.topic.id.wireString) }
        let count = try #require(derived[h.topic.id.wireString]).entryCount
        #expect(count == 1)
    }

    @Test("M21 · a run whose pinned version isn't stored shows the server's state, not a fold over no steps")
    func unknownVersionKeepsTheServersLabels() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let server = try h.seedServerRun(version: 9)
        h.wall.advance(by: 30)
        _ = try await h.runs().pause(runId: server.id.wireString)
        let run = try #require(try h.localRun(server.id.wireString))
        #expect(run.steps == nil)
        let open = try #require(run.state.open)
        #expect(open.label == "Shower")
        #expect(open.kind == .step)
    }

    @Test("M23 · a stop carries its answers and notes; other taps carry none")
    func stopCarriesItsAnswers() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 60)
        guard case .appended(let stop) = try await writes.stop(runId: runId, answers: ["mood": .int(2)], notes: "n")
        else {
            Issue.record("no stop")
            return
        }
        let payload = try h.payload(stop)
        let mood = try #require(payload.event.answers?["mood"] ?? nil)
        #expect(mood.value == .int(2))
        let notes: String? = payload.event.notes
        #expect(notes == "n")
        let run = try #require(try h.localRun(runId))
        #expect(run.status == .stopped, "answers on the stop make the entry")
        let entry = try #require(try h.viewEntries().first)
        #expect(entry.entry.answers == ["mood": .int(2)])
    }

    @Test("M28 · the optimistic entry carries the last queued finish's answers")
    func optimisticEntryUsesTheLastFinish() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 60)
        _ = try await writes.stop(runId: runId)
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(3)])
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(5)])
        let entry = try #require(try h.viewEntries().first)
        #expect(entry.entry.answers == ["mood": .int(5)])
    }

    @Test("L1 · a Pause while paused enqueues nothing")
    func pauseWhilePaused() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let id = try await h.start(writes)
        _ = try await writes.pause(runId: id)
        let again = try await writes.pause(runId: id)
        #expect(again == nil)
    }

    @Test("L4 · Fix is offered for a 422 only, not for another refusal")
    func fixNeedsA422() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.stop(runId: runId)
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(4)])
        h.server.inject(
            where: { Self.isEvent($0) && Self.type($0) == "finish" },
            .respond(header(FakeServer.problem(409, "event_conflict"))))
        _ = try await h.outbox().flushNow()
        let finish = try #require(try h.runItems.last)
        #expect(finish.state == .failed)
        let payload = try h.payload(finish)
        await #expect(throws: OutboxError.self) {
            try await h.outbox().fix(itemId: finish.id, payload: .runEvent(payload), rowVersion: finish.rowVersion)
        }
    }

    // MARK: - Offsets (L3, M17)

    @Test("L3 · a sample within 5 ms of the stored offset writes nothing")
    func smallChangesAreNotWritten() async throws {
        let s = try TestStore()
        let recorder = StoreServerOffset(store: s.store)
        await recorder.record(offsetMs: 1_000)
        await recorder.record(offsetMs: 1_004)
        let kept = try #require(try await s.store.syncState.syncState())
        #expect(kept.serverOffsetMs == 1_000)
        await recorder.record(offsetMs: 1_006)
        let moved = try #require(try await s.store.syncState.syncState())
        #expect(moved.serverOffsetMs == 1_006)
    }

    final class Samples: ServerOffsetRecorder {
        let values = Mutex<[Int]>([])

        func record(offsetMs: Int) async { values.withLock { $0.append(offsetMs) } }

        var all: [Int] { values.withLock { $0 } }
    }

    @Test("L3 · a response with another server's or epoch's headers, or none, is no sample")
    func mismatchedIdentityIsNoSample() async throws {
        let transport = FakeTransport()
        let samples = Samples()
        let client = APIClient(
            baseURL: URL(string: "https://q.example")!, transport: transport,
            identity: StaticServerIdentity(ServerIdentity(serverId: "s", epoch: "e")), serverOffset: samples,
            deviceNow: { 1_000 })
        func response(_ serverId: String?, _ epoch: String?) -> HTTPResponse {
            var headers: HTTPHeaders = [RunClock.serverTimeHeader: "3000"]
            if let serverId { headers[QuickrHeader.serverId] = serverId }
            if let epoch { headers[QuickrHeader.epoch] = epoch }
            return HTTPResponse(status: 200, headers: headers, body: Data("{}".utf8))
        }
        transport.enqueue(.success(response("other", "e")))
        transport.enqueue(.success(response("s", "E2")))
        transport.enqueue(.success(response(nil, nil)))
        transport.enqueue(.success(response("S", "E")))  // the same identity, compared case-insensitively
        for _ in 0..<4 { _ = try await client.getRun(id: UUID()) }
        #expect(samples.all == [2_000])
    }

    /// Adds `X-QuickR-Server-Time` (the device clock + 60 s) to every response.
    struct TimedTransport: Transport {
        let inner: any Transport

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            var response = try await inner.send(request)
            response.headers[RunClock.serverTimeHeader] = String(RunInstant.milliseconds(Date()) + 60_000)
            return response
        }
    }

    @Test("M17 · the feed's pages are offset samples for the store being pulled")
    func feedRecordsTheOffset() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let transport = TimedTransport(inner: env.transport)
        let coordinator = env.coordinator(feed: { url in
            APIClient(baseURL: url, transport: transport, identity: StaticServerIdentity(nil))
        })
        let store = try await env.connect(coordinator)
        _ = await coordinator.sync(reason: .requested)
        let state = try #require(try await store.syncState.syncState())
        #expect(abs(state.serverOffsetMs - 60_000) < 5_000)
    }
}
