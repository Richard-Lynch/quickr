import QuickrData
import SwiftUI
import WidgetKit

struct TopicEntry: TimelineEntry {
    let date: Date
    let topic: TopicEntity?
}

struct TopicProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TopicEntry {
        TopicEntry(date: .now, topic: nil)
    }

    func snapshot(for configuration: SelectTopicIntent, in context: Context) async -> TopicEntry {
        await Self.snapshotEntry(for: configuration)
    }

    func timeline(for configuration: SelectTopicIntent, in context: Context) async -> Timeline<TopicEntry> {
        Self.timeline(for: configuration)
    }

    // The rules, without WidgetKit's `Context` (which tests can't make).

    /// The gallery asks before the user has chosen a topic: show the first suggestion, read
    /// through `TopicEntityQuery` in this process.
    static func snapshotEntry(for configuration: SelectTopicIntent) async -> TopicEntry {
        let suggested = try? await TopicEntityQuery().suggestedEntities().first
        return TopicEntry(date: .now, topic: configuration.topic ?? suggested)
    }

    static func timeline(for configuration: SelectTopicIntent) -> Timeline<TopicEntry> {
        Timeline(entries: [TopicEntry(date: .now, topic: configuration.topic)], policy: .never)
    }
}

/// SKEL's minimal widget: an `AppIntentConfiguration` choosing a `TopicEntity`, showing its name.
struct TopicWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "com.bahumia.quickr.topic", intent: SelectTopicIntent.self, provider: TopicProvider()
        ) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text("quickR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.topic?.name ?? "Choose a topic")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Topic")
        .description("Shows a topic.")
        .supportedFamilies([.systemSmall])
    }
}
