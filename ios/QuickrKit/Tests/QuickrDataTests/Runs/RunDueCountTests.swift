import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@_spi(Testing) @testable import QuickrData

/// R11 (timers.md §11.1, §13.3): `TopicListing.dueCount` and `countsAsDue`, with the store's real
/// open-runs set, are the one rule behind the app badge, the NSE badge, the action handler's
/// badge, home's "Due now", the widgets' due list and Siri's: a topic with an open run (running or
/// paused, a queued start included) isn't counted; a finishing run's topic still is.
enum RunSeed {
    /// A server-layer run of `topicId` started an hour before `at`: `.running`, `.paused`, or
    /// `.finishing` (stopped without its required answers).
    @discardableResult
    static func run(_ db: Database, topicId: UUID, _ status: RunStatus, at: Date) throws -> Run {
        let id = UUID()
        let started = RunInstant.milliseconds(at.addingTimeInterval(-3600))
        var events = [RunEvent(id: id.wireString, type: .start, at: started)]
        switch status {
        case .paused: events.append(RunEvent(id: UUID().wireString, type: .pause, at: started + 60_000))
        case .finishing: events.append(RunEvent(id: UUID().wireString, type: .stop, at: started + 60_000))
        default: break
        }
        let state = try RunFold.fold(runId: id.wireString, steps: [], events: events)
        let run = Run(
            id: id, topicId: topicId, version: 1, status: status, revision: events.count, startedAt: state.startedAt,
            endedAt: state.endedAt, edited: false,
            events: events.enumerated().map { index, event in
                Run.StoredEvent(event: event, arrival: index + 1, effect: .applied, source: "web")
            },
            state: state, aliases: [])
        _ = try ServerLayer.upsert(db, run: run)
        return run
    }

    static func ref(_ topic: Topic) -> TopicRef { TopicRef(id: topic.id, slug: topic.slug, name: topic.name) }
}

@Suite struct RunDueCountTests {
    /// Running, paused and a queued start are open; finishing isn't.
    @Test func openRunTopicsAreTheRunningAndPausedOnes() async throws {
        let topics = ["Running", "Paused", "Finishing", "Queued", "Idle"].map { Make.topic(name: $0) }
        let store = try TestStore()
        try store.write { db in
            for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
            try RunSeed.run(db, topicId: topics[0].id, .running, at: Make.t0)
            try RunSeed.run(db, topicId: topics[1].id, .paused, at: Make.t0)
            try RunSeed.run(db, topicId: topics[2].id, .finishing, at: Make.t0)
        }
        try await RunWrites(store: store.store, origin: .app).start(topic: RunSeed.ref(topics[3]), version: 1)

        let open: TopicListing.OpenRunTopics = try await store.store.runs.openRunTopics()
        let expected: TopicListing.OpenRunTopics = [topics[0].id, topics[1].id, topics[3].id]
        #expect(open == expected)
    }

    /// The widgets: the due list's due topics and a topic widget's bell both use `countsAsDue`.
    @Test func theWidgetsLeaveOutATopicWithAnOpenRun() async throws {
        let now = Make.t0.addingTimeInterval(3 * 60 * 60)
        let every: Schedule = .interval(.init(everyMinutes: 60, timezone: "UTC"))
        let running = Make.topic(name: "Running", schedule: every)
        let finishing = Make.topic(name: "Finishing", schedule: every)
        let store = try TestStore()
        try store.write { db in
            for topic in [running, finishing] { _ = try ServerLayer.upsert(db, topic: topic) }
            try RunSeed.run(db, topicId: running.id, .running, at: now)
            try RunSeed.run(db, topicId: finishing.id, .finishing, at: now)
        }
        let reader = WidgetReader(store: store.store)

        let list = try await reader.dueList(now: now)
        let due: [String] = list.filter { $0.countsAsDue(at: now) }.map(\.topic.name)
        #expect(due == ["Finishing"])
        let one = try #require(try await reader.topic(id: running.id))
        let hasOpenRun: Bool = one.hasOpenRun
        #expect(hasOpenRun)
        let counts: Bool = one.countsAsDue(at: now)
        #expect(!counts)
        let scheduledDue: Bool = one.due(at: now)?.isDue == true
        #expect(scheduledDue, "its schedule is still due: only the count leaves it out")
    }

    /// Siri's "What's due": the open run's topic isn't listed; the finishing one's is.
    @Test func siriLeavesOutATopicWithAnOpenRun() async throws {
        let now = Make.t0.addingTimeInterval(3 * 60 * 60)
        let every: Schedule = .interval(.init(everyMinutes: 60, timezone: "UTC"))
        let running = Make.topic(name: "Running", schedule: every)
        let finishing = Make.topic(name: "Finishing", schedule: every)
        let store = try TestStore()
        store.wall.set(now)
        try store.write { db in
            for topic in [running, finishing] { _ = try ServerLayer.upsert(db, topic: topic) }
            try RunSeed.run(db, topicId: running.id, .running, at: now)
            try RunSeed.run(db, topicId: finishing.id, .finishing, at: now)
        }
        let local = store.store
        let context = IntentWriteContext(origin: .siri, openActiveStore: { local }, wallClock: store.wall)

        let due: [String] = try await IntentDue.dueTopics(in: context).map(\.name)
        #expect(due == ["Finishing"])
    }
}

extension HomeModelTests {
    /// Home: "Due now" and the badge leave out the open run's topic (Meds) but keep the finishing
    /// one's (Water); each tile's run is its open run, else its finishing one. A queued start on
    /// Water then takes it out too, and its tile shows the new open run.
    @Test func homeLeavesOutATopicWithAnOpenRun() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let meds = Self.mixed[0]
        let water = Self.mixed[1]
        let now = Self.now
        try await w.store.writer.write { db in
            try RunSeed.run(db, topicId: meds.id, .running, at: now)
            try RunSeed.run(db, topicId: water.id, .finishing, at: now)
        }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }
        try await eventually("the runs are read") { await MainActor.run { model.runs.count == 2 } }

        let due: [String] = Self.names(model.sections.due)
        #expect(due == ["Water"])
        let badge: Int = model.badgeCount
        #expect(badge == 1)
        let open: TopicListing.OpenRunTopics = model.openRuns
        #expect(open == [meds.id])
        let medsOpen: Bool = model.runs[meds.id]?.isOpen == true
        #expect(medsOpen)
        let waterStatus: RunStatus? = model.runs[water.id]?.status
        #expect(waterStatus == .finishing)

        try await RunWrites(store: w.store, origin: .app).start(topic: RunSeed.ref(water), version: 1)
        try await eventually("the queued start is seen") { await MainActor.run { model.badgeCount == 0 } }
        let dueAfter: [String] = Self.names(model.sections.due)
        #expect(dueAfter.isEmpty)
        let waterOpen: Bool = model.runs[water.id]?.isOpen == true
        #expect(waterOpen, "the open run wins over the finishing one")
    }
}

extension NotificationPreparationTests {
    /// The NSE badge: Meds (due) has an open run, so only Water counts.
    @Test func theNSEBadgeLeavesOutATopicWithAnOpenRun() async throws {
        let w = try await World()
        let (meds, now) = (Self.meds, Self.now)
        try await w.store.writer.write { db in try RunSeed.run(db, topicId: meds.id, .running, at: now) }
        let badge: Int? = await w.prepare(Self.reminder()).badge
        #expect(badge == 1)
    }

    /// A finishing run isn't open: Meds still counts.
    @Test func theNSEBadgeCountsATopicWithAFinishingRun() async throws {
        let w = try await World()
        let (meds, now) = (Self.meds, Self.now)
        try await w.store.writer.write { db in try RunSeed.run(db, topicId: meds.id, .finishing, at: now) }
        let badge: Int? = await w.prepare(Self.reminder()).badge
        #expect(badge == 2)
    }
}

extension NotificationActionHandlerTests {
    /// After an action logs, the badge is the active store's due count: Water is due, but has an
    /// open run (0); with a finishing run instead it counts (1).
    @Test(arguments: [RunStatus.running, .finishing])
    func theActionBadgeLeavesOutATopicWithAnOpenRun(_ status: RunStatus) async throws {
        let w = try await World()
        var water = w.water
        water.schedule = .interval(.init(everyMinutes: 30, timezone: "UTC"))
        water.scheduleUpdatedAt = Make.t0.addingTimeInterval(-86_400)
        water.revision += 1
        let store = try #require(w.stores[Self.serverA])
        try await store.writer.write { [water] db in
            _ = try ServerLayer.upsert(db, topic: water)
            try RunSeed.run(db, topicId: water.id, status, at: Make.t0)
        }
        w.center.withState { $0.badge = 99 }
        _ = await w.tap(w.reminder(w.moodTopic), 1)
        let badge: Int = w.center.withState { $0.badge }
        #expect(badge == (status == .running ? 0 : 1))
    }
}
