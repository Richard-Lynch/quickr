#if os(iOS)
import QuickrCore
import SwiftUI

/// A topic's due status as a pill (the PWA's `DueBadge`): a bell while due, a clock before.
/// Nothing when there is no pill (`DueView.Kind.none`).
public struct DueBadge: View {
    let view: DueView

    public init(_ view: DueView) {
        self.view = view
    }

    public var body: some View {
        if view.kind != .none {
            QuickrBadge(view.label(), icon: isDue ? .bell : .clock, tone: tone)
        }
    }

    private var isDue: Bool { view.tone == .due || view.tone == .overdue }

    /// The pill colours (the PWA's `TONE_CLASS`).
    private var tone: QuickrTone {
        switch view.tone {
        case .overdue: .danger
        case .due: .accent
        case .soon: .warn
        case .later, .none: .neutral
        }
    }
}
#endif
