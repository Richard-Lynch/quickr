import Foundation

/// What an entry's timing shows (content-display.md §3.1, §3.2): the list row's timing chip and
/// the detail's rows, segments and pauses in one list in time order.
public enum EntryTimingModel {
    /// One row of the detail's timing list. `index` is the item's 0-based position in
    /// `timing.segments` or `timing.pauses`, so the ids `entry.timing.segment.<i>` and
    /// `entry.timing.pause.<i>` stay what they were before pauses joined the list.
    public enum Row: Sendable, Hashable, Identifiable {
        case segment(index: Int, RunSegment)
        case pause(index: Int, RunPause)

        public var id: String {
            switch self {
            case .segment(let index, _): "segment.\(index)"
            case .pause(let index, _): "pause.\(index)"
            }
        }
    }

    /// The timing chip on a list row: `text` is the summary line's timing part ("12:40 · 3 laps"),
    /// `accessibilityLabel` speaks the duration and the segment count ("12 minutes 40 seconds,
    /// 3 laps").
    public struct Chip: Sendable, Hashable {
        public let text: String
        public let accessibilityLabel: String

        public init(text: String, accessibilityLabel: String) {
            self.text = text
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// The segments and pauses in time order: a pause sits after the segment it starts in, so it
    /// reads "between the segments it falls in" (a pause stays whole, so it can run past that
    /// segment's end). A pause starting exactly when a segment starts falls in that segment and
    /// comes after it; one starting before the first segment comes first.
    public static func rows(_ timing: Timing) -> [Row] {
        var rows: [Row] = []
        var pauses = timing.pauses.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .makeIterator()
        var pending = pauses.next()
        for (index, segment) in timing.segments.enumerated() {
            while let (j, pause) = pending, pause.start < segment.startedAt {
                rows.append(.pause(index: j, pause))
                pending = pauses.next()
            }
            rows.append(.segment(index: index, segment))
        }
        while let (j, pause) = pending {
            rows.append(.pause(index: j, pause))
            pending = pauses.next()
        }
        return rows
    }

    /// The list row's chip for a timed entry; nil for an untimed one (timers.md §11.1).
    public static func chip(_ timing: Timing?, timer: TopicTimer?) -> Chip? {
        guard let timing else { return nil }
        return Chip(
            text: EntrySummary.timingLine(timing, timer: timer),
            accessibilityLabel: spokenChip(timing))
    }

    /// The duration spoken, then the segments counted: "12 minutes 40 seconds, 3 laps", or with
    /// steps "4 minutes, 2 steps, 1 lap". No segments: the duration alone.
    static func spokenChip(_ timing: Timing) -> String {
        func count(_ n: Int, _ one: String) -> String? { n == 0 ? nil : "\(n) \(one)\(n == 1 ? "" : "s")" }
        let steps = timing.segments.count { $0.kind == .step }
        let laps = timing.segments.count { $0.kind == .lap }
        let parts = [RunPresentation.spoken(timing.activeMs), count(steps, "step"), count(laps, "lap")]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}
