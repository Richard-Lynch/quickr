import ActivityKit
import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import WidgetKit

/// The run's Live Activity (timers.md §10.3, Presentation): the Lock Screen and banner, and the
/// Dynamic Island. Everything shown comes from `RunActivityDisplay`; the timers are the system's
/// (`Text(timerInterval:pauseTime:)`), so they tick without updates. The buttons are
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
                    RunActivityTimer(timer: display.totalTimer, ended: nil)
                        .font(.qr(.footnote)).monospacedDigit()
                        .foregroundStyle(Color.qr.muted)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(display.label).font(.qr(.label)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunActivityButtons(buttons: display.islandButtons, context: context)
                }
            } compactLeading: {
                if let number = display.stepNumber {
                    Text(number).font(.qr(.caption)).monospacedDigit()
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

/// The Lock Screen and banner: topic, step and "2 of 5", the segment timer (large) and the total,
/// and the buttons; once ended, "Saved · 7:42" or "Add details".
struct RunActivityLockScreen: View {
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        let display = RunActivityDisplay(state: context.state, topicName: context.attributes.topicName)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.topicName).font(.qr(.label)).lineLimit(1)
                Spacer()
                if let position = display.position {
                    Text(position).font(.qr(.footnote)).foregroundStyle(Color.qr.muted)
                }
            }
            if let ended = display.endedText {
                Text(ended).font(.qr(.title))
            } else {
                Text(display.label).font(.qr(.body)).lineLimit(1)
                HStack(alignment: .lastTextBaseline) {
                    RunActivityTimer(timer: display.segmentTimer, ended: nil)
                        .font(.qr(.largeTitle)).monospacedDigit()
                    Spacer()
                    RunActivityTimer(timer: display.totalTimer, ended: nil)
                        .font(.qr(.footnote)).monospacedDigit()
                        .foregroundStyle(Color.qr.muted)
                }
                RunActivityButtons(buttons: display.buttons, context: context)
            }
        }
        .padding(16)
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

struct RunActivityButtons: View {
    let buttons: [RunActivityDisplay.Button]
    let context: ActivityViewContext<RunActivityAttributes>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(buttons, id: \.self) { button in
                Button(intent: RunActivityButtonIntent(button, attributes: context.attributes, state: context.state)) {
                    Text(button.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(button == .stop ? Color.qr.danger : Color.qr.accentStrong)
                .accessibilityLabel(label(button))
            }
        }
    }

    private func label(_ button: RunActivityDisplay.Button) -> String {
        if button == .next, let next = context.state.nextLabel { return "Next: \(next)" }
        return button.title
    }
}
