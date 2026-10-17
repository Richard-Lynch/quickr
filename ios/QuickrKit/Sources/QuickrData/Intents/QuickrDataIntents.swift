import AppIntents
import Foundation

/// The package's App Intents types. Every target that uses them (the app and the widget extension)
/// lists this exactly once in its own `AppIntentsPackage.includedPackages`; nothing else may
/// include it, or the metadata is duplicated and the intents stop resolving.
public struct QuickrDataIntentsPackage: AppIntentsPackage {}

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
