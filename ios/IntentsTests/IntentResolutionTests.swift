#if canImport(AppIntentsTesting)  // Xcode 27+ SDKs only; CI's Xcode 26 builds an empty bundle.
import AppIntentsTesting
import XCTest

/// PLAN M1 platform proof, app half: the package's App Intents resolve through the system.
/// AppIntentsTesting (Xcode 27) looks the types up in the metadata linkd registered for
/// `com.bahumia.quickr` and runs the queries and the intent through it. linkd folds the widget
/// extension's metadata into that same bundle and has no entry for the extension's own id, so the
/// widget half is `QuickRUITests/WidgetGalleryTests`. Needs an iOS 27 runtime, so this bundle has
/// its own plan (`Intents`), which check-ios runs only on iOS 27+; on iOS 26.0 the hosted
/// `IntentMetadataTests` checks both bundles' metadata instead.
final class IntentResolutionTests: XCTestCase {
    static let app = "com.bahumia.quickr"
    /// The demo store's Water (`DemoStore`: ids are fixed).
    static let water = "00000000-0000-4000-8000-000000000002"
    /// The demo store's active topics, by name (archived "Old habit" is left out of lists).
    static let listed = [
        "Headache", "Medication", "Mood", "Sleep", "Stretch", "Water", "Water the plants", "Workout",
    ]

    override func setUp() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("AppIntentsTesting needs an iOS 27 runtime") }
        // Installs the build, which registers its intents metadata with the system, and keeps the
        // app running over the seeded demo store (`-QuickrDemoStore`): the queries and the intent
        // run in it. Home showing means `start()` opened the store and registered its topics for
        // App Intents.
        try await MainActor.run {
            let app = XCUIApplication()
            app.launchArguments = ["-QuickrDemoStore"]
            app.launch()
            struct DemoStoreDidNotOpen: Error {}
            guard app.staticTexts["home.wordmark"].waitForExistence(timeout: 30) else { throw DemoStoreDidNotOpen() }
        }
    }

    func testTopicEntityResolvesInTheApp() async throws {
        guard #available(iOS 27.0, *) else { return }
        let topics = IntentDefinitions(bundleIdentifier: Self.app).entities["TopicEntity"]
        let all = try await topics.allEntities()
        XCTAssertEqual(try all.map { try $0.name as String }, Self.listed)
        let matched = try await topics.entities(matching: "mood")
        XCTAssertEqual(try matched.map { try $0.name as String }, ["Mood"])
        let byId = try await topics.entities(identifiers: [Self.water])
        XCTAssertEqual(try byId.map { try $0.name as String }, ["Water"])
    }

    func testLogEntryIntentRunsInTheApp() async throws {
        guard #available(iOS 27.0, *) else { return }
        let definitions = IntentDefinitions(bundleIdentifier: Self.app)
        // The topic and the number are given, so nothing is asked (AppIntentsTesting can't answer
        // a prompt); it logs into the demo store and says what it logged.
        let topic = definitions.entities["TopicEntity"].makeReference(identifier: Self.water)
        let intent = definitions.intents["LogEntryIntent"].makeIntent(topic: topic, number: 2.0)
        let result = try await intent.run()
        let summary: String = try result.value
        XCTAssertEqual(summary, "Water: 2 glasses")
    }
}
#endif
