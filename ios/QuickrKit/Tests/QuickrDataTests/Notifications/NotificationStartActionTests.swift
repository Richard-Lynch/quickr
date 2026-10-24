import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@_spi(Testing) @testable import QuickrData

/// A timed reminder's Start (timers.md §10.2; I-NOTIF): validated like any action (N3), the run's
/// id is the reminder's action entry id (N16), a second Start writes nothing, and it runs where
/// the handler does, in the background, flushing the active store. Same world as
/// `NotificationActionHandlerTests`: file-backed stores, a fake center and the fake server.
@Suite(.timeLimit(.minutes(2))) struct NotificationStartActionTests {
    typealias Handler = NotificationActionHandlerTests
    static let serverA = Handler.serverA
    static let serverB = Handler.serverB
    static let token = "a1b2c3"

    /// The handler world with a timed, due "Walk" topic (version 1, two steps) in both stores and
    /// on the fake server, and this device's APNs token in the registry.
    final class World: Sendable {
        let w: Handler.World
        let walk: Topic
        /// What the Live Activity seam was asked, and what it answers.
        let requests = Mutex<[NotificationRunStart]>([])
        let shows = Mutex(false)

        init() async throws {
            w = try await Handler.World()
            var walk = Make.topic(name: "Walk")
            walk.questions = []
            // Due (no entries here), so the badge counts it unless it has an open run.
            walk.schedule = .interval(.init(everyMinutes: 30, timezone: "UTC"))
            walk.scheduleUpdatedAt = Make.t0.addingTimeInterval(-86_400)
            let steps = [TopicTimer.Step(key: "out", label: "Out"), TopicTimer.Step(key: "back", label: "Back")]
            let version = TopicVersion(version: 1, questions: [], timer: TopicTimer(steps: steps), createdAt: Make.t0)
            for store in w.stores.values {
                try await store.writer.write { [walk] db in
                    _ = try ServerLayer.upsert(db, topic: walk)
                    _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: walk.id)
                }
            }
            w.server.put(walk)
            w.server.time(walk.id, FakeTimer(steps: steps))
            try await w.partitions.registry.writer.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO apns_state (id, token) VALUES (1, ?)",
                    arguments: [NotificationStartActionTests.token])
            }
            self.walk = walk
        }

        var handler: NotificationActionHandler {
            NotificationActionHandler(
                partitions: w.partitions, center: w.center,
                sender: { [server = w.server] _ in
                    APIClient(baseURL: FakeServer.base, transport: server, identity: StaticServerIdentity(nil))
                },
                owner: "app:test", wallClock: w.wall, reloadWidgets: { [w] in w.reloads.withLock { $0 += 1 } },
                startLiveActivity: { [self] start in
                    requests.withLock { $0.append(start) }
                    return shows.withLock { $0 }
                })
        }

        /// A timed reminder for Walk, as the server builds it.
        func reminder(serverId: String = NotificationStartActionTests.serverA, version: Int = 1)
            -> (info: QuickrNotificationInfo, category: NotificationCategory)
        {
            let category = NotificationCategory(
                serverId: serverId, topicId: walk.id.wireString, version: version, descriptor: .timed)
            let info = QuickrNotificationInfo(
                kind: "due", serverId: serverId, topicId: walk.id.wireString, topicSlug: walk.slug, version: version,
                dueSince: Handler.dueSince, url: "/t/\(walk.slug)/record", quickLog: .timed)
            return (info, category)
        }

        func start(_ reminder: (info: QuickrNotificationInfo, category: NotificationCategory)) async
            -> NotificationActionOutcome
        {
            await handler.handle(
                NotificationActionResponse(
                    action: .custom(reminder.category.actions[0].identifier), title: "Walk", quickr: reminder.info))
        }

        /// The derived run id (§10.2): the reminder's action entry id.
        func runId(serverId: String = NotificationStartActionTests.serverA) -> String {
            ActionEntryId.make(serverId: serverId, topicId: walk.id.wireString, dueSince: Handler.dueSince).wireString
        }

        func runItems(_ serverId: String = NotificationStartActionTests.serverA) async throws -> [OutboxItem] {
            try await w.items(serverId).filter { $0.kind == .runEvent }
        }
    }

    // MARK: - Start

    /// One start, with the derived id as the run id and the start event's id, on the reminder's
    /// version, stamped with this device's token; flushed; the reminder cleared; the badge counts
    /// the topic out now that it has an open run.
    @Test func aStartEnqueuesOneStartWithTheDerivedIdAndFlushesIt() async throws {
        let world = try await World()
        let r = world.reminder()
        let other = world.w.reminder(world.w.moodTopic)
        world.w.center.withState {
            $0.delivered = [
                NotificationSnapshot(id: "a", quickr: r.info), NotificationSnapshot(id: "b", quickr: other.info),
            ]
            $0.badge = 99
        }
        let id = world.runId()
        let outcome = await world.start(r)
        #expect(outcome == .started(runId: id, serverId: Self.serverA, flush: .drained))

        let run = try #require(world.w.server.run(id), "flushed within the budget")
        let version: Int = run.version
        #expect(version == 1)
        let events: [String] = run.events.map(\.event.id)
        #expect(events == [id], "the run id is the start event's id")
        let body = try #require(run.bodies[id])
        let device = try #require(body.device)
        #expect(device.apnsToken == Self.token)
        #expect(device.liveActivity == false, "the seam answered no")
        #expect(try await world.runItems().isEmpty, "acked")

        let delivered: [String] = world.w.center.withState { $0.delivered.map(\.id) }
        #expect(delivered == ["b"], "only this topic's reminders go")
        let badge: Int? = world.w.center.withState { $0.badge }
        #expect(badge == 0, "Walk has an open run: not due")
        #expect(world.w.reloads.withLock { $0 } == 1)
        let added: [LocalNotificationRequest] = world.w.center.withState { $0.added }
        #expect(added.isEmpty, "no failure notification")
    }

    /// A second Start on the same reminder writes nothing: while the first is queued (it is sent
    /// now, by the forced flush), once it is on the server, and after the run stopped.
    @Test func aSecondStartOnTheSameReminderWritesNothing() async throws {
        let world = try await World()
        world.w.server.inject(nil, .respond(FakeServer.problem(503, "unavailable")))  // the first stays queued
        let r = world.reminder()
        let id = world.runId()
        guard case .started = await world.start(r) else { throw Handler.Failure("the first Start starts") }
        #expect(try await world.runItems().count == 1)
        #expect(world.w.server.run(id) == nil)

        let queued = await world.start(r)
        #expect(queued == .alreadyStarted(runId: id, flush: .drained))
        #expect(world.w.server.run(id) != nil, "the queued start went out")
        #expect(try await world.runItems().isEmpty)

        let onServer = await world.start(r)
        #expect(onServer == .alreadyStarted(runId: id, flush: .drained))
        #expect(try await world.runItems().isEmpty)
        let events: Int? = world.w.server.run(id)?.events.count
        #expect(events == 1, "one start on the server")
        #expect(world.w.reloads.withLock { $0 } == 1, "nothing new to show")
        #expect(world.requests.withLock { $0.count } == 1, "a Live Activity is asked for once")
    }

    /// Two Starts on one reminder at once (two taps, the push re-delivered) enqueue one start.
    @Test func racingStartsOnOneReminderStartOnce() async throws {
        let world = try await World()
        world.w.server.inject(nil, once: false, .respond(FakeServer.problem(503, "unavailable")))
        let r = world.reminder()
        let outcomes = await withTaskGroup(of: NotificationActionOutcome.self) { group in
            for _ in 0..<3 { group.addTask { await world.start(r) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let started = outcomes.count { if case .started = $0 { true } else { false } }
        let already = outcomes.count { if case .alreadyStarted = $0 { true } else { false } }
        #expect(started == 1)
        #expect(already == 2)
        let items = try await world.runItems()
        #expect(items.map(\.id) == [world.runId()])
    }

    /// The topic already has an open run here (started from the app): the Start routes to it,
    /// enqueues nothing and asks for no Live Activity (§4.5).
    @Test func aStartWhileTheTopicHasAnOpenRunRoutesToIt() async throws {
        let world = try await World()
        let store = try #require(world.w.stores[Self.serverA])
        let ref = TopicRef(id: world.walk.id, slug: world.walk.slug, name: world.walk.name)
        let open = try await RunWrites(store: store, origin: .app).start(topic: ref, version: 1)
        let outcome = await world.start(world.reminder())
        #expect(outcome == .alreadyStarted(runId: open.runId, flush: .drained))
        let items = try await world.runItems()
        #expect(items.isEmpty, "the app's start was flushed; no second one")
        #expect(world.w.server.run(world.runId()) == nil)
        #expect(world.requests.withLock { $0.isEmpty })
    }

    // MARK: - The background and the Live Activity seam

    /// The Live Activity is asked for before the write, with the derived id and the reminder's
    /// version, and the start says it is shown here (so the server doesn't push-to-start one).
    @Test func aShownLiveActivityIsStampedOnTheStart() async throws {
        let world = try await World()
        world.shows.withLock { $0 = true }
        let id = world.runId()
        #expect(await world.start(world.reminder()) == .started(runId: id, serverId: Self.serverA, flush: .drained))
        let requests = world.requests.withLock { $0 }
        #expect(requests.map(\.runId.wireString) == [id])
        #expect(requests.map(\.version) == [1])
        #expect(requests.map(\.topic.id) == [world.walk.id.wireString])
        let device = try #require(world.w.server.run(id)?.bodies[id]?.device)
        #expect(device.liveActivity == true)
    }

    /// In the background (the app launched for the action, iOS refuses a Live Activity), the
    /// start is still written and flushed; the server's push-to-start shows the activity.
    @Test func inTheBackgroundTheStartStillGoesOut() async throws {
        let world = try await World()
        world.shows.withLock { $0 = false }
        let id = world.runId()
        #expect(await world.start(world.reminder()) == .started(runId: id, serverId: Self.serverA, flush: .drained))
        #expect(world.requests.withLock { $0.count } == 1)
        let device = try #require(world.w.server.run(id)?.bodies[id]?.device)
        #expect(device.liveActivity == false)
    }

    /// N8's rule for a Start: an inactive server's reminder starts its run in that server's store,
    /// with no badge change, no flush and no local Live Activity (this device shows the active
    /// server's runs).
    @Test func anInactiveStoresStartIsQueuedThereOnly() async throws {
        let world = try await World()
        world.w.center.withState { $0.badge = 7 }
        let r = world.reminder(serverId: Self.serverB)
        let id = world.runId(serverId: Self.serverB)
        #expect(await world.start(r) == .started(runId: id, serverId: Self.serverB, flush: nil))
        let items = try await world.runItems(Self.serverB)
        #expect(items.map(\.id) == [id])
        #expect(try await world.runItems().isEmpty, "never into the active store")
        #expect(world.w.center.withState { $0.badge } == 7)
        #expect(world.w.server.handled.isEmpty)
        #expect(world.requests.withLock { $0.isEmpty })
    }

    // MARK: - Validation (N3, N7)

    /// `k = t` needs a timed reminder of the same server, topic and version; a timed reminder
    /// offers nothing but Start. Each mismatch writes nothing and says so.
    @Test func aStartThatDoesntMatchItsReminderWritesNothing() async throws {
        let world = try await World()
        let r = world.reminder()
        let topic = world.walk.id.wireString
        func id(server: String = Self.serverA, version: Int = 1, key: String = "", kind: ActionIdentifier.Kind = .start)
            -> String
        {
            ActionIdentifier(serverId: server, topicId: topic, version: version, key: key, kind: kind).description
        }
        let tampered = [
            id(server: Self.serverB), id(version: 2), id(kind: .single), "q1|\(Self.serverA)|\(topic)|1|k|t|",
        ]
        for action in tampered {
            let outcome = await world.handler.handle(.init(action: .custom(action), title: "Walk", quickr: r.info))
            #expect(outcome == .refused(.invalid), "\(action)")
        }
        // A Start on an untimed reminder (the mood topic's).
        let mood = world.w.reminder(world.w.moodTopic)
        let start = ActionIdentifier(
            serverId: Self.serverA, topicId: world.w.moodTopic.id.wireString, version: 1, key: "", kind: .start)
        let onMood = await world.handler.handle(.init(action: .custom(start.description), quickr: mood.info))
        #expect(onMood == .refused(.invalid))
        #expect(try await world.w.items().isEmpty)
        #expect(world.requests.withLock { $0.isEmpty })
    }

    /// N7 for a Start: a reminder from a removed server is dropped with the explanation.
    @Test func aStartFromARemovedServerIsDroppedWithAnExplanation() async throws {
        let world = try await World()
        let gone = "0b9e0000-0000-4000-8000-0000000000cc"
        #expect(await world.start(world.reminder(serverId: gone)) == .refused(.unknownServer))
        let posted = try #require(world.w.center.withState { $0.added }.first)
        #expect(posted.body == "This reminder came from a server you've removed from quickR")
        #expect(try await world.w.items().isEmpty)
        #expect(try await world.w.items(Self.serverB).isEmpty)
        #expect(world.w.server.handled.isEmpty)
    }

    /// A Start on a reminder for a topic since made untimed (a newer version without a timer)
    /// still starts a run, on the reminder's timed version (timers.md §10.1).
    @Test func aStartAfterTheTopicWasMadeUntimedStartsOnTheRemindersVersion() async throws {
        let world = try await World()
        var walk = world.walk
        walk.currentVersion = 2
        let untimed = TopicVersion(version: 2, questions: [], createdAt: Make.t0)
        let store = try #require(world.w.stores[Self.serverA])
        try await store.writer.write { [walk] db in
            _ = try ServerLayer.upsert(db, topic: walk)
            _ = try ServerLayer.insert(db, version: untimed, id: UUID(), topicId: walk.id)
        }
        let id = world.runId()
        #expect(await world.start(world.reminder()) == .started(runId: id, serverId: Self.serverA, flush: .drained))
        let version: Int? = world.w.server.run(id)?.version
        #expect(version == 1)
    }
}
