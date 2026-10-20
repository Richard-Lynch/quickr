import AppIntents
import Foundation

// No `AppIntentsPackage` here, on purpose. Xcode merges this static library's intents metadata into
// every binary that links it. An `includedPackages` entry for it makes iOS 26.0's linkd look the
// package type up among the binary's *imported* symbols; a static library's never are, so linkd
// logs "did not match any imported symbol" and drops the whole bundle's intents (iOS 27 accepts
// it). `IntentMetadataTests` guards this.

/// Logs an entry for a quick-log topic. SKEL stub: it resolves the topic and answers with a dialog
/// but writes nothing; INTENTS adds the option or number, validation and the outbox write.
public struct LogEntryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Log Entry"
    public static let description = IntentDescription("Logs an entry for a topic in quickR.")

    @Parameter(title: "Topic") public var topic: TopicEntity

    public static var parameterSummary: some ParameterSummary { Summary("Log \(\.$topic)") }

    public init() {}

    public init(topic: TopicEntity) {
        self.topic = topic
    }

    /// Returns the resolved topic's name, so tests can see what the system passed in.
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        .result(value: topic.name, dialog: "\(topic.name) isn't logged yet: this is a preview build.")
    }
}

/// The topic a widget shows. WIDGETS builds the real widgets on it.
public struct SelectTopicIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose Topic"
    public static let description = IntentDescription("The topic this widget shows.")

    @Parameter(title: "Topic") public var topic: TopicEntity?

    public init() {}

    public init(topic: TopicEntity?) {
        self.topic = topic
    }
}
