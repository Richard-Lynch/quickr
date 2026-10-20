#if os(iOS)
import SwiftUI

/// A topic's due status as a badge (the PWA's `DueBadge`): a bell while due, a clock before.
/// Nothing for an unscheduled topic.
public struct DueBadge: View {
    let view: DueView

    public init(_ view: DueView) {
        self.view = view
    }

    public var body: some View {
        if view.tone != .none {
            QuickrBadge(view.label, icon: view.isDue ? .bell : .clock, tone: tone)
        }
    }

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
