#if DEBUG
import QuickrData
import QuickrUI
import SwiftUI

/// `-QuickrTilesDemo`: every topic of the active store as a tile, in store order, until HOME's
/// list replaces it. With `-QuickrDemoStore` it shows `DemoStore`'s topics (screenshots, the
/// tile UI tests).
struct TilesDemoView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var topics: [ViewTopic] = []
    @State private var opened: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(topics) { topic in
                        TopicTile(
                            topic: topic, now: context.date, onOpen: { opened = "open \(topic.topic.slug)" },
                            onRecord: { opened = "record \(topic.topic.slug)" })
                    }
                    if let opened {
                        Text(opened).font(.footnote).foregroundStyle(.qr.muted).accessibilityIdentifier("tiles.opened")
                    }
                }
                .padding(16)
            }
            .qrPaperBackground()
        }
        .task(id: environment.session?.binding) {
            guard let session = environment.session, let store = session.store else { return }
            do {
                for try await topics in store.observeTopics(refresh: session.refresh.stream()) { self.topics = topics }
            } catch {}
        }
    }
}
#endif
