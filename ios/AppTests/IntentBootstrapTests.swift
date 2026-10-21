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
