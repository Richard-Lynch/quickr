import QuickrCore
import QuickrUI
import SwiftUI

// The run screen's controls (active-surfaces.md §2.2, §2.3): one big primary, a row of
// secondaries, and the rest in the toolbar's overflow menu. `RunControlsLayout` places every
// action once, by role; titles, icons and VoiceOver text come from QuickrUI's `RunActionLabel`
// (§1.3).

/// The primary (`hero`, full width, ≥ 72 pt) and the secondaries (56 pt, equal widths; stacked at
/// accessibility text sizes). Disabled while `busy` (the tap cooldown), so the layout never
/// changes under the finger.
struct RunControls: View {
    let layout: RunControlsLayout
    /// The topic's name, for the spoken labels ("Stop Morning").
    let topic: String
    let busy: Bool
    /// The stopped run's total: an idle screen's `reopen` reads "Resume · 1:44" (§2.4), not the
    /// generic "Resume run".
    var reopenTotalMs: Int?
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
                        Image(systemName: primary.systemImage).font(.system(size: primaryIcon, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.qr(.primary, size: .hero))
                .disabled(busy || !primary.enabled)
                .accessibilityLabel(primary.spokenTitle(topic: topic))
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
                            Label(title(action), systemImage: action.systemImage)
                                .foregroundStyle(action.kind == .stop ? Color.qr.danger : .qr.ink)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.qr(.secondary, size: .large))
                        .disabled(busy || !action.enabled)
                        .accessibilityLabel(action.spokenTitle(topic: topic))
                        .accessibilityIdentifier("run.\(action.id)")
                    }
                }
            }
        }
    }
}

extension RunControls {
    private func title(_ action: RunAction) -> String {
        if case .reopen = action.kind, let reopenTotalMs { return RunHeaderText.reopenTitle(totalMs: reopenTotalMs) }
        return action.title
    }
}

/// The toolbar's "More" menu (`run.menu`): the layout's overflow, destructive last, then the
/// topic's own pages (`run.topic.<page>`, active-surfaces.md §2.2), so an open run never hides
/// them. Nothing when both are empty.
struct RunOverflowMenu: View {
    let actions: [RunAction]
    let topic: String
    let busy: Bool
    /// The topic whose pages the menu lists; none leaves them out.
    var pages: TopicLinkRef?
    let perform: (RunAction) -> Void

    var body: some View {
        if !actions.isEmpty || pages != nil {
            Menu {
                ForEach(actions) { action in
                    Button(role: action.role == .destructive ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(busy || !action.enabled)
                    .accessibilityLabel(action.spokenTitle(topic: topic))
                    .accessibilityIdentifier("run.\(action.id)")
                }
                if let pages {
                    Section(topic) {
                        TopicPageItems(ref: pages, prefix: "run.topic")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("run.menu")
        }
    }
}

extension RunAction {
    /// The primary's accessibility id: `run.start` idle, `run.addDetails` finishing, else
    /// `run.primary` (Next or Lap, whichever the rule picks).
    var primaryIdentifier: String {
        switch kind {
        case .start, .addDetails: "run.\(id)"
        default: "run.primary"
        }
    }
}
