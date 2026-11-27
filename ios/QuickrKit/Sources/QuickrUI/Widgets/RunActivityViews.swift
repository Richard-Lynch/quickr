#if os(iOS)
import QuickrCore
import SwiftUI

/// The run's Live Activity on the Lock Screen and banner (active-surfaces.md §4.2), without its
/// buttons: topic and "2 of 5", the segment timer (large) with the headline and the total, the
/// alert countdown while one is pending, then `buttons`; once ended, "Saved · 7:42" or "Add
/// details". Here, not in the extension, so the app's widget gallery draws it too (#202); the
/// extension passes its intent buttons, the gallery plain ones.
///
/// The topic's theme (appearance.md §6.5) puts its glyph before the name; the background
/// (``RunActivityTheme/background``) and the primary's tint (``RunActivityTheme/primaryTint``)
/// are set by the caller and the buttons.
public struct RunActivityLockScreenContent<Buttons: View>: View {
    let display: RunActivityDisplay
    let theme: TopicTheme
    let buttons: Buttons

    public init(display: RunActivityDisplay, theme: TopicTheme, @ViewBuilder buttons: () -> Buttons) {
        self.display = display
        self.theme = theme
        self.buttons = buttons()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if TopicChrome(theme).glyph != nil {
                    TopicGlyphView(theme: theme, size: 18, fallbackInitial: theme.isTinted)
                }
                Text(display.topicName).font(.qr(.label)).lineLimit(1)
                Spacer()
                if let badge = Self.badge(display) {
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
                            RunAlertLine(alert: alert).font(.qr(.footnote))
                        }
                    }
                }
                buttons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .dynamicTypeSize(...WidgetStyle.largestTypeSize)
    }

    /// "2 of 5", "L4", or "2 of 5 | L4" (§4.2).
    static func badge(_ display: RunActivityDisplay) -> String? {
        let parts = [display.position, display.lapCounter].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }
}

/// The Live Activity's colours from the topic's theme (appearance.md §6.5): set at start, so a
/// colour change shows at the next run.
public enum RunActivityTheme {
    /// The Lock Screen's background: the paper, or the topic's `tintSoft` when it has a colour.
    public static func background(_ theme: TopicTheme) -> Color {
        theme.isTinted ? theme.tintSoft : .qr.paper
    }

    /// The primary button's tint: the accent-strong, or the topic's `tint` when it has a colour.
    public static func primaryTint(_ theme: TopicTheme) -> Color {
        theme.isTinted ? theme.tint : .qr.accentStrong
    }
}

/// The Lock Screen's row (§4.2): the primary prominent at half the width, then Pause/Resume and
/// Stop bordered at a quarter each. `button` draws one, given whether it is the primary.
public struct RunActivityButtonRow<Button: View>: View {
    let buttons: [RunActivityDisplay.Button]
    let fractions: [CGFloat]
    let primary: RunActivityDisplay.Button?
    let button: (RunActivityDisplay.Button, Bool) -> Button

    /// The Lock Screen's ½ ¼ ¼.
    public static func lockScreen(
        _ display: RunActivityDisplay, @ViewBuilder button: @escaping (RunActivityDisplay.Button, Bool) -> Button
    ) -> Self {
        Self(buttons: display.buttons, fractions: [0.5, 0.25, 0.25], primary: display.primary, button: button)
    }

    /// The expanded Dynamic Island's ⅔ ⅓ (§4.3).
    public static func island(
        _ display: RunActivityDisplay, @ViewBuilder button: @escaping (RunActivityDisplay.Button, Bool) -> Button
    ) -> Self {
        Self(buttons: display.islandButtons, fractions: [2.0 / 3, 1.0 / 3], primary: display.primary, button: button)
    }

    public var body: some View {
        ProportionalRow(fractions: fractions) {
            ForEach(buttons, id: \.self) { item in button(item, item == primary) }
        }
    }
}

extension View {
    /// One Live Activity button's look: the primary `.borderedProminent` in the topic's tint
    /// (``RunActivityTheme/primaryTint(_:)``), the others `.bordered`, Stop in the danger colour.
    @ViewBuilder public func runActivityButtonStyle(
        _ button: RunActivityDisplay.Button, primary: Bool, theme: TopicTheme
    ) -> some View {
        if primary {
            buttonStyle(.borderedProminent).controlSize(.large).tint(RunActivityTheme.primaryTint(theme))
        } else {
            buttonStyle(.bordered).tint(button == .stop ? Color.qr.danger : Color.qr.accentStrong)
        }
    }
}

/// A button's label: titles per §1.3, at least 44 pt (primary) or 32 pt tall.
public struct RunActivityButtonLabel: View {
    let title: String
    let primary: Bool

    public init(_ title: String, primary: Bool) {
        self.title = title
        self.primary = primary
    }

    public var body: some View {
        Text(title)
            .font(.qr(primary ? .label : .callout))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: primary ? 44 : 32)
    }
}

/// A timer frozen at its pause; the ended text (or nothing) once there is none.
public struct RunActivityTimer: View {
    let timer: RunActivityDisplay.Timer?
    let ended: String?

    public init(timer: RunActivityDisplay.Timer?, ended: String?) {
        self.timer = timer
        self.ended = ended
    }

    public var body: some View {
        if let timer {
            Text(
                timerInterval: Date(timeIntervalSince1970: timer.start)...Date.distantFuture,
                pauseTime: timer.pausedAt.map { Date(timeIntervalSince1970: $0) }, countsDown: false)
        } else if let ended {
            Text(ended)
        }
    }
}

/// A row whose subviews take fixed fractions of its width, whatever their labels measure: the
/// Lock Screen's ½ ¼ ¼ and the island's ⅔ ⅓. As tall as its tallest subview at that width.
public struct ProportionalRow: Layout {
    var fractions: [CGFloat]
    var spacing: CGFloat = 8

    public init(fractions: [CGFloat], spacing: CGFloat = 8) {
        self.fractions = fractions
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
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

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
#endif
