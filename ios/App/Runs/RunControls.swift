import QuickrCore
import QuickrUI
import SwiftUI

// The run screen's controls (active-surfaces.md §2.2, §2.3): one big primary, a row of
// secondaries, and the rest in the toolbar's overflow menu. `RunControlsLayout` places every
// action once, by role; the only per-kind code here is the title and icon table (§1.3).

/// The primary (`hero`, full width, ≥ 72 pt) and the secondaries (56 pt, equal widths; stacked at
/// accessibility text sizes). Disabled while `busy` (the tap cooldown), so the layout never
/// changes under the finger.
struct RunControls: View {
    let layout: RunControlsLayout
    /// The topic's name, for the spoken labels ("Stop Morning").
    let topic: String
    let busy: Bool
    let perform: (RunAction) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var primaryIcon: CGFloat = 28

    var body: some View {
        VStack(spacing: 10) {
            if let primary = layout.primary {
                Button {
                    perform(primary)
                } label: {
                    Label {
                        Text(primary.title)
                    } icon: {
                        Image(systemName: primary.icon).font(.system(size: primaryIcon, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.qr(.primary, size: .hero))
                .disabled(busy || !primary.enabled)
                .accessibilityLabel(primary.spoken(topic: topic))
                .accessibilityIdentifier(primary.primaryIdentifier)
            }
            if !layout.secondaries.isEmpty {
                let stack =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                stack {
                    ForEach(layout.secondaries) { action in
                        Button {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.icon)
                                .foregroundStyle(action.kind == .stop ? Color.qr.danger : .qr.ink)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.qr(.secondary, size: .large))
                        .disabled(busy || !action.enabled)
                        .accessibilityLabel(action.spoken(topic: topic))
                        .accessibilityIdentifier("run.\(action.id)")
                    }
                }
            }
        }
    }
}

/// The toolbar's "More" menu (`run.menu`): the layout's overflow, destructive last. Nothing when
/// it is empty.
struct RunOverflowMenu: View {
    let actions: [RunAction]
    let topic: String
    let busy: Bool
    let perform: (RunAction) -> Void

    var body: some View {
        if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(role: action.role == .destructive ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.icon)
                    }
                    .disabled(busy || !action.enabled)
                    .accessibilityLabel(action.spoken(topic: topic))
                    .accessibilityIdentifier("run.\(action.id)")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("run.menu")
        }
    }
}

// MARK: - Titles and icons (active-surfaces.md §1.3)

extension RunAction {
    /// The button's title. `…` marks a confirmation.
    var title: String {
        switch kind {
        case .start: "Start"
        // `next("Next")` is the steps-unknown fallback (timers2.md §10): a plain "Next".
        case .next(let label): label == "Next" ? label : "Next: \(label)"
        case .lap(let next): next.map { "Lap → \($0)" } ?? "Lap"
        case .skip(let label): "Skip \(label)"
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop"
        case .addDetails: "Add details"
        case .reopen: "Resume run"
        case .revert: "Undo resume…"
        case .discard: "Discard run…"
        }
    }

    /// An SF Symbol.
    var icon: String {
        switch kind {
        case .start, .resume: "play"
        case .next: "chevron.right"
        case .lap: "flag"
        case .skip: "forward.end"
        case .pause: "pause"
        case .stop: "stop"
        case .addDetails: "pencil"
        case .reopen: "arrow.uturn.backward"
        case .revert: "arrow.uturn.forward"
        case .discard: "trash"
        }
    }

    /// What VoiceOver reads.
    func spoken(topic: String) -> String {
        switch kind {
        case .start: "Start \(topic)"
        case .lap(let next?): "Lap, then \(next)"
        case .stop: "Stop \(topic)"
        case .addDetails: "Add details to \(topic)"
        case .reopen: "Resume the last run of \(topic)"
        case .revert: "Undo the resume and keep the stop"
        case .discard: "Discard run"
        case .next, .lap, .skip, .pause, .resume: title
        }
    }

    /// The primary's accessibility id: `run.start` idle, `run.addDetails` finishing, else
    /// `run.primary` (Next or Lap, whichever the rule picks).
    var primaryIdentifier: String {
        switch kind {
        case .start, .addDetails: "run.\(id)"
        default: "run.primary"
        }
    }
}
