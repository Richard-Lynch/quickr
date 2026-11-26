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

    /// A typed lap's neutral badge (content-display.md §3.2): its type's label in the run's
    /// version (`lapTypes`), or the key when the version isn't known; nil for a step or an untyped
    /// lap.
    public static func lapTypeBadge(_ segment: RunSegment, lapTypes: [TopicTimer.LapType]) -> String? {
        guard segment.kind == .lap, let key = segment.lapType else { return nil }
        return lapTypes.first { $0.key == key }?.label ?? key
    }

    // MARK: - Remove (content-display.md §3.2)

    /// A row's one-tap Remove: the event it targets (timers2.md §3.3, A7), whether it can be sent,
    /// the confirmation it asks first, and its accessibility identifier.
    public struct Remove: Sendable, Hashable {
        /// A lap's `event_id` (the event that opened it) or a pause's `id` (a gap pause carries
        /// the reopened stop's: removing it removes the gap).
        public let target: String
        /// False on a lap opened by anything but a `lap` (the lap after the last step is opened by
        /// a `next`, whose `remove` is `no_target`, timers2.md §3.4): shown, disabled.
        public let enabled: Bool
        public let title: String
        public let message: String
        /// `entry.timing.remove.<i>` on a segment row, `entry.timing.pause.remove.<j>` on a pause.
        public let identifier: String

        public init(target: String, enabled: Bool, title: String, message: String, identifier: String) {
            self.target = target
            self.enabled = enabled
            self.title = title
            self.message = message
            self.identifier = identifier
        }
    }

    /// Remove on `row` of `timing`, or nil: never on an edited timing (the server voids it,
    /// `run_edited`, timers2.md §3.6), a step, the first segment, or a row without an id (a
    /// pre-v2 stored timing, A12: Edit times still works there).
    public static func remove(_ row: Row, in timing: Timing) -> Remove? {
        guard !timing.edited else { return nil }
        switch row {
        case .segment(let index, let segment):
            guard index > 0, segment.kind == .lap, let target = segment.eventId else { return nil }
            return Remove(
                target: target, enabled: segment.openedBy == .lap, title: "Remove this lap?",
                message: "Its time joins the previous segment.", identifier: "entry.timing.remove.\(index)")
        case .pause(let index, let pause):
            guard let target = pause.id else { return nil }
            return Remove(
                target: target, enabled: true, title: "Remove this pause?", message: "Its time becomes active.",
                identifier: "entry.timing.pause.remove.\(index)")
        }
    }

    // MARK: - Resume run (content-display.md §3.2)

    /// Whether the detail offers "Resume run" (`entry.resume`): `resumableFromDetail` (unedited,
    /// within 7 days of the run's start, OQ-1), the entry not pending, and the topic without a
    /// locally open or finishing run (A15: the server would answer 409 `conflict`).
    public static func offersResume(_ entry: Entry, pending: Bool, topicHasLocalRun: Bool, now: Date) -> Bool {
        !pending && !topicHasLocalRun && RunPresentation.resumableFromDetail(entry, now: now)
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
