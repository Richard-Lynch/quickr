#if os(iOS)
import QuickrCore
import SwiftUI

/// The idle tile's second line (content-display.md §5): the latest entry's summary line
/// (`EntrySummary`), or `fallback` when there is no entry or nothing to say. Widgets reuse it.
public struct TopicSummaryLine: View {
    let summary: String
    let fallback: Text

    /// - Parameters:
    ///   - entry: the topic's latest entry; nil shows `fallback`.
    ///   - questions: the entry's version's questions (the labels).
    ///   - timer: the topic's current timer (lap-type labels); nil when untimed.
    ///   - fallback: the tile's own line, for example "4 entries · 4 days ago".
    public init(entry: Entry?, questions: [Question], timer: TopicTimer?, fallback: Text) {
        summary = EntrySummary.line(entry: entry, questions: questions, timer: timer)
        self.fallback = fallback
    }

    public var body: some View {
        if summary.isEmpty {
            fallback
        } else {
            Text(summary)
                .font(.qr(.footnote))
                .foregroundStyle(.qr.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel("Last entry: \(summary)")
        }
    }
}
#endif
