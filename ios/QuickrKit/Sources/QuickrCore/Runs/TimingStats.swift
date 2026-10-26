import Foundation

/// Timing stats: best, median and mean run times, per step, laps and pauses (timers.md §9.1).
///
/// A port of backend/app/services/timing_stats.py, the model behind the timing charts;
/// `shared/fixtures/timing-stats-vectors.json` is the contract. Every duration is active time in
/// integer milliseconds. Best, median and mean of run totals count complete runs only; per-step
/// stats, laps, pauses and the series count every timed run. Untimed entries (`timing` nil) count
/// toward nothing here.
public enum TimingStats {
    public struct TimedEntry: Sendable, Hashable {
        public var entryId: String
        /// Epoch milliseconds.
        public var capturedAt: Int
        public var timing: Timing?

        public init(entryId: String, capturedAt: Int, timing: Timing?) {
            self.entryId = entryId
            self.capturedAt = capturedAt
            self.timing = timing
        }
    }

    public struct Summary: Sendable, Hashable {
        public var bestMs: Int?
        public var medianMs: Int?
        public var meanMs: Int?
    }

    public struct StepStats: Sendable, Hashable {
        public var key: String
        public var label: String
        /// The key is in the current version.
        public var current: Bool
        public var done: Int
        public var skipped: Int
        public var bestMs: Int?
        public var medianMs: Int?
        public var meanMs: Int?
    }

    public struct LapStats: Sendable, Hashable {
        public var runsWithLaps: Int
        public var medianMs: Int?
        public var meanMs: Int?
    }

    public struct PausedStats: Sendable, Hashable {
        public var runsWithPauses: Int
        public var medianMs: Int?
    }

    public struct SeriesPoint: Sendable, Hashable {
        public var entryId: String
        public var capturedAt: Int
        public var startedAt: Int
        public var activeMs: Int
        public var pausedMs: Int
        public var complete: Bool
        /// Each step segment's key and its `activeMs`.
        public var steps: [String: Int]
    }

    /// `TopicTiming` (§9.2).
    public struct TopicTiming: Sendable, Hashable {
        public var runs: Int
        public var completeRuns: Int
        public var total: Summary
        /// The current version's keys first, in step order, then the rest by key.
        public var steps: [StepStats]
        public var laps: LapStats
        public var paused: PausedStats
        /// By `(capturedAt, entryId)`.
        public var series: [SeriesPoint]
    }

    /// The middle value; `floor((a + b) / 2)` of the two middle ones for an even count.
    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let mid = ordered.count / 2
        return ordered.count % 2 == 1 ? ordered[mid] : RunInstant.floorDiv(ordered[mid - 1] + ordered[mid], 2)
    }

    /// `floor(sum / n)`.
    public static func mean(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : RunInstant.floorDiv(values.reduce(0, +), values.count)
    }

    public static func summary(_ values: [Int]) -> Summary {
        Summary(bestMs: values.min(), medianMs: median(values), meanMs: mean(values))
    }

    /// Each step key's label in the latest version that has it.
    public static func stepLabels(_ versions: [Int: [TopicTimer.Step]?]) -> [String: String] {
        var labels: [String: String] = [:]
        for number in versions.keys.sorted() {
            for step in versions[number].flatMap({ $0 }) ?? [] { labels[step.key] = step.label }
        }
        return labels
    }

    /// Timing stats over `entries` (already filtered to the range).
    ///
    /// `versions` maps each version number of the topic to its steps (nil when that version isn't
    /// timed). `steps` lists only keys seen in range (done or skipped). A key keeps the label of the
    /// latest version that has it, else its latest segment's.
    public static func compute(
        _ entries: [TimedEntry], versions: [Int: [TopicTimer.Step]?], currentVersion: Int
    ) -> TopicTiming {
        let timed = entries.compactMap { e in e.timing.map { (entry: e, timing: $0) } }
            .sorted { a, b in
                a.entry.capturedAt != b.entry.capturedAt
                    ? a.entry.capturedAt < b.entry.capturedAt : codePointLess(a.entry.entryId, b.entry.entryId)
            }
        let current = (versions[currentVersion].flatMap { $0 } ?? []).map(\.key)
        let labels = stepLabels(versions)
        var latestLabels: [String: String] = [:]  // a key in no version: its latest segment's label

        var done: [String: [Int]] = [:]
        var skipped: [String: Int] = [:]
        var lapTotals: [Int] = []
        var paused: [Int] = []
        var series: [SeriesPoint] = []
        for (entry, t) in timed {
            var steps: [String: Int] = [:]
            for s in t.segments {
                guard let key = s.step else { continue }
                steps[key] = s.activeMs
                done[key, default: []].append(s.activeMs)
                latestLabels[key] = s.label
            }
            for key in t.skipped { skipped[key, default: 0] += 1 }
            let laps = t.segments.filter { $0.kind == .lap }.map(\.activeMs)
            if !laps.isEmpty { lapTotals.append(laps.reduce(0, +)) }
            if t.pausedMs > 0 { paused.append(t.pausedMs) }  // a zero-length pause doesn't count
            series.append(
                SeriesPoint(
                    entryId: entry.entryId, capturedAt: entry.capturedAt, startedAt: t.startedAt,
                    activeMs: t.activeMs, pausedMs: t.pausedMs, complete: t.complete, steps: steps))
        }

        let seen = Set(done.keys).union(skipped.keys)
        let order = current.filter(seen.contains) + seen.subtracting(current).sorted(by: codePointLess)
        let complete = timed.filter(\.timing.complete).map(\.timing.activeMs)
        return TopicTiming(
            runs: timed.count, completeRuns: complete.count, total: summary(complete),
            steps: order.map { key in
                let durations = done[key] ?? []
                let label = labels[key].flatMap { $0.isEmpty ? nil : $0 } ?? latestLabels[key] ?? key
                return StepStats(
                    key: key, label: label, current: current.contains(key), done: durations.count,
                    skipped: skipped[key] ?? 0, bestMs: durations.min(), medianMs: median(durations),
                    meanMs: mean(durations))
            },
            laps: LapStats(runsWithLaps: lapTotals.count, medianMs: median(lapTotals), meanMs: mean(lapTotals)),
            paused: PausedStats(runsWithPauses: paused.count, medianMs: median(paused)),
            series: series)
    }
}
