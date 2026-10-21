import AppIntents
import Foundation
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

/// The intents' data path as each process boots it (`AppEnvironment.bootstrap()` in the app,
/// `WidgetBootstrap.register()` in the widget extension), over a store whose active server holds
/// the fixture topics, then the calls the system and WidgetKit make. These run in the Unit plan on every runtime, iOS 26 CI included; the system-level proofs
/// (AppIntentsTesting, widget-proof.sh) can't run there. Serialized: the registration is
/// process-wide.
@Suite(.serialized) @MainActor struct IntentBootstrapTests {
    /// The seeded store with Coffee and Mood made quick-loggable (a number, an option), for the
    /// write paths. Only here: other suites' sessions on the fixture store must not register
    /// notification categories with the system while CAT's tests read them.
    static func quickLogLocation() async throws -> StoreLocation {
        let location = try await TestStores.seededLocation()
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        var topics = try await PlaceholderTopicRepository().topics().map(\.topic)
        let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 20, unit: "cups")))
        let mood = Question(
            key: "mood", label: "Mood",
            kind: .choice(
                .init(options: [EnumOption(value: "good", label: "Good"), EnumOption(value: "bad", label: "Bad")])))
        for index in topics.indices {
            topics[index].questions = topics[index].id == PlaceholderTopicRepository.coffee ? [cups] : [mood]
            topics[index].revision += 1
        }
        let seeded = topics
        try await store.writer.write { db in for topic in seeded { _ = try ServerLayer.upsert(db, topic: topic) } }
        return location
    }

    @Test func appBootstrapServesTheTopicQuery() async throws {
        let location = try await TestStores.seededLocation()
        defer { TestStores.remove(location) }
        _ = AppEnvironment.bootstrap(location: location)
        let query = TopicEntityQuery()
        #expect(try await query.suggestedEntities().map(\.name) == ["Coffee", "Mood"])
        #expect(try await query.allEntities().map(\.name) == ["Coffee", "Mood"])
        #expect(try await query.entities(for: [PlaceholderTopicRepository.oldHabit]).map(\.name) == ["Old habit"])
        #expect(try await query.entities(matching: "mo").map(\.name) == ["Mood"])
    }

    @Test func widgetBootstrapServesTheTimelineProvider() async throws {
        let location = try await TestStores.seededLocation()
        defer { TestStores.remove(location) }
        WidgetBootstrap.register(location: location)
        let unconfigured = await TopicProvider.snapshotEntry(for: SelectTopicIntent())
        #expect(unconfigured.topic?.id == PlaceholderTopicRepository.coffee, "gallery shows the first suggestion")

        let mood = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.mood]).first)
        let configured = SelectTopicIntent(topic: mood)
        #expect(await TopicProvider.snapshotEntry(for: configured).topic?.topic.name == "Mood")
        let timeline = await TopicProvider.timeline(for: configured)
        #expect(!timeline.entries.isEmpty && timeline.entries.allSatisfy { $0.topic?.topic.name == "Mood" })
        #expect(await TopicProvider.timeline(for: SelectTopicIntent()).entries.allSatisfy { $0.topic == nil })
    }

    /// Both widgets' timelines put the due change at the device time of the server's boundary
    /// (sync-protocol.md §10): Coffee, every 50 min, last logged 40 min ago by the server's clock,
    /// turns due 10 min from now on either clock; read uncorrected, the device clock 5 min behind
    /// (skew +5 min) or ahead would put it 5 min late or early.
    @Test(arguments: [5.0 * 60, -5.0 * 60])
    func widgetTimelinesFollowTheServersClock(skew: TimeInterval) async throws {
        let location = try await TestStores.seededLocation()
        defer { TestStores.remove(location) }
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        var coffee = try #require(
            try await PlaceholderTopicRepository().topic(id: PlaceholderTopicRepository.coffee)?.topic)
        coffee.schedule = .interval(.init(everyMinutes: 50, timezone: "UTC"))
        coffee.createdAt = now.addingTimeInterval(-86_400)
        coffee.scheduleUpdatedAt = coffee.createdAt
        coffee.lastCapturedAt = now.addingTimeInterval(skew - 40 * 60)
        coffee.revision += 1
        try await store.writer.write { [coffee] db in
            _ = try ServerLayer.upsert(db, topic: coffee)
            try db.execute(sql: "UPDATE sync_state SET skew_ms = ? WHERE id = 1", arguments: [skew * 1000])
        }
        WidgetBootstrap.register(location: location)
        let turnsDue = now.addingTimeInterval(10 * 60)
        let uncorrected = turnsDue.addingTimeInterval(skew)  // the server's boundary read as device time

        let topic = await TopicProvider.timeline(for: SelectTopicIntent(topic: TopicEntity(coffee)), now: now)
        #expect(topic.entries.map(\.date).contains(turnsDue))
        #expect(!topic.entries.map(\.date).contains(uncorrected))
        let list = await DueListProvider.timeline(now: now)
        #expect(list.entries.map(\.date).contains(turnsDue))
        #expect(!list.entries.map(\.date).contains(uncorrected))
        // At that entry Coffee is due; at the first, not yet.
        let atDue = try #require(list.entries.first { $0.date == turnsDue })
        #expect(atDue.topics.first { $0.id == coffee.id }?.due(at: turnsDue)?.isDue == true)
        #expect(list.entries.first?.topics.first { $0.id == coffee.id }?.due(at: now)?.isDue == false)
    }

    /// The app's write path: a number and an option, durably queued in the active store with
    /// source `ios.siri`, the dialog saying what was logged.
    @Test func logEntryIntentLogsThroughTheActiveStore() async throws {
        let location = try await Self.quickLogLocation()
        defer { TestStores.remove(location) }
        let environment = AppEnvironment.bootstrap(location: location, categoryCenter: nil)
        let coffee = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.coffee]).first)
        let logged = try await LogEntryIntent(topic: coffee, number: 2).perform()
        #expect(logged.value == "Coffee: 2 cups")
        let mood = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.mood]).first)
        let good = QuestionOptionEntity(
            topicId: PlaceholderTopicRepository.mood, key: "mood", option: EnumOption(value: "good", label: "Good"))
        #expect(try await LogEntryIntent(topic: mood, option: good).perform().value == "Mood: Good")

        let partitions = try #require(environment.session?.partitions)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        let items = try await store.outbox.items()
        #expect(items.count == 2 && items.allSatisfy { $0.origin == .siri })
    }

    /// Repeat-last re-logs the latest entry; What's Due reads the active store (the fixture topics
    /// have no schedule); OpenRecordIntent opens the record screen through the app's router.
    @Test func repeatLastWhatsDueAndOpenRecordInTheApp() async throws {
        let location = try await Self.quickLogLocation()
        defer { TestStores.remove(location) }
        let environment = AppEnvironment.bootstrap(location: location, categoryCenter: nil)
        let coffee = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.coffee]).first)
        _ = try await LogEntryIntent(topic: coffee, number: 3).perform()
        #expect(try await RepeatLastEntryIntent(topic: coffee).perform().value == "Coffee: 3 cups")

        #expect(try await WhatsDueIntent().perform().value?.isEmpty == true)

        _ = try await OpenRecordIntent(topic: coffee).perform()
        let ref = try #require(TopicLinkRef(PlaceholderTopicRepository.coffee.uuidString))
        #expect(environment.router.path.last == .record(ref))
    }
}
