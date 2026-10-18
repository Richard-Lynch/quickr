import AppIntents
import Foundation
import QuickrData
import Testing

@testable import QuickR

/// The intents' data path as each process boots it (`AppEnvironment.bootstrap()` in the app,
/// `WidgetBootstrap.register()` in the widget extension), then the calls the system and WidgetKit
/// make. These run in the Unit plan on every runtime, iOS 26 CI included; the system-level proofs
/// (AppIntentsTesting, widget-proof.sh) can't run there. Serialized: the registration is
/// process-wide.
@Suite(.serialized) @MainActor struct IntentBootstrapTests {
    @Test func appBootstrapServesTheTopicQuery() async throws {
        _ = AppEnvironment.bootstrap()
        let query = TopicEntityQuery()
        #expect(try await query.suggestedEntities().map(\.name) == ["Coffee", "Mood"])
        #expect(try await query.allEntities().map(\.name) == ["Coffee", "Mood"])
        #expect(try await query.entities(for: [PlaceholderTopicRepository.oldHabit]).map(\.name) == ["Old habit"])
        #expect(try await query.entities(matching: "mo").map(\.name) == ["Mood"])
    }

    @Test func widgetBootstrapServesTheTimelineProvider() async throws {
        WidgetBootstrap.register()
        let unconfigured = await TopicProvider.snapshotEntry(for: SelectTopicIntent())
        #expect(unconfigured.topic?.id == PlaceholderTopicRepository.coffee, "gallery shows the first suggestion")

        let mood = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.mood]).first)
        let configured = SelectTopicIntent(topic: mood)
        #expect(await TopicProvider.snapshotEntry(for: configured).topic?.name == "Mood")
        #expect(TopicProvider.timeline(for: configured).entries.map(\.topic?.name) == ["Mood"])
        #expect(TopicProvider.timeline(for: SelectTopicIntent()).entries.map(\.topic?.name) == [nil])
    }

    @Test func logEntryIntentPerformsWithAResolvedTopic() async throws {
        _ = AppEnvironment.bootstrap()
        let coffee = try #require(try await TopicEntityQuery().entities(for: [PlaceholderTopicRepository.coffee]).first)
        let result = try await LogEntryIntent(topic: coffee).perform()
        #expect(result.value == "Coffee")
    }
}
