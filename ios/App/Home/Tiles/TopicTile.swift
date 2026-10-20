import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// STUB until TILES lands (`ios/m2-tiles` owns this file; take theirs on merge). The agreed API:
/// the whole card for one topic, laid out by the home screen.
struct TopicTile: View {
    let topic: ViewTopic
    let now: Date
    let onOpen: () -> Void
    let onRecord: () -> Void

    init(topic: ViewTopic, now: Date, onOpen: @escaping () -> Void, onRecord: @escaping () -> Void) {
        self.topic = topic
        self.now = now
        self.onOpen = onOpen
        self.onRecord = onRecord
    }

    var body: some View {
        let due = DueView(due: TopicListing.due(of: topic.topic, at: now), now: now)
        let archived = topic.topic.status == .archived
        TileView(
            title: topic.topic.name, isDue: due.tone == .due || due.tone == .overdue, onOpen: onOpen,
            onLog: archived ? nil : onRecord
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if due.kind != .none {
                    QuickrBadge(due.label(), icon: due.tone == .later ? .clock : .bell, tone: due.tone.badgeTone)
                }
                if archived { QuickrBadge("Archived", tone: .warn) }
                Text(topic.topic.entryCount == 0 ? "No entries yet" : "\(topic.topic.entryCount) entries")
            }
        }
        .accessibilityIdentifier("tile.\(topic.topic.slug)")
    }
}

extension DueView.Tone {
    /// The pill colours (the PWA's `TONE_CLASS`).
    var badgeTone: QuickrTone {
        switch self {
        case .overdue: .danger
        case .due: .accent
        case .soon: .warn
        case .later, .none: .neutral
        }
    }
}
