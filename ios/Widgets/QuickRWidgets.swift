import SwiftUI
import WidgetKit

/// M0 placeholder widget. The quick-log and due-list widgets and Controls arrive in M4.
@main
struct QuickRWidgets: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.bahumia.quickr.placeholder", provider: PlaceholderProvider()) { _ in
            Text("quickR")
                .font(.headline)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("quickR")
        .description("Placeholder")
        .supportedFamilies([.systemSmall])
    }
}
