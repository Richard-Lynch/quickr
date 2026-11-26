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
        return TopicEntry(date: now, topic: await topic(id: id, now: now))
    }

    /// Entries at every due change and refresh point (`WidgetTimeline`), and at each pending alert
    /// of the shown run, from which the alert line shows the next one or goes; rebuilt after the
    /// last, or at an alert past the ones followed.
    static func timeline(for configuration: SelectTopicIntent, now: Date = .now) async -> Timeline<TopicEntry> {
        let shown = await topicByAlert(id: configuration.topic?.id, now: now)
        let topic = shown.first?.topic
        let dates = WidgetTimeline.entryDates(for: topic.map { [$0.topic] } ?? [], now: now, skew: topic?.skew ?? 0)
        let entries = WidgetTimeline.entries(dates, changes: shown.map { ($0.from, $0.topic) })
        let alert = shown.last?.topic?.runDisplay?.alert.map { Date(timeIntervalSince1970: $0.at) }
        return Timeline(
            entries: entries.map { TopicEntry(date: $0.date, topic: $0.value) },
            policy: .after(WidgetTimeline.reloadDate(after: entries.map(\.date), now: now, alert: alert)))
    }

    /// The topic from `now`, then from each pending alert of its run on (`WidgetReader.topicByAlert`).
    private static func topicByAlert(id: UUID?, now: Date) async -> [(from: Date, topic: WidgetTopic?)] {
        guard let id, let reader = WidgetBootstrap.reader() else { return [(now, nil)] }
        do {
            let end = now.addingTimeInterval(WidgetTimeline.horizon)
            return try await reader.topicByAlert(id: id, now: now, until: end)
        } catch {
            WidgetBootstrap.log.error("topic \(id) unreadable: \(String(describing: error), privacy: .public)")
            return [(now, nil)]
        }
    }

    private static func topic(id: UUID?, now: Date) async -> WidgetTopic? {
        guard let id, let reader = WidgetBootstrap.reader() else { return nil }
        do {
            return try await reader.topic(id: id, now: now)
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
        .description("Log a topic in one tap, or time it, and see when it's due and what you logged last.")
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

    /// A chip logs its option, ✓ its number, through `WidgetLogIntent`; a timed topic's Start,
    /// Next, Lap and Stop run `RunWidgetIntent` with the run and segment shown (timers.md §11.3).
    /// Both are pinned to the store this snapshot came from, so a widget left over from another
    /// server refuses instead of writing there. Without a scope (no store) the controls open the
    /// record or run screen.
    static func actions(_ topic: WidgetTopic) -> WidgetActions {
        let entity = TopicEntity(topic.topic)
        let scope = topic.scope
        return WidgetActions(
            option: { option in
                guard let scope, case .chips(let question, _) = topic.quick else { return nil }
                return WidgetLogIntent(
                    topic: entity, option: QuestionOptionEntity(topicId: topic.id, key: question.key, option: option),
                    scope: scope)
            },
            number: { value in
                guard let scope else { return nil }
                switch value {
                case .int(let n): return WidgetLogIntent(topic: entity, number: Double(n), scope: scope)
                case .double(let x): return WidgetLogIntent(topic: entity, number: x, scope: scope)
                default: return nil
                }
            },
            single: {
                guard let scope, case .single = topic.quick else { return nil }
                return WidgetLogIntent(topic: entity, scope: scope)
            },
            run: { button in
                guard let scope else { return nil }
                return RunWidgetIntent(button, topicId: topic.id, scope: scope, run: topic.run)
            })
    }
}
