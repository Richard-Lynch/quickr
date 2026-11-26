#if DEBUG
import QuickrCore
import QuickrUI
import SwiftUI
import WidgetKit

/// `-QuickrWidgetGallery <home|lock> [tinted] [outdated]`: the widget views at their sizes over the demo
/// topics, for screenshots and UI checks without SpringBoard (whose automation stalls). Same views
/// and styles as the extension. "tinted" approximates the system's one-colour modes (Home Screen
/// tinted, Lock Screen): the accented style on a dark tinted plate, desaturated; the system's own
/// rendering is checked on a device (M4-DEV). "outdated" shows them while this build is too old for
/// the server ("Update quickR", client-versions.md §4.1).
struct WidgetGalleryView: View {
    enum Page: String { case home, lock }

    let page: Page
    let tinted: Bool
    var outdated = false
    let now = Date()

    private var topics: [WidgetTopic] {
        DemoStore.topics(now: now).filter { $0.status == .active }.map { topic in
            let quick = QuickLog(questions: topic.questions)
            return WidgetTopic(
                topic: topic, quick: quick,
                lastAnswer: quick?.question.flatMap { DemoStore.answers[topic.slug]?[$0.key] },
                queued: topic.slug == "water" ? 1 : 0, updateRequired: outdated)
        }
    }

    private func topic(_ slug: String) -> WidgetTopic? { topics.first { $0.topic.slug == slug } }

    /// A timed topic with an open run (the demo store has none), as the widget reader would show
    /// it: `steps` is the pinned version's; `open` the segment, as the Live Activity's content
    /// state; `lap` a typed lap's type and closed laps; `alert` a pending alert's label and
    /// seconds to go. No store, so its chips open the run screen.
    private func timed(
        slug: String, name: String, steps: [TopicTimer.Step], open: (label: String, stepIndex: Int?, next: String?),
        paused: Bool = false, lap: (type: String, closed: Int)? = nil, alert: (label: String, in: Double)? = nil
    ) -> WidgetTopic? {
        guard var topic = topics.first?.topic else { return nil }
        topic.slug = slug
        topic.name = name
        topic.questions = []
        topic.timer = TopicTimer(steps: steps)
        let startedAt = now.timeIntervalSince1970 - 104
        let run = RunActivityState(
            runId: "00000000-0000-4000-8000-0000000000aa", revision: 3, status: paused ? "paused" : "running",
            startedAt: startedAt, seg: 3, segStartedAt: startedAt + 63, label: open.label, stepIndex: open.stepIndex,
            stepCount: steps.count, nextLabel: open.next, pausedAt: paused ? startedAt + 90 : nil,
            pausedMsBeforeSeg: 0, pausedMsInSeg: 0, endedAt: nil, activeMs: nil, lapType: lap?.type,
            lapCount: lap?.closed, alertAt: alert.map { now.timeIntervalSince1970 + $0.in }, alertLabel: alert?.label)
        return WidgetTopic(
            topic: topic, quick: nil, lastAnswer: nil, hasOpenRun: true, run: run, updateRequired: outdated)
    }

    /// A stopwatch (no steps) on its third lap: Lap is the primary; without lap types the small
    /// size's one Auto chip is Stop (§5.3). `typed`: the lap it opens is "Rest" (`next_label`
    /// during a lap, M1-LA-STATE), so the primary reads "Lap → Rest" once I2-LA lands the §4.1
    /// rule in `RunActivityDisplay` (today's v1 rule reads that fixture as Next).
    private func smoke(typed: Bool = false) -> WidgetTopic? {
        timed(
            slug: typed ? "smoke-typed" : "smoke", name: "Smoke", steps: [],
            open: (label: "Lap 3", stepIndex: nil, next: typed ? "Rest" : nil))
    }

    /// Intervals on a typed lap, its fourth: "Rest 2 · lap 4", "Go" due in 5 minutes (the alert
    /// line under the total, active-surfaces.md §5.1). Lap reads "Lap" while the widget's lap
    /// types wait for M1's Auto (`WidgetTopic.isLapTyped`).
    private func intervals() -> WidgetTopic? {
        timed(
            slug: "intervals", name: "Intervals", steps: [], open: (label: "Rest 2", stepIndex: nil, next: "Run"),
            lap: (type: "rest", closed: 3), alert: (label: "Go", in: 300))
    }

    /// A step run on its first step, Breakfast next; `paused` freezes its timers.
    private func morning(paused: Bool = false) -> WidgetTopic? {
        timed(
            slug: "morning", name: "Morning", steps: Self.morningSteps,
            open: (label: "Shower", stepIndex: 0, next: "Breakfast"), paused: paused)
    }

    private static let morningSteps = [
        TopicTimer.Step(key: "shower", label: "Shower"), TopicTimer.Step(key: "breakfast", label: "Breakfast"),
        TopicTimer.Step(key: "out", label: "Out"),
    ]

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
        // The Lock Screen's widgets sit on the wallpaper (dark here); tinted Home Screen on a dark one.
        .background(tinted || page == .lock ? Color(white: 0.12) : Color.qr.sunken)
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
        // Timed (active-surfaces.md §5.1): the lap primary with Stop beside it (plain, and typed
        // "Lap → Rest"); the small size's one Auto chip (§5.3: Stop on a stopwatch without lap
        // types, Next while a step remains); paused.
        frame(.systemMedium, "widget.medium.timed.lap") { TopicWidgetView(topic: smoke(), date: now, style: $0) }
        frame(.systemMedium, "widget.medium.timed.typedlap") {
            TopicWidgetView(topic: smoke(typed: true), date: now, style: $0)
        }
        HStack(spacing: 16) {
            frame(.systemSmall, "widget.small.timed.auto") { TopicWidgetView(topic: smoke(), date: now, style: $0) }
            frame(.systemSmall, "widget.small.timed.step") { TopicWidgetView(topic: morning(), date: now, style: $0) }
        }
        frame(.systemMedium, "widget.medium.timed.paused") {
            TopicWidgetView(topic: morning(paused: true), date: now, style: $0)
        }
        // A typed lap's headline and the pending alert under the total (§5.1).
        frame(.systemMedium, "widget.medium.timed.alert") {
            TopicWidgetView(topic: intervals(), date: now, style: $0)
        }
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
