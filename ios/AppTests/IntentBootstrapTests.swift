import AppIntents
import Foundation
import QuickrData
import Testing

@testable import QuickR

/// The intents' data path as each process boots it (`AppEnvironment.bootstrap()` in the app,
/// `WidgetBootstrap.register()` in the widget extension), over a store whose active server holds
/// the fixture topics, then the calls the system and WidgetKit make. These run in the Unit plan on every runtime, iOS 26 CI included; the system-level proofs
/// (AppIntentsTesting, widget-proof.sh) can't run there. Serialized: the registration is
/// process-wide.
@Suite(.serialized) @MainActor struct IntentBootstrapTests {
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

    @Test func logEntryIntentPerformsWithAResolvedTopic() async throws {
        let location = try await TestStores.seededLocation()
        defer { TestStores.remove(location) }
        _ = AppEnvironment.bootstrap(location: location)
        let coffee = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.coffee]).first)
        let result = try await LogEntryIntent(topic: coffee).perform()
        #expect(result.value == "Coffee")
    }
}
