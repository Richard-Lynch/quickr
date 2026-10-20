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
    static let coffee = "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c01"

    override func setUp() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("AppIntentsTesting needs an iOS 27 runtime") }
        // Installs the build, which registers its intents metadata with the system.
        await MainActor.run { XCUIApplication().launch() }
    }

    func testTopicEntityResolvesInTheApp() async throws {
        guard #available(iOS 27.0, *) else { return }
        let topics = IntentDefinitions(bundleIdentifier: Self.app).entities["TopicEntity"]
        let all = try await topics.allEntities()
        XCTAssertEqual(try all.map { try $0.name as String }, ["Coffee", "Mood"])
        let matched = try await topics.entities(matching: "cof")
        XCTAssertEqual(try matched.map { try $0.name as String }, ["Coffee"])
        let byId = try await topics.entities(identifiers: [Self.coffee])
        XCTAssertEqual(byId.count, 1)
    }

    func testLogEntryIntentRunsInTheApp() async throws {
        guard #available(iOS 27.0, *) else { return }
        let definitions = IntentDefinitions(bundleIdentifier: Self.app)
        let topic = definitions.entities["TopicEntity"].makeReference(identifier: Self.coffee)
        let intent = definitions.intents["LogEntryIntent"].makeIntent(topic: topic)
        let result = try await intent.run()
        let name: String = try result.value
        XCTAssertEqual(name, "Coffee")
    }
}
#endif
