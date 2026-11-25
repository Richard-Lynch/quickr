import ActivityKit
import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import WidgetKit

/// The run's Live Activity (timers.md §10.3; active-surfaces.md §4): the Lock Screen and banner,
/// and the Dynamic Island. Everything shown comes from `RunActivityDisplay`; the timers are the
/// system's (`Text(timerInterval:pauseTime:)`), so they tick without updates. The buttons are
/// `RunActivityButtonIntent`s, which iOS runs in the app's process.
struct RunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunActivityLockScreen(context: context)
                .activityBackgroundTint(Color.qr.paper)
        } dynamicIsland: { context in
            let display = RunActivityDisplay(state: context.state, topicName: context.attributes.topicName)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RunActivityTimer(timer: display.segmentTimer, ended: display.endedText)
                        .font(.qr(.title)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        RunActivityTimer(timer: display.totalTimer, ended: nil)
                            .font(.qr(.footnote)).monospacedDigit()
                            .foregroundStyle(Color.qr.muted)
                        if let alert = display.alert {
                            RunActivityAlertLine(alert: alert).font(.qr(.caption))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(display.headline).font(.qr(.label)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunActivityIslandButtons(display: display, context: context)
                }
            } compactLeading: {
                if let leading = display.compactLeading {
                    Text(leading).font(.qr(.caption)).monospacedDigit()
                } else {
                    Image(systemName: "timer")
                }
            } compactTrailing: {
                RunActivityTimer(timer: display.segmentTimer, ended: display.endedText)
                    .monospacedDigit()
                    .frame(maxWidth: 56)
            } minimal: {
                RunActivityTimer(timer: display.segmentTimer, ended: nil)
                    .monospacedDigit()
            }
        }
    }
}

/// The Lock Screen and banner (§4.2): topic and "2 of 5", the segment timer (large) with the
/// headline and the total, the alert countdown while one is pending, then the buttons with the
/// primary dominant; once ended, "Saved · 7:42" or "Add details".
///
/// iOS truncates a Lock Screen activity above 160 pt, so the text is two rows and the buttons
/// one: the primary at half the width, Pause/Resume and Stop a quarter each (all ≥ 56 pt tall).
struct RunActivityLockScreen: View {
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        let display = RunActivityDisplay(state: context.state, topicName: context.attributes.topicName)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.topicName).font(.qr(.label)).lineLimit(1)
                Spacer()
                if let badge = badge(display) {
                    Text(badge).font(.qr(.footnote)).monospacedDigit().foregroundStyle(Color.qr.muted)
                }
            }
            if let ended = display.endedText {
                Text(ended).font(.qr(.title))
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    RunActivityTimer(timer: display.segmentTimer, ended: nil)
                        .font(.qr(.largeTitle)).monospacedDigit()
                    Text(display.headline).font(.qr(.body)).lineLimit(1)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        RunActivityTimer(timer: display.totalTimer, ended: nil)
                            .font(.qr(.footnote)).monospacedDigit()
                            .foregroundStyle(Color.qr.muted)
                        if let alert = display.alert {
                            RunActivityAlertLine(alert: alert).font(.qr(.footnote))
                        }
                    }
                }
                RunActivityLockScreenButtons(display: display, context: context)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .dynamicTypeSize(...WidgetStyle.largestTypeSize)
    }

    /// "2 of 5", "L4", or "2 of 5 | L4" (§4.2).
    private func badge(_ display: RunActivityDisplay) -> String? {
        let parts = [display.position, display.lapCounter].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }
}

/// A timer frozen at its pause; the ended text (or nothing) once there is none.
struct RunActivityTimer: View {
    let timer: RunActivityDisplay.Timer?
    let ended: String?

    var body: some View {
        if let timer {
            Text(
                timerInterval: Date(timeIntervalSince1970: timer.start)...Date.distantFuture,
                pauseTime: timer.pausedAt.map { Date(timeIntervalSince1970: $0) }, countsDown: false)
        } else if let ended {
            Text(ended)
        }
    }
}

/// "⏰ Half way · 0:12", counting down to the alert and staying at 0:00 until the next update
/// (the activity cannot sound: timers2.md §9).
struct RunActivityAlertLine: View {
    let alert: RunActivityDisplay.Alert

    var body: some View {
        let at = Date(timeIntervalSince1970: alert.at)
        HStack(spacing: 4) {
            Image(systemName: "alarm")
            Text(alert.label).lineLimit(1)
            Text("·")
            Text(timerInterval: min(Date(), at)...at, countsDown: true).monospacedDigit()
        }
        .foregroundStyle(Color.qr.warn)
        .accessibilityElement(children: .combine)
    }
}

/// The Lock Screen's row (§4.2): the primary prominent at half the width, then Pause/Resume and
/// Stop bordered at a quarter each.
struct RunActivityLockScreenButtons: View {
    let display: RunActivityDisplay
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        ProportionalRow(fractions: [0.5, 0.25, 0.25]) {
            ForEach(display.buttons, id: \.self) { button in
                RunActivityButton(
                    button: button, display: display, context: context, primary: button == display.primary)
            }
        }
    }
}

/// The expanded Dynamic Island's row (§4.3): the primary prominent at two thirds, Stop one third.
struct RunActivityIslandButtons: View {
    let display: RunActivityDisplay
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        ProportionalRow(fractions: [2.0 / 3, 1.0 / 3]) {
            ForEach(display.islandButtons, id: \.self) { button in
                RunActivityButton(
                    button: button, display: display, context: context, primary: button == display.primary)
            }
        }
    }
}

/// A row whose subviews take fixed fractions of its width, whatever their labels measure: the
/// Lock Screen's ½ ¼ ¼ and the island's ⅔ ⅓. As tall as its tallest subview at that width.
struct ProportionalRow: Layout {
    var fractions: [CGFloat]
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let width =
            proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.reduce(gaps) { $0 + $1.sizeThatFits(.unspecified).width }
        let height =
            zip(subviews, widths(in: width, count: subviews.count))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(in: bounds.width, count: subviews.count)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    /// Each subview's share of `width` less the gaps; a subview past `fractions` gets none.
    private func widths(in width: CGFloat, count: Int) -> [CGFloat] {
        let available = max(0, width - spacing * CGFloat(max(0, count - 1)))
        return (0..<count).map { available * (fractions.indices.contains($0) ? fractions[$0] : 0) }
    }
}

/// One button: the primary `.borderedProminent` in the accent (M3's theme tint later), the
/// others `.bordered`, Stop in the danger colour; titles and VoiceOver labels per §1.3.
struct RunActivityButton: View {
    let button: RunActivityDisplay.Button
    let display: RunActivityDisplay
    let context: ActivityViewContext<RunActivityAttributes>
    let primary: Bool

    var body: some View {
        let intent = RunActivityButtonIntent(button, attributes: context.attributes, state: context.state)
        let label = Text(display.title(for: button))
            .font(.qr(primary ? .label : .callout))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: primary ? 44 : 32)
        Group {
            if primary {
                Button(intent: intent) { label }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.qr.accentStrong)
            } else {
                Button(intent: intent) { label }
                    .buttonStyle(.bordered)
                    .tint(button == .stop ? Color.qr.danger : Color.qr.accentStrong)
            }
        }
        .accessibilityLabel(display.spokenTitle(for: button))
    }
}
