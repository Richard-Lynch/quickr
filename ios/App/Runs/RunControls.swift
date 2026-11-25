import QuickrCore
import QuickrUI
import SwiftUI

// The run screen's controls (active-surfaces.md §2.2, §2.3): one big primary, a row of
// secondaries, and the rest in the toolbar's overflow menu. Every control renders in exactly one
// of those places, decided by its role, never by what it does.

/// One run control, placed by `role`.
///
/// Phase-1 seam (I2-CONTROLS): `RunPanel.controls` builds these from today's taps. Phase 2 swaps
/// this for M1's `RunAction` (`RunPresentation.actions`), placed by M2-MODEL-ADOPT's
/// `RunControlsLayout`, with the titles and icons of active-surfaces.md §1.3.
struct RunControlItem: Identifiable {
    enum Role { case primary, secondary, destructive, overflow }

    /// The accessibility id: "run.primary", "run.stop", "run.skip", ….
    var id: String
    var title: String
    /// An SF Symbol.
    var icon: String
    /// What VoiceOver reads, when it isn't the title ("Stop Morning").
    var label: String?
    var role: Role
    var enabled = true
    /// Stop: danger text on the secondary capsule.
    var danger = false
    var perform: () -> Void

    /// The controls by place, each exactly once, in the given order: the first primary, the
    /// secondaries, then the menu (overflow, destructive last).
    struct Slots {
        var primary: RunControlItem?
        var secondaries: [RunControlItem]
        var menu: [RunControlItem]
    }

    static func slots(_ items: [RunControlItem]) -> Slots {
        let primary = items.first { $0.role == .primary }
        return Slots(
            primary: primary,
            secondaries: items.filter { $0.role == .secondary },
            menu: items.filter { $0.role == .overflow || ($0.role == .primary && $0.id != primary?.id) }
                + items.filter { $0.role == .destructive }
        )
    }
}

/// The primary (full width, ≥ 72 pt) and the secondaries (56 pt, equal widths; stacked at
/// accessibility text sizes). Disabled while `busy` (the tap cooldown), so the layout never
/// changes under the finger.
struct RunControls: View {
    let primary: RunControlItem?
    let secondaries: [RunControlItem]
    let busy: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var primaryIcon: CGFloat = 28

    /// The primary's size. Phase 2: M2-MODEL-ADOPT's `QuickrButtonSize.hero` (72 pt), and
    /// `primaryMinHeight` goes.
    static let primarySize: QuickrButtonSize = .large
    /// Holds the primary at 72 pt until `.hero` lands; it still grows with a two-line label.
    static let primaryMinHeight: CGFloat = 72

    init(_ slots: RunControlItem.Slots, busy: Bool) {
        primary = slots.primary
        secondaries = slots.secondaries
        self.busy = busy
    }

    var body: some View {
        VStack(spacing: 10) {
            if let primary {
                Button(action: primary.perform) {
                    Label {
                        Text(primary.title)
                    } icon: {
                        Image(systemName: primary.icon).font(.system(size: primaryIcon, weight: .semibold))
                    }
                    .font(.qr(.sansSemiBold, size: 22, relativeTo: .title2))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: Self.primaryMinHeight)
                }
                .buttonStyle(.qr(.primary, size: Self.primarySize))
                .disabled(busy || !primary.enabled)
                .accessibilityLabel(primary.label ?? primary.title)
                .accessibilityIdentifier(primary.id)
            }
            if !secondaries.isEmpty {
                let layout =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    ForEach(secondaries) { item in
                        Button(action: item.perform) {
                            Label(item.title, systemImage: item.icon)
                                .foregroundStyle(item.danger ? Color.qr.danger : .qr.ink)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.qr(.secondary, size: .large))
                        .disabled(busy || !item.enabled)
                        .accessibilityLabel(item.label ?? item.title)
                        .accessibilityIdentifier(item.id)
                    }
                }
            }
        }
    }
}

/// The toolbar's "More" menu (`run.menu`): the overflow controls, then the destructive ones.
/// Nothing when there are none.
struct RunOverflowMenu: View {
    let items: [RunControlItem]
    let busy: Bool

    var body: some View {
        if !items.isEmpty {
            Menu {
                ForEach(items) { item in
                    Button(role: item.role == .destructive ? .destructive : nil, action: item.perform) {
                        Label(item.title, systemImage: item.icon)
                    }
                    .disabled(busy || !item.enabled)
                    .accessibilityLabel(item.label ?? item.title)
                    .accessibilityIdentifier(item.id)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("run.menu")
        }
    }
}
