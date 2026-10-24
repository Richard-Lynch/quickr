import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// timers.md §13.3 R6 and R7 against the real backend, and the start-after-retrying-stop ordering
/// (§8.1) with the real server's merge rule (§4.5) behind it. Each device is an iOS store with the
/// production outbox (`Device`); the PWA's side of R7 is the request its service worker sends
/// (`WebServer.pwaStart`).
extension IntegrationTests {
    @Suite("Runs") struct RunCases {
        static let runEvents = "/api/v1/runs/*/events"

        // MARK: R6 · two devices on one run

        @Test(
            "R6 · A starts and steps; B, offline, taps Next twice and Lap; A stops; B flushes: the entry's timing is the fold of that history"
        )
        func r6() async throws {
            let it = try await IT.start()
            let steps = Self.steps(["wash", "dry", "fold"])
            let topic = try await it.a.createTimedTopic(steps: steps)
            let a = try Device(it.config)
            let b = try Device(it.config)
            try await a.run {
                try await b.run {
                    let storeA = try await a.connect()
                    let storeB = try await b.connect()
                    let tapsA = RunWrites(store: storeA, origin: .app)
                    let tapsB = RunWrites(store: storeB, origin: .app)
                    let outboxA = try await a.outbox()
                    let outboxB = try await b.outbox()

                    // A starts and steps (Wash → Dry), online.
                    let started = try await tapsA.start(topic: topic, version: 1)
                    let runId = started.runId
                    let runUUID = try #require(UUID(uuidString: runId))
                    try #require(started.started)
                    try #require(try await tapsA.next(runId: runId) != nil)
                    let sentA = try await outboxA.flush(force: true, budget: .seconds(20))
                    #expect(sentA.acked == 2)

                    // B pulls the run, goes offline and taps Next, Next and Lap on what it shows.
                    #expect(await b.coordinator.sync(reason: .requested) == .synced)
                    let pulled = try #require(try await storeB.runs.localRun(id: runUUID))
                    let pulledOpen = try #require(pulled.state.open)
                    #expect(pulledOpen.index == 1, "B shows Dry, A's Next pulled")
                    try b.transport.goOffline()
                    var tapIds: [String] = []
                    for type in [RunTapType.next, .next, .lap] {
                        try await Task.sleep(for: .milliseconds(30))
                        let tap = try #require(try await tapsB.tap(type, runId: runId), "B's \(type) enqueues")
                        if case .appended(let item) = tap { tapIds.append(item.id) }
                    }
                    try #require(tapIds.count == 3)
                    let offline = try await outboxB.flush(force: true, budget: .seconds(5))
                    #expect(offline.acked == 0)
                    let waiting: [OutboxState] = try await storeB.items.map(\.state)
                    let allQueued: Bool = waiting.allSatisfy { $0.isActive }
                    #expect(allQueued, "B's taps stay queued: \(waiting)")

                    // A stops: the version has no questions, so the entry exists at once.
                    try await Task.sleep(for: .milliseconds(30))
                    try #require(try await tapsA.stop(runId: runId) != nil)
                    let stopped = try await outboxA.flush(force: true, budget: .seconds(20))
                    #expect(stopped.acked == 1)
                    let first = try #require(try await it.serverEntry(runUUID), "A's stop made the entry")
                    let firstRevision: Int = first.revision
                    let firstLabels: [String] = first.timing?.segments.map(\.label) ?? []
                    #expect(firstLabels == ["Wash", "Dry"])

                    // B comes back and flushes: its taps were before the stop, so each merges.
                    b.transport.goOnline()
                    b.clock.advance(by: .seconds(3600))  // past the offline flush's backoff
                    let merged = try await outboxB.flush(force: true, budget: .seconds(20))
                    #expect(merged.acked == 3)
                    let remaining: Int = try await storeB.items.count
                    #expect(remaining == 0)

                    let run = try #require(try await it.serverRun(runUUID))
                    let entry = try #require(try await it.serverEntry(runUUID))
                    let status: RunStatus = run.status
                    #expect(status == .stopped)
                    for id in tapIds {
                        let effect: RunEffect? = run.state.effects[id]
                        #expect(effect == .applied, "B's tap \(id) merged")
                    }
                    let revision: Int = entry.revision
                    #expect(revision > firstRevision, "each merge bumps the entry")

                    // The entry is the fold of exactly the history the server holds.
                    let state = try RunFold.fold(runId: runId, steps: steps, events: run.foldEvents)
                    let expected = try RunFold.projectTiming(state, steps: steps)
                    let timing = try #require(entry.timing)
                    #expect(timing == expected)
                    let labels: [String] = timing.segments.map(\.label)
                    #expect(labels == ["Wash", "Dry", "Fold", "Lap 1", "Lap 2"])
                    let capturedAt: Int = RunInstant.milliseconds(entry.capturedAt)
                    #expect(capturedAt == timing.endedAt, "captured_at stays the stop")

                    // Both devices converge on that entry, and neither keeps the run.
                    #expect(await a.coordinator.sync(reason: .requested) == .synced)
                    #expect(await b.coordinator.sync(reason: .requested) == .synced)
                    for store in [storeA, storeB] {
                        let local = try #require(try await store.view(runUUID))
                        #expect(local.entry.timing == expected)
                        let open: LocalRun? = try await store.runs.openRun(topicId: run.topicId)
                        #expect(open == nil)
                    }
                }
            }
        }

        // MARK: R7 · one reminder, two Starts

        @Test("R7 · the reminder's Start on iOS, then in the PWA: one run, its id the action entry id")
        func r7IOSThenPWA() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTimedTopic(steps: Self.steps(["out", "back"]))
            try await it.withTimedDevice(topic) { device, store in
                let reminder = it.reminder(topic)
                let outcome = await device.startHandler().handle(reminder.response)
                let started: NotificationActionOutcome = .started(
                    runId: reminder.runId.wireString, serverId: it.config.serverId, flush: .drained)
                #expect(outcome == started)

                // The PWA's service worker starts the same slot: the server has it.
                let pwa = try await it.a.pwaStart(reminder)
                #expect(pwa.status == 409)
                #expect(pwa.object["code"] as? String == "event_conflict", "the PWA reads this as started elsewhere")

                let runs = try await it.openRuns(topic)
                #expect(runs == [reminder.runId])
                let run = try #require(try await it.serverRun(reminder.runId))
                let source: String? = run.events.first?.source
                #expect(source == "ios.notification")
                let events: Int = run.events.count
                #expect(events == 1, "the PWA's start wasn't stored")
            }
        }

        @Test("R7 · the reminder's Start in the PWA, then on iOS after a pull: one run, nothing written on iOS")
        func r7PWAThenIOSPulled() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTimedTopic(steps: Self.steps(["out", "back"]))
            try await it.withTimedDevice(topic) { device, store in
                let reminder = it.reminder(topic)
                let pwa = try await it.a.pwaStart(reminder)
                #expect(pwa.status == 201)

                #expect(await device.coordinator.sync(reason: .requested) == .synced)
                let outcome = await device.startHandler().handle(reminder.response)
                let already: NotificationActionOutcome = .alreadyStarted(
                    runId: reminder.runId.wireString, flush: .drained)
                #expect(outcome == already)
                let items: Int = try await store.items.count
                #expect(items == 0)
                let runs = try await it.openRuns(topic)
                #expect(runs == [reminder.runId])
            }
        }

        /// The handler can't know of the PWA's start before its next pull (a Start in the background,
        /// say): it enqueues the same run id with its own `at`, and the server answers
        /// `event_conflict`. The outbox reads the run, finds it is this topic's, and acks the start
        /// with it ("started elsewhere"), as the PWA drops its item on the same answer.
        @Test("R7 · the reminder's Start in the PWA, then on iOS before a pull: one run, and iOS joins it")
        func r7PWAThenIOSUnpulled() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTimedTopic(steps: Self.steps(["out", "back"]))
            try await it.withTimedDevice(topic) { device, store in
                let reminder = it.reminder(topic)
                let pwa = try await it.a.pwaStart(reminder)
                #expect(pwa.status == 201)

                _ = await device.startHandler().handle(reminder.response)
                let runs = try await it.openRuns(topic)
                #expect(runs == [reminder.runId], "one run, the PWA's")

                try await Self.expectJoined(it, device, store, reminder.runId)
            }
        }

        @Test("R7 · two iOS stores start the same reminder, the second before a pull: one run, both on it")
        func r7TwoIOSStores() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTimedTopic(steps: Self.steps(["out", "back"]))
            let second = try Device(it.config)
            try await it.withTimedDevice(topic) { device, _ in
                try await second.run {
                    let secondStore = try await second.connect()
                    let reminder = it.reminder(topic)
                    let first = await device.startHandler().handle(reminder.response)
                    let started: NotificationActionOutcome = .started(
                        runId: reminder.runId.wireString, serverId: it.config.serverId, flush: .drained)
                    #expect(first == started)

                    _ = await second.startHandler().handle(reminder.response)
                    let runs = try await it.openRuns(topic)
                    #expect(runs == [reminder.runId])
                    try await Self.expectJoined(it, second, secondStore, reminder.runId)
                }
            }
        }

        /// After a second Start of a reminder already started elsewhere, the device has no failed item,
        /// and its next tap on the run reaches the server.
        static func expectJoined(_ it: IT, _ device: Device, _ store: LocalStore, _ runId: UUID) async throws {
            let failed: [OutboxItem] = try await store.items.filter { $0.state == .failed }
            #expect(failed.isEmpty, "a start the server already has isn't a failure: \(failed.map(\.lastErrorJSON))")
            #expect(await device.coordinator.sync(reason: .requested) == .synced)
            let taps = RunWrites(store: store, origin: .app)
            try #require(try await taps.next(runId: runId.wireString) != nil, "the run is in the local view")
            _ = try await device.outbox().flush(force: true, budget: .seconds(10))
            let run = try #require(try await it.serverRun(runId))
            let types: [RunEventType] = run.events.map(\.event.type)
            #expect(types.contains(.next), "the Next reached the server: \(types)")
        }

        // MARK: Start after a retrying Stop (§8.1)

        @Test("Start after a Stop that got a 503: the Stop goes first; two runs, no merge")
        func startAfterStop503() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTimedTopic(steps: Self.steps(["out", "back"]))
            try await it.withTimedDevice(topic) { device, store in
                let (outbox, first) = try await Self.startedRun(device, store, topic)
                let path = "/api/v1/runs/\(first.wireString)/events"
                try await it.proxy.add(["action": "status", "status": 503, "method": "POST", "path": path])
                try await Self.stopThenStart(it, device, store, outbox, topic, first) { stop in
                    // The proxy's 503 has no identity headers, so it can't prove the stop wasn't
                    // delivered; either way it waits for a retry.
                    let waiting: Bool = stop.state.isActive
                    #expect(waiting, "\(stop.state)")
                    let refused = try await it.proxy.log().filter { $0.route == path && $0.action == "status" }
                    let upstream: [String?] = refused.map(\.upstream)
                    #expect(upstream == [nil], "the 503 never reached the server")
                    let run = try #require(try await it.serverRun(first))
                    let status: RunStatus = run.status
                    #expect(status == .running)
                }
            }
        }

        @Test("Start after a Stop held past its deadline: the Stop is resent first; two runs, no merge")
        func startAfterStopTimeout() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTimedTopic(steps: Self.steps(["out", "back"]))
            try await it.withTimedDevice(topic) { device, store in
                let (outbox, first) = try await Self.startedRun(device, store, topic)
                let path = "/api/v1/runs/\(first.wireString)/events"
                let hold = try await it.proxy.add(["action": "hold", "method": "POST", "path": path])
                try await Self.stopThenStart(it, device, store, outbox, topic, first) { stop in
                    try await it.proxy.waitUntilHolding(hold)
                    #expect(stop.state == .uncertain && stop.maybeDelivered)
                }
                // The parked first send of the stop arrives last: a replay, nothing changes.
                try await it.proxy.release(hold)
                try await eventually("the parked stop is answered") {
                    try await it.proxy.log().filter { $0.route == path && $0.upstreamStatus != nil }.count >= 3
                }
                let late = try await it.proxy.log().filter { $0.route == path }.compactMap(\.upstreamStatus)
                #expect(late.allSatisfy { $0 == 200 || $0 == 201 }, "\(late)")
                let runs = try await it.openRuns(topic)
                #expect(runs.count == 1)
            }
        }

        /// A run started and flushed on `device`.
        static func startedRun(_ device: Device, _ store: LocalStore, _ topic: TopicRef) async throws
            -> (Outbox, UUID)
        {
            let outbox = try await device.outbox()
            let started = try await RunWrites(store: store, origin: .app).start(topic: topic, version: 1)
            let sent = try await outbox.flush(force: true, budget: .seconds(20))
            #expect(sent.acked == 1)
            return (outbox, try #require(UUID(uuidString: started.runId)))
        }

        /// Stops `first` through a proxy rule that fails the send (`failedStop` checks how), starts a
        /// new run while the stop waits for its retry, and checks that the start waits too, then that
        /// both go in order: `first` stopped with its entry, the new run open on its own id, no alias.
        static func stopThenStart(
            _ it: IT, _ device: Device, _ store: LocalStore, _ outbox: Outbox, _ topic: TopicRef, _ first: UUID,
            failedStop: (OutboxItem) async throws -> Void
        ) async throws {
            let taps = RunWrites(store: store, origin: .app)
            let stop = try #require(try await taps.stop(runId: first.wireString))
            guard case .appended(let stopItem) = stop else { throw CancellationError() }
            _ = try await outbox.flush(force: true, budget: .seconds(3))
            try await failedStop(try #require(try await store.item(stopItem.id)))

            // The stop shows the run closed here, so the next tap starts a new run.
            let next = try await taps.start(topic: topic, version: 1)
            try #require(next.started, "the local view has no open run")
            let second = try #require(UUID(uuidString: next.runId))
            #expect(second != first)
            let index = device.sent().count
            // A scheduled flush (not forced): the stop is in its backoff, so the start must wait.
            _ = try await outbox.flush(force: false, budget: .seconds(3))
            let early = device.sent(from: index).filter { $0.url.path.contains(second.wireString) }
            #expect(early.isEmpty, "the start waits for the retrying stop")
            #expect(try await it.serverRun(second) == nil)

            device.clock.advance(by: .seconds(3600))  // past the stop's backoff
            let report = try await outbox.flush(force: true, budget: .seconds(20))
            #expect(report.acked == 2)
            let order = device.sent(from: index).compactMap { request -> String? in
                if request.url.path.contains(first.wireString) { return "stop" }
                if request.url.path.contains(second.wireString) { return "start" }
                return nil
            }
            #expect(order == ["stop", "start"])

            let firstRun = try #require(try await it.serverRun(first))
            let secondRun = try #require(try await it.serverRun(second))
            let firstStatus: RunStatus = firstRun.status
            let secondStatus: RunStatus = secondRun.status
            let secondId: UUID = secondRun.id
            #expect(firstStatus == .stopped)
            #expect(secondStatus == .running)
            #expect(secondId == second, "not merged into the first run")
            #expect(firstRun.aliases.isEmpty)
            #expect(secondRun.aliases.isEmpty)
            #expect(try await it.serverEntry(first) != nil)
            let runs = try await it.openRuns(topic)
            #expect(runs == [second])
        }

        static func steps(_ keys: [String]) -> [TopicTimer.Step] {
            keys.map { TopicTimer.Step(key: $0, label: $0.prefix(1).uppercased() + $0.dropFirst()) }
        }
    }
}

// MARK: - Harness

/// A timed reminder of `topic` on server a, as the server builds it, and the Start tap on it.
struct TimedReminder: Sendable {
    var topic: TopicRef
    var dueSince: String
    var info: QuickrNotificationInfo
    var category: NotificationCategory
    /// timers.md §10.2: the run id and the start event's id, on every device and the PWA.
    var runId: UUID

    var response: NotificationActionResponse {
        NotificationActionResponse(action: .custom(category.actions[0].identifier), title: topic.name, quickr: info)
    }
}

extension IT {
    /// Runs `body` with a device onboarded to server a after `topic` exists, so it has the timed
    /// version.
    func withTimedDevice(_ topic: TopicRef, _ body: (Device, LocalStore) async throws -> Void) async throws {
        let device = try Device(config)
        try await device.run {
            let store = try await device.connect()
            try await body(device, store)
        }
    }

    /// A reminder for a fresh slot (each test its own run id).
    func reminder(_ topic: TopicRef) -> TimedReminder {
        let slot = Date().addingTimeInterval(-Double(Int.random(in: 60...86_000)))
        let dueSince = ISO8601DateFormatter().string(from: slot)  // whole seconds, Z
        let info = QuickrNotificationInfo(
            kind: "due", serverId: config.serverId, topicId: topic.id, topicSlug: topic.slug, version: 1,
            dueSince: dueSince, url: "/t/\(topic.slug)/record", quickLog: .timed)
        let category = NotificationCategory(
            serverId: config.serverId, topicId: topic.id, version: 1, descriptor: .timed)
        let runId = ActionEntryId.make(serverId: config.serverId, topicId: topic.id, dueSince: dueSince)
        return TimedReminder(topic: topic, dueSince: dueSince, info: info, category: category, runId: runId)
    }

    /// Server a's client for typed reads.
    var client: APIClient {
        APIClient(baseURL: config.serverAURL, transport: URLSessionTransport(), identity: StaticServerIdentity(nil))
    }

    /// The run `id` resolves to on server a, in any status, or nil.
    func serverRun(_ id: UUID) async throws -> Run? {
        let response = try await client.getRun(id: id)
        if response.status == 404 { return nil }
        guard let run = response.value else { throw ITError("get run \(id): \(response.status ?? 0)") }
        return run
    }

    func serverEntry(_ id: UUID) async throws -> Entry? {
        let response = try await client.getEntry(id: id)
        if response.status == 404 { return nil }
        guard let entry = response.value else { throw ITError("get entry \(id): \(response.status ?? 0)") }
        return entry
    }

    /// The ids of `topic`'s open runs on server a.
    func openRuns(_ topic: TopicRef) async throws -> [UUID] {
        let response = try await client.listRuns(statuses: ["open"], topic: topic.id)
        let runs = try #require(response.value, "list runs: \(response.status ?? 0)")
        return runs.map(\.id)
    }
}

struct ITError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

extension WebServer {
    /// Creates a timed topic with no questions (a stop makes the entry at once) and returns its ref.
    func createTimedTopic(steps: [TopicTimer.Step]) async throws -> TopicRef {
        let name = "IT run \(UUID().uuidString.prefix(8))"
        let reply = try await http.call(
            "POST", "/api/v1/topics",
            [
                "name": name, "questions": [] as [Any],
                "timer": ["steps": steps.map { ["key": $0.key, "label": $0.label] }],
            ])
        try #require(reply.status == 201, "create timed topic: \(reply.status) \(reply.object)")
        let id = try #require((reply.object["id"] as? String).flatMap(UUID.init))
        return TopicRef(id: id, slug: try #require(reply.object["slug"] as? String), name: name)
    }

    /// The PWA service worker's Start for `reminder` (frontend/src/lib/pushActions.ts
    /// `handleStartAction`): a `start` whose run id and event id are the action entry id, at now,
    /// on the reminder's version, from the PWA's channel.
    func pwaStart(_ reminder: TimedReminder) async throws -> HTTP.Reply {
        let id = reminder.runId.wireString
        return try await http.call(
            "POST", "/api/v1/runs/\(id)/events",
            [
                "id": id, "type": "start", "at": WireDate.format(Date()), "topic_id": reminder.topic.id,
                "version": 1, "source": "pwa.notification",
            ])
    }
}

extension Device {
    /// The notification action handler as the app wires it, over this device's stores, sending
    /// through the proxy.
    func startHandler() -> NotificationActionHandler {
        NotificationActionHandler(
            partitions: partitions, center: FakeNotificationCenter(),
            sender: { [config, transport] _ in
                APIClient(baseURL: config.proxyURL, transport: transport, identity: StaticServerIdentity(nil))
            },
            owner: "app:A")
    }
}
