import OSLog
import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import WidgetKit

struct TopicEntry: TimelineEntry {
    let date: Date
    /// The chosen topic as the store has it now; nil when none is chosen, or it's gone.
    let topic: WidgetTopic?
}

struct TopicProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TopicEntry {
        TopicEntry(date: .now, topic: nil)
    }

    func snapshot(for configuration: SelectTopicIntent, in context: Context) async -> TopicEntry {
        await Self.snapshotEntry(for: configuration)
    }

    func timeline(for configuration: SelectTopicIntent, in context: Context) async -> Timeline<TopicEntry> {
        await Self.timeline(for: configuration)
    }

    // The rules, without WidgetKit's `Context` (which tests can't make).

    /// The gallery asks before the user has chosen a topic: show the first suggestion, read
    /// through `TopicEntityQuery` in this process.
    static func snapshotEntry(for configuration: SelectTopicIntent, now: Date = .now) async -> TopicEntry {
        var id = configuration.topic?.id
        if id == nil {
            do {
                id = try await TopicEntityQuery().suggestedEntities().first?.id
            } catch {
                WidgetBootstrap.log.error("no suggested topic: \(String(describing: error), privacy: .public)")
            }
        }
        return TopicEntry(date: now, topic: await topic(id: id))
    }

    /// Entries at every due change and refresh point (`WidgetTimeline`); rebuilt after the last.
    static func timeline(for configuration: SelectTopicIntent, now: Date = .now) async -> Timeline<TopicEntry> {
        let topic = await topic(id: configuration.topic?.id)
        let dates = WidgetTimeline.entryDates(for: topic.map { [$0.topic] } ?? [], now: now)
        return Timeline(
            entries: dates.map { TopicEntry(date: $0, topic: topic) },
            policy: .after(WidgetTimeline.reloadDate(after: dates, now: now)))
    }

    private static func topic(id: UUID?) async -> WidgetTopic? {
        guard let id, let reader = WidgetBootstrap.reader() else { return nil }
        do {
            return try await reader.topic(id: id)
        } catch {
            WidgetBootstrap.log.error("topic \(id) unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// The per-topic quick-log widget (Home Screen and Lock Screen), configured with a `TopicEntity`.
struct TopicWidget: Widget {
    static let kind = "com.bahumia.quickr.topic"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectTopicIntent.self, provider: TopicProvider()) { entry in
            TopicWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Topic")
        .description("Log a topic in one tap, see when it's due and what you logged last.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

struct TopicWidgetEntryView: View {
    let entry: TopicEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        TopicWidgetView(
            topic: entry.topic, date: entry.date, style: WidgetStyle(family: family, renderingMode: renderingMode),
            actions: entry.topic.map(Self.actions)
        )
        .containerBackground(for: .widget) { Color.qr.paper }
    }

    /// INTENTS' fully specified logs: a chip logs its option, ✓ the last number. No prompt.
    static func actions(_ topic: WidgetTopic) -> WidgetActions {
        let entity = TopicEntity(topic.topic)
        return WidgetActions(
            option: { option in
                guard case .chips(let question, _) = topic.quick else { return nil }
                return LogEntryIntent(
                    topic: entity, option: QuestionOptionEntity(topicId: topic.id, key: question.key, option: option))
            },
            number: { value in
                switch value {
                case .int(let n): LogEntryIntent(topic: entity, number: Double(n))
                case .double(let x): LogEntryIntent(topic: entity, number: x)
                default: nil
                }
            })
    }
}
