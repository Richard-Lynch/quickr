#if DEBUG
import QuickrCore
import QuickrUI
import SwiftUI
import WidgetKit

/// `-QuickrWidgetGallery <home|lock> [tinted]`: the widget views at their sizes over the demo
/// topics, for screenshots and UI checks without SpringBoard (whose automation stalls). Same views
/// and styles as the extension. "tinted" approximates the system's one-colour modes (Home Screen
/// tinted, Lock Screen): the accented style on a dark tinted plate, desaturated; the system's own
/// rendering is checked on a device (M4-DEV).
struct WidgetGalleryView: View {
    enum Page: String { case home, lock }

    let page: Page
    let tinted: Bool
    let now = Date()

    private var topics: [WidgetTopic] {
        DemoStore.topics(now: now).filter { $0.status == .active }.map { topic in
            let quick = QuickLog(questions: topic.questions)
            return WidgetTopic(
                topic: topic, quick: quick,
                lastAnswer: quick.flatMap { DemoStore.answers[topic.slug]?[$0.question.key] },
                queued: topic.slug == "water" ? 1 : 0)
        }
    }

    private func topic(_ slug: String) -> WidgetTopic? { topics.first { $0.topic.slug == slug } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch page {
                case .home: home
                case .lock: lock
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tinted ? Color(white: 0.12) : Color.qr.sunken)
        .accessibilityIdentifier("widgets.gallery")
    }

    @ViewBuilder private var home: some View {
        HStack(spacing: 16) {
            frame(.systemSmall, "widget.small.headache") {
                TopicWidgetView(topic: topic("headache"), date: now, style: $0)
            }
            frame(.systemSmall, "widget.small.water") { TopicWidgetView(topic: topic("water"), date: now, style: $0) }
        }
        frame(.systemMedium, "widget.medium.headache") {
            TopicWidgetView(topic: topic("headache"), date: now, style: $0)
        }
        frame(.systemMedium, "widget.medium.due") { DueListWidgetView(topics: topics, date: now, style: $0) }
        frame(.systemLarge, "widget.large.due") { DueListWidgetView(topics: topics, date: now, style: $0) }
    }

    @ViewBuilder private var lock: some View {
        frame(.accessoryRectangular, "widget.rect.water") {
            TopicWidgetView(topic: topic("water"), date: now, style: $0)
        }
        frame(.accessoryRectangular, "widget.rect.due") { DueListWidgetView(topics: topics, date: now, style: $0) }
        HStack(spacing: 16) {
            frame(.accessoryCircular, "widget.circle.headache") {
                TopicWidgetView(topic: topic("headache"), date: now, style: $0)
            }
            frame(.accessoryCircular, "widget.circle.due") { DueListWidgetView(topics: topics, date: now, style: $0) }
        }
        frame(.accessoryInline, "widget.inline.due") { DueListWidgetView(topics: topics, date: now, style: $0) }
        frame(.accessoryInline, "widget.inline.water") { TopicWidgetView(topic: topic("water"), date: now, style: $0) }
    }

    /// One widget at its family's size (iPhone 16 Pro Max), with the widget's container.
    private func frame(
        _ family: WidgetFamily, _ id: String, @ViewBuilder content: (WidgetStyle) -> some View
    ) -> some View {
        let lock = [.accessoryRectangular, .accessoryCircular, .accessoryInline].contains(family)
        let style = WidgetStyle(family: family, isAccented: tinted || lock)
        let size: CGSize =
            switch family {
            case .systemSmall: CGSize(width: 170, height: 170)
            case .systemMedium: CGSize(width: 364, height: 170)
            case .systemLarge: CGSize(width: 364, height: 382)
            case .accessoryRectangular: CGSize(width: 172, height: 76)
            case .accessoryCircular: CGSize(width: 76, height: 76)
            default: CGSize(width: 300, height: 22)
            }
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(describing: family)).font(.caption2).foregroundStyle(.secondary)
            content(style)
                .padding(lock ? 0 : 16)
                .frame(width: size.width, height: size.height)
                .background {
                    if lock {
                        Color.clear
                    } else {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(tinted ? Color(white: 0.2) : Color.qr.paper)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: lock ? 0 : 22, style: .continuous))
                .foregroundStyle(lock || tinted ? Color.white : Color.primary)
                .saturation(lock || tinted ? 0 : 1)
                .environment(\.colorScheme, lock || tinted ? .dark : colorScheme)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(id)
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}
#endif
