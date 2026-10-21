import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import WidgetKit

struct DueListEntry: TimelineEntry {
    let date: Date
    /// Active topics, due first (empty before the app has a store).
    let topics: [WidgetTopic]
}

struct DueListProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueListEntry {
        DueListEntry(date: .now, topics: [])
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (DueListEntry) -> Void) {
        Task { completion(await Self.snapshotEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<DueListEntry>) -> Void) {
        Task { completion(await Self.timeline()) }
    }

    // The rules, without WidgetKit's `Context`.

    static func snapshotEntry(now: Date = .now) async -> DueListEntry {
        DueListEntry(date: now, topics: await topics(now: now))
    }

    /// Entries at every due change of any listed topic and at refresh points; the order is
    /// recomputed at each entry's date, so a topic moves up when it turns due.
    static func timeline(now: Date = .now) async -> Timeline<DueListEntry> {
        let topics = await topics(now: now)
        let dates = WidgetTimeline.entryDates(for: topics.map(\.topic), now: now, skew: topics.first?.skew ?? 0)
        let entries = dates.map { date in
            DueListEntry(date: date, topics: WidgetTopic.dueFirst(topics, at: date))
        }
        return Timeline(entries: entries, policy: .after(WidgetTimeline.reloadDate(after: dates, now: now)))
    }

    private static func topics(now: Date) async -> [WidgetTopic] {
        guard let reader = WidgetBootstrap.reader() else { return [] }
        do {
            return try await reader.dueList(now: now)
        } catch {
            WidgetBootstrap.log.error("due list unreadable: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

/// What's due, as on the home screen (Home Screen and Lock Screen).
struct DueListWidget: Widget {
    static let kind = "com.bahumia.quickr.due"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: DueListProvider()) { entry in
            DueListEntryView(entry: entry)
        }
        .configurationDisplayName("Due now")
        .description("What's due, then what's coming up.")
        .supportedFamilies([
            .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

private struct DueListEntryView: View {
    let entry: DueListEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        DueListWidgetView(
            topics: entry.topics, date: entry.date, style: WidgetStyle(family: family, renderingMode: renderingMode)
        )
        .containerBackground(for: .widget) { Color.qr.paper }
    }
}
