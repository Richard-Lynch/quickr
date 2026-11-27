#if os(iOS)
import QuickrCore
import SwiftUI

/// The idle tile's second line (content-display.md §5): the latest entry's summary line
/// (`EntrySummary`), or `fallback` when there is no entry or nothing to say. Widgets reuse it.
public struct TopicSummaryLine: View {
    let summary: String
    let fallback: Text
    let suffix: String?

    /// - Parameters:
    ///   - entry: the topic's latest entry; nil shows `fallback`.
    ///   - questions: the entry's version's questions (the labels).
    ///   - timer: the topic's current timer (lap-type labels); nil when untimed.
    ///   - fallback: the tile's own line, for example "4 entries · 4 days ago".
    ///   - suffix: after the summary as " · {suffix}", never truncated: the tile's "4 hours ago".
    public init(entry: Entry?, questions: [Question], timer: TopicTimer?, fallback: Text, suffix: String? = nil) {
        summary = EntrySummary.line(entry: entry, questions: questions, timer: timer)
        self.fallback = fallback
        self.suffix = suffix
    }

    public var body: some View {
        if summary.isEmpty {
            fallback
        } else {
            HStack(spacing: 0) {
                Text(summary)
                    .foregroundStyle(.qr.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let suffix {
                    Text(" · \(suffix)").lineLimit(1).fixedSize()
                }
            }
            .font(.qr(.footnote))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last entry: \(summary)\(suffix.map { ", \($0)" } ?? "")")
        }
    }
}
#endif
