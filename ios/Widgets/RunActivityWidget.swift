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
                .activityBackgroundTint(RunActivityTheme.background(context.attributes.theme))
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
                            RunAlertLine(alert: alert).font(.qr(.caption))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(display.headline).font(.qr(.label)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunActivityButtonRow.island(display) { button, primary in
                        RunActivityButton(button: button, display: display, context: context, primary: primary)
                    }
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

/// The Lock Screen and banner (§4.2), drawn by QuickrUI's `RunActivityLockScreenContent` (which
/// the app's widget gallery shows too) with this extension's intent buttons; in the topic's theme
/// (appearance.md §6.5) from `attributes.appearance`.
///
/// iOS truncates a Lock Screen activity above 160 pt, so the text is two rows and the buttons
/// one: the primary (≥ 56 pt tall) at half the width, Pause/Resume and Stop (≥ 44 pt) a quarter
/// each.
struct RunActivityLockScreen: View {
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        let display = RunActivityDisplay(state: context.state, topicName: context.attributes.topicName)
        let theme = context.attributes.theme
        RunActivityLockScreenContent(display: display, theme: theme) {
            RunActivityButtonRow.lockScreen(display) { button, primary in
                RunActivityButton(button: button, display: display, context: context, primary: primary)
            }
        }
    }
}

extension RunActivityAttributes {
    /// The topic's theme at start (appearance.md §6.5); the default without an appearance.
    var theme: TopicTheme { TopicTheme(appearance: appearance, name: topicName) }
}

/// One button: the primary `.borderedProminent` in the topic's tint (the accent-strong without a
/// colour), the others `.bordered`, Stop in the danger colour; titles and VoiceOver labels per §1.3.
struct RunActivityButton: View {
    let button: RunActivityDisplay.Button
    let display: RunActivityDisplay
    let context: ActivityViewContext<RunActivityAttributes>
    let primary: Bool

    var body: some View {
        let intent = RunActivityButtonIntent(button, attributes: context.attributes, state: context.state)
        Button(intent: intent) { RunActivityButtonLabel(display.title(for: button), primary: primary) }
            .runActivityButtonStyle(button, primary: primary, theme: context.attributes.theme)
            .accessibilityLabel(display.spokenTitle(for: button))
    }
}
