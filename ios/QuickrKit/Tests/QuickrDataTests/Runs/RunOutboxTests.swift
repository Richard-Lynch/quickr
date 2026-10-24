import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

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
        // A start whose id the server knows is checked (started elsewhere, timers.md §10.2).
        ("409 id_conflict, a start", .terminal(status: 409, problem: problem("id_conflict")), true, .startKnown),
        ("409 event_conflict, a start", .terminal(status: 409, problem: problem("event_conflict")), true, .startKnown),
        (
            "409 event_conflict, not a start", .terminal(status: 409, problem: problem("event_conflict")), false,
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

    // MARK: A start the server already has (timers.md §10.2)

    /// Starts run `id` of `topic` on the fake server from "another device" (its own `at`).
    static func startElsewhere(_ h: OutboxHarness, id: UUID, topicId: UUID, at seconds: Double = -30) async throws {
        let body = RunEventInDTO(
            id: id.wireString, type: "start", at: RunInstant.format(ms(seconds)), topicId: topicId.wireString,
            version: 1, source: "pwa.notification")
        try await elsewhere(h, runId: id, body, status: 201)
    }

    /// Stops run `id` on the fake server from "another device".
    static func stopElsewhere(_ h: OutboxHarness, id: UUID, at seconds: Double) async throws {
        let body = RunEventInDTO(id: UUID().wireString, type: "stop", at: RunInstant.format(ms(seconds)))
        try await elsewhere(h, runId: id, body, status: 200)
    }

    static func elsewhere(_ h: OutboxHarness, runId: UUID, _ body: RunEventInDTO, status expected: Int) async throws {
        let client = APIClient(baseURL: FakeServer.base, transport: h.server, identity: StaticServerIdentity(nil))
        let response = try await client.recordRunEvent(
            runId: runId, body, options: RequestOptions(expecting: ServerIdentity(serverId: "server-1", epoch: "E1")))
        let status: Int? = response.status
        #expect(status == expected)
    }

    /// `response` as the server answers it: with its identity headers.
    static func fromServer(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        response.headers[QuickrHeader.serverId] = "server-1"
        response.headers[QuickrHeader.epoch] = "E1"
        return response
    }

    static func isRunRead(_ request: HTTPRequest) -> Bool {
        request.method == .get && request.url.path.contains("/runs/")
    }

    @Test(
        "R7 · a start already started elsewhere (event_conflict): acked with the server's run, pull; a Next follows it")
    func startStartedElsewhere() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let id = UUID()
        try await Self.startElsewhere(h, id: id, topicId: h.topic.id)

        let writes = h.runs(.notification)
        let started = try await writes.start(topic: h.ref, version: 1, id: id)
        #expect(started.started, "this store hasn't pulled the other start")
        _ = try await writes.next(runId: id.wireString)
        let report = try await h.outbox().flushNow()
        let acked: Int = report.acked
        let failed: Int = report.failed
        #expect(acked == 2)
        #expect(failed == 0)
        #expect(try h.runItems.isEmpty)
        #expect(h.signals.contains(.pullRequested))

        let server = try #require(h.server.run(id.wireString))
        let types: [RunEventType] = server.events.map(\.event.type)
        #expect(types == [.start, .next], "one start (the other device's); this store's Next")
        let local = try #require(try h.localRun(id.wireString))
        let open = try #require(local.state.open)
        #expect(open.index == 1, "the server's run is in the server layer")
    }

    @Test("R7 · a start whose id is another topic's run: fails rejected, the refusal kept")
    func startKnownForAnotherTopic() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let other = Make.topic(name: "Other")
        h.server.put(other)
        h.server.time(other.id, FakeTimer(steps: OutboxHarness.steps))
        let id = UUID()
        try await Self.startElsewhere(h, id: id, topicId: other.id)

        try await h.runs().start(topic: h.ref, version: 1, id: id)
        let report = try await h.outbox().flushNow()
        let failed: Int = report.failed
        #expect(failed == 1)
        let item = try #require(try h.item(id))
        let reason: OutboxFailureReason? = item.failureReason
        #expect(reason == .rejected)
        let error: String = item.lastErrorJSON ?? ""
        #expect(error.contains("event_conflict"), "\(error)")
    }

    @Test(
        "R7 · id_conflict: an entry of the start's topic settles the run's items (answers fail logged_elsewhere) and pulls; another topic's fails it"
    )
    func startIdIsAnEntry() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let mine = UUID()
        let theirs = UUID()
        h.server.put(Make.entry(id: mine, topicId: h.topic.id))
        h.server.put(Make.entry(id: theirs, topicId: UUID()))

        // A Next and a Stop with answers queued behind the start.
        let writes = h.runs()
        try await writes.start(topic: h.ref, version: 1, id: mine)
        _ = try #require(try await writes.next(runId: mine.wireString))
        _ = try #require(try await writes.stop(runId: mine.wireString, answers: ["mood": .int(3)]))
        let report = try await h.outbox().flushNow()
        let settled: Int = report.settled
        let requests: Int = report.requests
        #expect(settled == 1)
        #expect(requests == 3, "the start, its run read and its entry read; the taps never go")
        let left = try h.runItems
        let leftTypes: [String] = try left.map { try h.payload($0).event.type }
        #expect(leftTypes == ["next", "stop"], "the start went; the taps stay, failed, to discard")
        let reasons: [OutboxFailureReason?] = left.map(\.failureReason)
        #expect(reasons == [.loggedElsewhere, .loggedElsewhere])
        let messages: [String?] = left.map { $0.lastError?.message }
        #expect(messages == ["Already logged elsewhere", "Already logged elsewhere"])
        #expect(h.signals.contains(.pullRequested))

        try await h.runs().start(topic: h.ref, version: 1, id: theirs)
        let second = try await h.outbox().flushNow()
        let failed: Int = second.failed
        #expect(failed == 1)
        let item = try #require(try h.item(theirs))
        let reason: OutboxFailureReason? = item.failureReason
        #expect(reason == .rejected)
    }

    @Test("R7 · a 503 on the run read: the start retries, then acks with the run")
    func startKnownReadRetries() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let id = UUID()
        try await Self.startElsewhere(h, id: id, topicId: h.topic.id)
        h.server.inject(where: Self.isRunRead, .respond(Self.fromServer(FakeServer.problem(503, "unavailable"))))

        try await h.runs().start(topic: h.ref, version: 1, id: id)
        let first = try await h.outbox().flushNow()
        let retried: Int = first.retried
        #expect(retried == 1)
        let waiting = try #require(try h.item(id))
        let state: OutboxState = waiting.state
        #expect(state == .pending)
        #expect(!h.signals.contains(.pullRequested), "no ack, no pull")

        let second = try await h.outbox().flushNow()
        let acked: Int = second.acked
        #expect(acked == 1)
        #expect(try h.runItems.isEmpty)
        #expect(h.signals.contains(.pullRequested))
    }

    @Test("R7 · a terminal refusal of the run read fails the start rejected, with the read's error")
    func startKnownReadRefused() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let id = UUID()
        try await Self.startElsewhere(h, id: id, topicId: h.topic.id)
        h.server.inject(where: Self.isRunRead, .respond(Self.fromServer(FakeServer.problem(400, "invalid_request"))))

        try await h.runs().start(topic: h.ref, version: 1, id: id)
        let report = try await h.outbox().flushNow()
        let failed: Int = report.failed
        #expect(failed == 1)
        let item = try #require(try h.item(id))
        let reason: OutboxFailureReason? = item.failureReason
        #expect(reason == .rejected)
        let error: String = item.lastErrorJSON ?? ""
        #expect(error.contains("invalid_request"), "the read's error, as the PWA keeps: \(error)")
    }

    @Test("R7 · the start's id is an alias of the topic's run: a run_alias row, and the Next goes to that run")
    func startKnownAsAlias() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let first = UUID()
        let alias = UUID()
        try await Self.startElsewhere(h, id: first, topicId: h.topic.id, at: -40)
        try await Self.startElsewhere(h, id: alias, topicId: h.topic.id, at: -30)  // merged into `first`

        let writes = h.runs()
        try await writes.start(topic: h.ref, version: 1, id: alias)
        _ = try #require(try await writes.next(runId: alias.wireString))
        let report = try await h.outbox().flushNow()
        let acked: Int = report.acked
        #expect(acked == 2)
        let target: String? = try h.read { db in
            try String.fetchOne(db, sql: "SELECT run_id FROM run_alias WHERE id = ?", arguments: [alias.wireString])
        }
        #expect(target == first.wireString)
        let server = try #require(h.server.run(first.wireString))
        let types: [RunEventType] = server.events.map(\.event.type)
        #expect(types == [.start, .start, .next])
        let local = try #require(try h.localRun(alias.wireString))
        #expect(local.id == first.wireString, "the alias routes to the run")
    }

    @Test("R7 · the server's run is already closed: tombstoned here, and the queued taps void with notices")
    func startKnownClosed() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let id = UUID()
        try await Self.startElsewhere(h, id: id, topicId: h.topic.id, at: -40)
        try await Self.stopElsewhere(h, id: id, at: -20)

        let writes = h.runs()
        try await writes.start(topic: h.ref, version: 1, id: id)
        _ = try #require(try await writes.next(runId: id.wireString))
        _ = try #require(try await writes.stop(runId: id.wireString))
        let report = try await h.outbox().flushNow()
        let acked: Int = report.acked
        #expect(acked == 3)
        let tombstoned: Bool = try h.read { db in try ServerLayer.isTombstoned(db, kind: .run, id: id.wireString) }
        #expect(tombstoned)
        let reasons: [VoidReason] = report.runVoids.map(\.reason)
        #expect(reasons == [.afterStop, .alreadyClosed])
        let notices: Int = try await h.store.runNotices.all().count
        #expect(notices == 2)
    }

    @Test("R7 · the acked start's effect: the server's for its id, else merged")
    func startKnownEffect() {
        let id = UUID()
        let state = RunState(
            status: .running, startedAt: 0, endedAt: nil, open: nil, nextStep: nil, pausedSince: nil, segments: [],
            skipped: [], pauses: [], effects: [id.wireString: .applied])
        let run = Run(
            id: id, topicId: UUID(), version: 1, status: .running, revision: 1, startedAt: 0, endedAt: nil,
            edited: false, events: [], state: state, aliases: [])
        let own: RunEffect = Outbox.startKnownEffect(run, startId: id.wireString.uppercased())
        #expect(own == .applied)
        let unlisted: RunEffect = Outbox.startKnownEffect(run, startId: UUID().wireString)
        #expect(unlisted == .void(.merged))
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
        other.server.with { _ = $0.deletedRuns.insert(gone.id.wireString) }
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
