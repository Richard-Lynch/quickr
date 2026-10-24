import Foundation

/// The Edit times form's model (timers.md §3.8, the PWA's `components/runs/timingEdit.ts`): a
/// stopped run's times as editable text, the edit a save sends, and the client-side checks that
/// mirror the server's (T2–T5, the run's steps, the 7-day limit, the `captured_at` bounds). The
/// server stays the final word: its 422 field paths (`timing.segments.1.ended_at`…) land on the
/// same fields as these checks (``TimingDraft/field(forServerPath:)``).
///
/// Times are edited as local wall time to the second (`2026-10-24 07:15:30`). Each field remembers
/// its original text and millisecond: while its text is unchanged it sends that exact millisecond,
/// so two boundaries within the same second never collapse; once edited, it sends the second it
/// shows.
public struct TimingDraft: Sendable, Hashable {
    public struct Segment: Sendable, Hashable, Identifiable {
        public let id: UUID
        public var kind: RunSegmentKind
        /// The step's key; nil for a lap.
        public var step: String?
        public var endedAt: String

        public init(id: UUID = UUID(), kind: RunSegmentKind, step: String?, endedAt: String) {
            self.id = id
            self.kind = kind
            self.step = step
            self.endedAt = endedAt
        }
    }

    public struct Pause: Sendable, Hashable, Identifiable {
        public let id: UUID
        public var start: String
        public var end: String

        public init(id: UUID = UUID(), start: String, end: String) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// The field an original belongs to.
    public enum Field: Sendable, Hashable {
        case startedAt
        case segmentEnd(UUID)
        case pauseStart(UUID)
        case pauseEnd(UUID)
    }

    /// A field's original value: the text it opened with and the exact instant behind it.
    public struct Original: Sendable, Hashable {
        public var text: String
        public var ms: Int
    }

    public var startedAt: String
    public var segments: [Segment]
    /// Skipped step keys (any order; a save sends them in step order).
    public var skipped: [String]
    public var pauses: [Pause]
    /// A field whose text still equals its original's sends the original's millisecond.
    public var originals: [Field: Original]
    public let clock: TimingEditClock

    /// The draft a stopped run's timing opens as (`draftFromTiming`).
    public init(timing: Timing, clock: TimingEditClock = .current) {
        self.clock = clock
        var originals: [Field: Original] = [:]
        func field(_ id: Field, _ ms: Int) -> String {
            let text = clock.text(ms)
            originals[id] = Original(text: text, ms: ms)
            return text
        }
        startedAt = field(.startedAt, timing.startedAt)
        segments = timing.segments.map { s in
            let id = UUID()
            return Segment(id: id, kind: s.kind, step: s.step, endedAt: field(.segmentEnd(id), s.endedAt))
        }
        pauses = timing.pauses.map { p in
            let id = UUID()
            return Pause(id: id, start: field(.pauseStart(id), p.start), end: field(.pauseEnd(id), p.end))
        }
        skipped = timing.skipped
        self.originals = originals
    }

    /// The instant a field's text means: its original millisecond while unchanged, else the
    /// local time it shows.
    func instant(_ field: Field, _ text: String) -> Int? {
        if let original = originals[field], original.text == text { return original.ms }
        return clock.milliseconds(text)
    }

    /// The run's last end, as text and its original (so a copy of it keeps the exact ms).
    private var lastEnd: (text: String, original: Original?) {
        guard let last = segments.last else { return (startedAt, originals[.startedAt]) }
        return (last.endedAt, originals[.segmentEnd(last.id)])
    }

    // MARK: Edits

    /// "Add segment": a zero-length segment at the end, timing the first step not used yet,
    /// else a lap (`withNewSegment`).
    public mutating func addSegment(steps: [TopicTimer.Step]) {
        let used = Set(segments.compactMap(\.step))
        let free = steps.first { !used.contains($0.key) }
        let (text, original) = lastEnd
        let segment = Segment(kind: free == nil ? .lap : .step, step: free?.key, endedAt: text)
        segments.append(segment)
        if let free { skipped.removeAll { $0 == free.key } }
        if let original { originals[.segmentEnd(segment.id)] = original }
    }

    /// "Add pause": a zero-length pause at the run's end, to be moved (`withNewPause`).
    public mutating func addPause() {
        let (text, original) = lastEnd
        let pause = Pause(start: text, end: text)
        pauses.append(pause)
        if let original {
            originals[.pauseStart(pause.id)] = original
            originals[.pauseEnd(pause.id)] = original
        }
    }

    /// Picks what a segment times: a step's key, or nil for a lap. Drops it from `skipped`
    /// (`withSegmentStep`).
    public mutating func setSegmentStep(_ index: Int, _ step: String?) {
        guard segments.indices.contains(index) else { return }
        segments[index].kind = step == nil ? .lap : .step
        segments[index].step = step
        if let step { skipped.removeAll { $0 == step } }
    }

    /// Ticks or clears "Skipped" for a step without a segment.
    public mutating func setSkipped(_ key: String, _ isSkipped: Bool) {
        skipped.removeAll { $0 == key }
        if isSkipped { skipped.append(key) }
    }

    // MARK: Checks

    /// One segment as the form shows it while editing.
    public struct ShownSegment: Sendable, Hashable {
        /// The step's label, or "Lap n" numbered in this order.
        public var label: String
        /// Nil while its times don't make a segment.
        public var activeMs: Int?
        public var pausedMs: Int?
    }

    /// What a save sends (`TimingEdit`), every instant in epoch milliseconds.
    public struct Edit: Sendable, Hashable {
        public struct Segment: Sendable, Hashable {
            public var kind: RunSegmentKind
            public var step: String?
            public var endedAt: Int

            public init(kind: RunSegmentKind, step: String?, endedAt: Int) {
                self.kind = kind
                self.step = step
                self.endedAt = endedAt
            }
        }

        public var startedAt: Int
        public var segments: [Segment]
        /// In step order.
        public var skipped: [String]
        public var pauses: [RunPause]

        public init(startedAt: Int, segments: [Segment], skipped: [String], pauses: [RunPause]) {
            self.startedAt = startedAt
            self.segments = segments
            self.skipped = skipped
            self.pauses = pauses
        }

        /// The `Timing` the server rebuilds from it (`edited_timing`): labels from `steps`, laps
        /// numbered in order, each segment's paused time its overlap with the pauses.
        public func timing(steps: [TopicTimer.Step]) -> Timing {
            let labels = Dictionary(steps.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
            var laps = 0
            var from = startedAt
            var out: [RunSegment] = []
            for segment in segments {
                let label: String
                if let step = segment.step {
                    label = labels[step] ?? step
                } else {
                    laps += 1
                    label = RunFold.lapLabel(laps)
                }
                let paused = TimingDraft.overlap(from, segment.endedAt, pauses)
                out.append(
                    RunSegment(
                        kind: segment.kind, step: segment.step, label: label, startedAt: from,
                        endedAt: segment.endedAt, activeMs: segment.endedAt - from - paused, pausedMs: paused))
                from = segment.endedAt
            }
            let paused = pauses.reduce(0) { $0 + $1.end - $1.start }
            return Timing(
                startedAt: startedAt, endedAt: from, activeMs: from - startedAt - paused, pausedMs: paused,
                complete: RunFold.isComplete(steps: steps, segments: out, skipped: skipped), edited: true,
                segments: out, skipped: skipped, pauses: pauses)
        }
    }

    public struct Checked: Sendable, Hashable {
        /// By field path relative to `timing` (`segments.0.ended_at`, `pauses.1.start`,
        /// `skipped.0`, `segments` and "" for the form); the first problem in each field.
        public var errors: [String: String]
        /// The request's `timing`, when there are no errors.
        public var edit: Edit?
        public var segments: [ShownSegment]
        public var activeMs: Int?
        public var pausedMs: Int?
    }

    /// The earliest instant the server takes (`captured_at` bounds, sync-protocol.md §10).
    public static let minInstant = 946_684_800_000  // 2000-01-01T00:00:00Z
    public static let maxAheadMs = 24 * 60 * 60 * 1000

    /// Each pause's overlap with `[a, b]`.
    static func overlap(_ a: Int, _ b: Int, _ pauses: [RunPause]) -> Int {
        pauses.reduce(0) { $0 + Swift.max(0, Swift.min(b, $1.end) - Swift.max(a, $1.start)) }
    }

    /// Checks the draft against the run's `steps` (its version's) and builds the edit
    /// (`checkTimingDraft`). The rules are the server's (`edited_timing`, and the `captured_at`
    /// bounds at `now`, epoch ms), in the client's own words.
    public func check(steps: [TopicTimer.Step], now: Int) -> Checked {
        var errors: [String: String] = [:]
        func fail(_ path: String, _ message: String) {
            if errors[path] == nil { errors[path] = message }
        }
        let labels = Dictionary(steps.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        var claimed: Set<String> = []
        func claim(_ key: String, _ path: String) {
            if labels[key] == nil {
                fail(path, "'\(key)' is not a step of the run's version")
            } else if claimed.contains(key) {
                fail(path, "Step '\(labels[key] ?? key)' appears more than once")
            }
            claimed.insert(key)
        }
        func read(_ field: Field, _ text: String, _ path: String) -> Int? {
            let ms = instant(field, text)
            if let ms {
                if ms < Self.minInstant {
                    fail(path, "Must not be before 2000-01-01")
                } else if ms > now + Self.maxAheadMs {
                    fail(path, "Must not be more than 24 hours in the future")
                }
            } else {
                fail(path, "Enter a date and time")
            }
            return ms
        }

        let start = read(.startedAt, startedAt, "started_at")
        if segments.isEmpty { fail("segments", "Keep at least one segment") }

        var ends: [Int?] = []
        var previous = start
        for (i, segment) in segments.enumerated() {
            if segment.kind == .step {
                if let step = segment.step {
                    claim(step, "segments.\(i).step")
                } else {
                    fail("segments.\(i).step", "Pick a step")
                }
            }
            let end = read(.segmentEnd(segment.id), segment.endedAt, "segments.\(i).ended_at")
            if let end, let previous, end < previous { fail("segments.\(i).ended_at", "Before the segment’s start") }
            ends.append(end)
            previous = end ?? previous
        }
        for (i, key) in skipped.enumerated() { claim(key, "skipped.\(i)") }

        let runEnd: Int? = ends.isEmpty || ends.contains(where: { $0 == nil }) ? nil : ends.last ?? nil
        if let start, let runEnd, runEnd - start > RunFold.maxRunMs {
            fail("segments.\(segments.count - 1).ended_at", "More than 7 days after the start")
        }

        var pauseTimes: [RunPause] = []
        var floor = start
        for (i, pause) in pauses.enumerated() {
            let ps = read(.pauseStart(pause.id), pause.start, "pauses.\(i).start")
            let pe = read(.pauseEnd(pause.id), pause.end, "pauses.\(i).end")
            if let ps, let floor, ps < floor {
                fail("pauses.\(i).start", "Before the run’s start or the previous pause’s end")
            }
            if let pe, let ps, pe < ps {
                fail("pauses.\(i).end", "Before the pause’s start")
            } else if let pe, let runEnd, pe > runEnd {
                fail("pauses.\(i).end", "After the run’s end")
            }
            if let ps, let pe { pauseTimes.append(RunPause(start: ps, end: pe)) }
            floor = pe ?? floor
        }

        // The live durations (shown while editing, valid or not).
        var laps = 0
        var from = start
        var shown: [ShownSegment] = []
        for (i, segment) in segments.enumerated() {
            let label: String
            if segment.kind == .lap {
                laps += 1
                label = RunFold.lapLabel(laps)
            } else {
                label = segment.step.flatMap { labels[$0] ?? $0 } ?? "Step"
            }
            var row = ShownSegment(label: label, activeMs: nil, pausedMs: nil)
            if let a = from, let b = ends[i], b >= a {
                let paused = Self.overlap(a, b, pauseTimes)
                row.activeMs = b - a - paused
                row.pausedMs = paused
            }
            shown.append(row)
            from = ends[i] ?? from
        }
        let active: Int? =
            shown.contains(where: { $0.activeMs == nil }) ? nil : shown.reduce(0) { $0 + ($1.activeMs ?? 0) }
        let paused: Int? =
            shown.contains(where: { $0.pausedMs == nil }) ? nil : shown.reduce(0) { $0 + ($1.pausedMs ?? 0) }

        var edit: Edit?
        if errors.isEmpty, let start {
            let order = steps.map(\.key)
            edit = Edit(
                startedAt: start,
                segments: segments.enumerated().map { i, segment in
                    Edit.Segment(
                        kind: segment.kind, step: segment.kind == .step ? segment.step : nil, endedAt: ends[i] ?? 0)
                },
                skipped: skipped.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) },
                pauses: pauseTimes)
        }
        return Checked(errors: errors, edit: edit, segments: shown, activeMs: active, pausedMs: paused)
    }

    /// A server field path (`timing.segments.0.ended_at`) as the form's, or nil when it isn't one
    /// (`timingFieldOf`); `timing` itself is the form's ("").
    public static func field(forServerPath path: String) -> String? {
        if path == "timing" { return "" }
        return path.hasPrefix("timing.") ? String(path.dropFirst("timing.".count)) : nil
    }

    /// A note for a local time a clock change makes ambiguous (it happens twice: the earlier is
    /// used) or skips (it doesn't exist: it reads as the time after the gap); nil otherwise
    /// (`localTimeNote`).
    public func localTimeNote(_ text: String) -> String? {
        guard let ms = clock.milliseconds(text), let wanted = clock.normalized(text) else { return nil }
        let shown = clock.text(ms)
        let time = { (s: String) in String(s.suffix(8)) }
        if shown != wanted {
            return "There is no \(time(wanted)) that day (the clocks went forward): it reads as \(time(shown))."
        }
        if clock.text(ms + 3_600_000) == wanted || clock.text(ms - 3_600_000) == wanted {
            return "\(time(wanted)) happens twice that day (the clocks went back): the earlier one is used."
        }
        return nil
    }
}

/// Local wall time to the second, as the Edit times fields show it: `yyyy-MM-dd HH:mm:ss` in
/// `timeZone` (a `T` between date and time, and leaving out the seconds, are accepted too).
public struct TimingEditClock: Sendable, Hashable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone) { self.timeZone = timeZone }

    public static var current: TimingEditClock { TimingEditClock(timeZone: .current) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Epoch ms as the field's text (truncated to the second).
    public func text(_ ms: Int) -> String {
        let seconds = RunInstant.floorDiv(ms, 1000)
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        func pad(_ n: Int?, _ width: Int = 2) -> String {
            let s = String(n ?? 0)
            return String(repeating: "0", count: Swift.max(0, width - s.count)) + s
        }
        return "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day)) \(pad(c.hour)):\(pad(c.minute)):\(pad(c.second))"
    }

    private func parts(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(whereSeparator: { $0 == " " || $0 == "T" })
        guard pieces.count == 2 else { return nil }
        let date = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        let time = pieces[1].split(separator: ":", omittingEmptySubsequences: false)
        guard date.count == 3, time.count == 2 || time.count == 3, date[0].count == 4,
            date.dropFirst().allSatisfy({ $0.count == 2 }), time.allSatisfy({ $0.count == 2 })
        else { return nil }
        let numbers = (date + time).map { piece in piece.allSatisfy(\.isASCII) ? Int(piece) : nil }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        var out = numbers.compactMap { $0 }
        if out.count == 5 { out.append(0) }
        let (month, day, hour, minute, second) = (out[1], out[2], out[3], out[4], out[5])
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute),
            (0...59).contains(second)
        else { return nil }
        return out
    }

    /// The text with seconds, as `text(_:)` would write it; nil when it isn't a local time.
    func normalized(_ text: String) -> String? {
        guard let p = parts(text) else { return nil }
        func pad(_ n: Int, _ width: Int = 2) -> String {
            let s = String(n)
            return String(repeating: "0", count: Swift.max(0, width - s.count)) + s
        }
        return "\(pad(p[0], 4))-\(pad(p[1]))-\(pad(p[2])) \(pad(p[3])):\(pad(p[4])):\(pad(p[5]))"
    }

    /// A field's text as epoch ms (a whole second), or nil when it isn't a local date and time.
    /// A time a clock change skips reads as the time after the gap; one it repeats, as the earlier.
    public func milliseconds(_ text: String) -> Int? {
        guard let p = parts(text) else { return nil }
        // A day the month doesn't have (31 April) is refused, as an input would.
        guard let first = calendar.date(from: DateComponents(year: p[0], month: p[1], day: 1, hour: 12)),
            let days = calendar.range(of: .day, in: .month, for: first), days.contains(p[2]),
            let date = calendar.date(
                from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4], second: p[5]))
        else { return nil }
        return Int(date.timeIntervalSince1970.rounded(.down)) * 1000
    }
}
