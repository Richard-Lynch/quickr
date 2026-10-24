import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// R3 (timers.md §8.1): the `run.event` kind. It waits only for its run's start (and its topic's
/// `topic.*` items); a failed Next doesn't block Stop; K6 drops a never-sent run at its discard;
/// the classification table; the atomic ack.
@Suite(.timeLimit(.minutes(5))) struct RunOutboxTests {
    static func isEvent(_ request: HTTPRequest) -> Bool { request.url.path.hasSuffix("/events") }

    static func type(_ request: HTTPRequest) -> String? { request.json?["type"] as? String }

    // MARK: Ordering

    @Test("R3 · a failed start blocks its run's events; discarding it discards them, and nothing else waits")
    func failedStartBlocksItsRun() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.next(runId: runId)
        let entry = try await h.log(h.outbox())
        h.server.inject(where: Self.isEvent, .respond(header(FakeServer.problem(409, "topic_not_timed"))))
        let report = try await h.outbox().flushNow()
        #expect(report.failed == 1)
        let types = h.server.requests.filter(Self.isEvent).compactMap(Self.type)
        #expect(types == ["start"], "the Next waits behind its failed start")
        #expect(h.server.entry(entry) != nil, "an entry of the topic doesn't wait for a run")
        let summary = try await h.outbox().summary()
        #expect(summary.blocked == 1)

        try await h.outbox().discard(itemId: runId, origin: .app)
        let left = try h.runItems
        #expect(left.isEmpty)
    }

    @Test("R3 · run events don't wait for each other: a failed Next doesn't block Stop")
    func failedNextDoesNotBlockStop() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.wall.advance(by: 60)
        _ = try await writes.next(runId: runId)
        h.wall.advance(by: 60)
        _ = try await writes.stop(runId: runId)
        h.server.inject(
            where: { Self.isEvent($0) && Self.type($0) == "next" },
            .respond(header(FakeServer.problem(422, "run_too_many_events"))))
        let report = try await h.outbox().flushNow()
        #expect(report.acked == 2)
        #expect(report.failed == 1)
        let failed = try h.runItems
        #expect(failed.map(\.state) == [.failed])
        let stopped = try #require(h.server.run(runId))
        #expect(stopped.status == .stopped)
        // The stopped run's entry is in the server layer, from the stop's answer.
        let entryId = try #require(UUID(uuidString: runId))
        let entry = try #require(try h.view(entryId))
        #expect(entry.syncState == .synced)
        let segments = entry.entry.timing?.segments.count
        #expect(segments == 1)
    }

    @Test("R3 · a finish waits for its run's active stop, and goes once a failed stop no longer holds it")
    func finishWaitsForTheStop() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        h.wall.advance(by: 60)
        _ = try await writes.stop(runId: runId)
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(4)])
        h.server.inject(where: Self.isEvent, .respond(header(FakeServer.problem(503, "unavailable"))))
        _ = try await h.outbox().flushNow()
        let sent = h.server.requests.filter(Self.isEvent).compactMap(Self.type)
        #expect(sent == ["start", "stop"], "the finish waits while its stop is retried")

        // The stop is refused for good: the finish goes, and fails on `run_open` with its answers.
        h.server.inject(
            where: { Self.isEvent($0) && Self.type($0) == "stop" },
            .respond(header(FakeServer.problem(422, "run_too_long"))))
        _ = try await h.outbox().flushNow()
        let items = try h.runItems
        #expect(items.map(\.state) == [.failed, .failed])
        let finish = try #require(items.last)
        let payload = try h.payload(finish)
        #expect(payload.type == .finish)
        let mood = try #require(payload.event.answers?["mood"] ?? nil)
        #expect(mood.value == .int(4))
        let error = try #require(try finish.errorInfo)
        #expect(error.status == 409)
    }

    @Test("R3 · a run's events wait for an earlier topic item of their topic")
    func eventsWaitForTopicItems() async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await h.outbox().archiveTopic(id: h.topic.id, origin: .app)
        let runId = try await h.start()
        h.server.inject(.post, .respond(header(FakeServer.problem(503, "unavailable"))))
        _ = try await h.outbox().flushNow()
        #expect(h.server.requests.filter(Self.isEvent).isEmpty)
        #expect(try h.item(runId)?.state == .pending)
    }

    // MARK: K6

    @Test("R3 · K6: a discard of a run never sent drops the run's items and sends nothing")
    func k6DropsAnUnsentRun() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.next(runId: runId)
        _ = try await writes.pause(runId: runId)
        let result = try await writes.discard(runId: runId)
        #expect(result == .cancelled)
        #expect(try h.runItems.isEmpty)
        _ = try await h.outbox().flushNow()
        #expect(h.server.requests.isEmpty)
        #expect(try h.localRuns().isEmpty)
    }

    @Test("R3 · K6 needs every item never attempted: after the start was sent, the discard is appended")
    func k6KeepsASentRun() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        h.server.inject(where: Self.isEvent, .lose(.timedOut(requestStarted: true)))
        _ = try await h.outbox().flushNow()
        let result = try await writes.discard(runId: runId)
        guard case .appended = result else {
            Issue.record("not appended: \(String(describing: result))")
            return
        }
        _ = try await h.outbox().flushNow()
        let run = try #require(h.server.run(runId))
        #expect(run.status == .discarded)
        #expect(try h.runItems.isEmpty)
        #expect(try h.read { db in try ServerLayer.isTombstoned(db, kind: .run, id: runId) })
    }

    // MARK: Classification (§8.1)

    static let rows: [(name: String, outcome: APIOutcome<OutboxSuccess>, start: Bool, expected: OutboxResolution)] = [
        ("404, not a start", .notFound(nil), false, .fail(.deletedElsewhere, pull: true)),
        ("404, a start (its topic)", .notFound(nil), true, .fail(.topicMissing, pull: true)),
        ("409 run_deleted", .terminal(status: 409, problem: problem("run_deleted")), false, .retire(pull: true)),
        (
            "409 topic_not_timed", .terminal(status: 409, problem: problem("topic_not_timed")), true,
            .fail(.rejected, pull: false)
        ),
        (
            "409 topic_archived", .terminal(status: 409, problem: problem("topic_archived")), true,
            .fail(.rejected, pull: false)
        ),
        (
            "409 id_conflict", .terminal(status: 409, problem: problem("id_conflict")), true,
            .fail(.rejected, pull: false)
        ),
        (
            "409 event_conflict", .terminal(status: 409, problem: problem("event_conflict")), false,
            .fail(.rejected, pull: false)
        ),
        ("409 run_open", .terminal(status: 409, problem: problem("run_open")), false, .fail(.rejected, pull: false)),
        ("422", .terminal(status: 422, problem: problem("invalid_request")), false, .fail(.rejected, pull: false)),
        ("409 entry_deleted", .entryDeleted(problem("entry_deleted")), false, .fail(.rejected, pull: false)),
        ("503", .uncertain(.serverError(status: 503, problem: nil)), false, .retry(maybeDelivered: true)),
    ]

    static func problem(_ code: String) -> Problem {
        Problem(code: ProblemCode(rawValue: code), detail: code, errors: [])
    }

    @Test("R3 · the classification table", arguments: rows.indices)
    func classification(_ index: Int) {
        let row = Self.rows[index]
        let resolution = OutboxResolution.resolve(.runEvent, row.outcome, runEvent: row.start ? .start : .next)
        #expect(resolution == row.expected, "\(row.name)")
    }

    @Test("R3 · a 404 fails a Next deleted_elsewhere and asks for a pull; run_deleted retires it")
    func goneRuns() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let run = try h.seedServerRun()
        let writes = h.runs()
        _ = try await writes.next(runId: run.id.wireString)
        _ = try await writes.lap(runId: run.id.wireString)
        _ = try await h.outbox().flushNow()  // the server never saw this run: 404s
        let failed = try h.runItems
        #expect(failed.map(\.failureReason) == [.deletedElsewhere, .deletedElsewhere])
        #expect(h.signals.contains(.pullRequested))

        let other = try OutboxHarness()
        try other.timed()
        let gone = try other.seedServerRun()
        other.server.with { $0.deletedRuns.insert(gone.id.wireString) }
        _ = try await other.runs().pause(runId: gone.id.wireString)
        let report = try await other.outbox().flushNow()
        #expect(report.settled == 1)
        #expect(try other.runItems.isEmpty)
    }

    // MARK: Ack

    @Test("R3 · ack: the run is stored with the response; a void Next is acked and reported")
    func ackStoresTheRun() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.next(runId: runId, target: .shown(seg: 0, step: nil, pauseId: nil))
        _ = try await writes.next(runId: runId, target: .shown(seg: 0, step: nil, pauseId: nil))  // a double tap
        let report = try await h.outbox().flushNow()
        #expect(report.acked == 3)
        #expect(report.runVoids.isEmpty, "stale is silent")
        #expect(try h.runItems.isEmpty)
        let stored = try #require(try h.read { db in try StoreView.run(db, id: runId) })
        let open = try #require(stored.state.open)
        #expect(open.index == 1)
        #expect(stored.revision == 3)

        // A Next after another device stopped the run: void after_stop, reported.
        h.wall.advance(by: 10)
        let stopAt = RunInstant.format(RunInstant.milliseconds(h.wall.now()))
        h.server.with { state in
            var run = state.runs[runId]!
            let stop = RunEvent(id: UUID().wireString, type: .stop, at: RunInstant.parse(stopAt)!)
            run.append(stop, RunEventInDTO(id: stop.id, type: "stop", at: stopAt))
            run.refold()
            state.runs[runId] = run
        }
        h.wall.advance(by: 30)
        _ = try await writes.next(runId: runId)
        let late = try await h.outbox().flushNow()
        let void = try #require(late.runVoids.only)
        #expect(void.reason == .afterStop)
        #expect(void.type == .next)
        // The stopped run left the run table (tombstoned) and its entry arrived with the answer.
        let closed = try h.read { db in try StoreView.run(db, id: runId) }
        #expect(closed == nil)
        let entryId = try #require(UUID(uuidString: runId))
        let entry = try h.view(entryId)
        #expect(entry != nil)
    }

    @Test("R3 · a run event's request: the item id is the event id, source is the origin's, device is stamped")
    func requestShape() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let device = RunEventInDTO.Device(apnsToken: "abcd", liveActivity: true)
        let writes = RunWrites(store: h.store, origin: .widget, device: { device })
        let runId = try await h.start(writes)
        _ = try await h.outbox().flushNow()
        let request = try #require(h.server.requests.first)
        #expect(request.url.path == "/api/v1/runs/\(runId)/events")
        let body = try #require(request.json)
        #expect(body["id"] as? String == runId)
        #expect(body["source"] as? String == "ios.widget")
        #expect(body["topic_id"] as? String == h.topic.id.wireString)
        let sentDevice = try #require(body["device"] as? [String: Any])
        #expect(sentDevice["apns_token"] as? String == "abcd")
        #expect(sentDevice["live_activity"] as? Bool == true)
        #expect(body["seg"] == nil)
    }

    // MARK: Tombstones (§7.2)

    @Test("R3 · a run tombstone keeps its queued events; a topic tombstone fails them deleted_elsewhere")
    func tombstones() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let run = try h.seedServerRun()
        _ = try await h.runs().next(runId: run.id.wireString)
        try h.applyTombstone(.run, id: run.id, topicId: h.topic.id)
        let kept = try h.runItems
        #expect(kept.map(\.state) == [.pending])
        try h.applyTombstone(.topic, id: h.topic.id, topicId: h.topic.id)
        let failed = try h.runItems
        #expect(failed.map(\.failureReason) == [.deletedElsewhere])
    }

    // MARK: Fix

    @Test("R3 · a refused finish offers Fix: only its answers and notes change")
    func fixAFinish() async throws {
        let h = try OutboxHarness()
        try h.timed(requiresAnswers: true)
        let writes = h.runs()
        let runId = try await h.start(writes)
        _ = try await writes.stop(runId: runId)
        _ = try await writes.finish(runId: runId, answers: ["mood": .int(9)])
        h.server.inject(
            where: { Self.isEvent($0) && Self.type($0) == "finish" },
            .respond(header(FakeServer.problem(422, "invalid_answers"))))
        _ = try await h.outbox().flushNow()
        let finish = try #require(try h.runItems.last)
        #expect(finish.state == .failed)
        var payload = try h.payload(finish)
        payload.event.answers = ["mood": WireAnswer(.int(4))]
        var moved = payload
        moved.event.at = RunInstant.format(0)
        await #expect(throws: OutboxError.self) {
            try await h.outbox().fix(itemId: finish.id, payload: .runEvent(moved), rowVersion: finish.rowVersion)
        }
        try await h.outbox().fix(itemId: finish.id, payload: .runEvent(payload), rowVersion: finish.rowVersion)
        _ = try await h.outbox().flushNow()
        let entry = try #require(h.server.run(runId)?.entry)
        #expect(entry.answers["mood"] == .int(4))
    }
}

extension Array {
    /// The single element, or nil.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
