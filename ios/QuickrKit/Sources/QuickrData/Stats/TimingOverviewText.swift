import Foundation
import QuickrCore

/// What the Overview's Timing section shows (timers.md §9, §11.2; the PWA's `TimingOverview`),
/// from `getTopicTiming`: best, median and mean run time over **complete** runs only (OPEN 2),
/// with how many runs that is; the run time of every run over time; each step's median with its
/// best marked, retired steps flagged; skipped counts; laps and paused time. A topic with lap types
/// (content-display.md §4.1) gets one card per type and a stacked time per type in place of the
/// v1 lap tiles. Durations are `m:ss` / `h:mm:ss` (`fmtDuration`).
public struct TimingOverviewText: Sendable, Hashable {
    public struct Step: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public var key: String
        public var label: String
        /// No longer a step of the current version.
        public var retired: Bool
        public var median: String
        public var best: String
        /// The median's share of the longest median (the bar's length), 0…1.
        public var share: Double
        /// The best's share of the longest median, 0…1 (the mark on the bar).
        public var bestShare: Double
        /// "3 runs · skipped 1×".
        public var counts: String
    }

    /// One run in the line: its end and its active time.
    public struct Point: Sendable, Hashable {
        public var endedAt: Date
        public var activeMs: Int
        /// Each step segment's key and its active time.
        public var steps: [String: Int]
        /// Each lap type's key and the run's summed active time in it (untyped laps aren't in it).
        public var lapTypes: [String: Int]
    }

    /// A lap type's card (the PWA's `lapTypeCards`): label, lap count, median (the big figure),
    /// best and mean.
    public struct LapType: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public var key: String
        public var label: String
        /// "4 laps".
        public var laps: String
        public var median: String
        public var best: String
        public var mean: String
    }

    /// Each step's mean time per run in one bucket (the PWA's `stepsByBucket`): a run that didn't
    /// time the step counts as 0, so the stack's height is the mean time per run spent in steps.
    public struct StepBucket: Sendable, Hashable {
        public var start: Date
        public var count: Int
        /// By step key, in the steps' order; keys no run in the bucket timed are left out.
        public var meanMs: [StepMean]
    }

    public struct StepMean: Sendable, Hashable {
        public var key: String
        public var ms: Int
    }

    /// Each lap type's mean time per run in one bucket (the PWA's `lapTypesByBucket`), as
    /// ``StepBucket`` is for steps: a run without the type counts as 0. Lap-type and step keys are
    /// separate, and untyped laps are in neither.
    public struct LapTypeBucket: Sendable, Hashable {
        public var start: Date
        public var count: Int
        /// By lap-type key, in the cards' order; keys no run in the bucket has are left out.
        public var meanMs: [LapTypeMean]

        /// The bucket as the stacked bars draw it (`option_counts` keyed by lap type, in ms).
        public var point: QuestionSeries.Point {
            QuestionSeries.Point(
                start: start, count: count, mean: nil, min: nil, max: nil,
                optionCounts: Dictionary(uniqueKeysWithValues: meanMs.map { ($0.key, $0.ms) }))
        }
    }

    public struct LapTypeMean: Sendable, Hashable {
        public var key: String
        public var ms: Int
    }

    /// Every run in one chart bucket (the PWA's `totalsByBucket`): the floored mean, min and max
    /// of their active time.
    public struct BucketPoint: Sendable, Hashable {
        public var start: Date
        public var count: Int
        public var meanMs: Int
        public var minMs: Int
        public var maxMs: Int
    }

    public var runs: Int
    public var median: String
    public var best: String
    public var mean: String
    /// "Best, median and mean over complete runs: 2 of 3 runs".
    public var completeNote: String
    /// Every run (complete or not), by end; the line averages them per bucket (``totals(by:calendar:)``).
    public var points: [Point]
    /// The line's title: every run counts, complete or not.
    public static func lineTitle(_ bucket: QuestionSeries.Bucket) -> String {
        "Average run per \(bucket.rawValue) (all runs)"
    }

    /// The runs by the bucket they ended in (`calendar`'s zone): local midnight, the Monday, or
    /// the 1st, oldest first.
    public func totals(by bucket: QuestionSeries.Bucket, calendar: Calendar) -> [BucketPoint] {
        let groups = grouped(by: bucket, calendar: calendar)
        return groups.keys.sorted().map { start in
            let ms = (groups[start] ?? []).map(\.activeMs)
            // Durations are non-negative, so integer division is the floor.
            return BucketPoint(
                start: start, count: ms.count, meanMs: ms.reduce(0, +) / Swift.max(1, ms.count),
                minMs: ms.min() ?? 0, maxMs: ms.max() ?? 0)
        }
    }
    public var steps: [Step]
    /// One card per lap type, in the server's order (the current version's first). When there are
    /// any, they replace the "Runs with laps" and "Lap time (median)" tiles; the pause tiles stay.
    public var lapTypes: [LapType]
    /// The lap types as the stacked chart's options and colour order (key, label; card order).
    public var lapTypeOptions: [EnumOption] { lapTypes.map { EnumOption(value: $0.key, label: $0.label) } }
    public var runsWithLaps: String
    public var lapMedian: String
    public var runsWithPauses: String
    public var pausedMedian: String

    /// "—" when there is none.
    public static func duration(_ ms: Int?) -> String { ms.map(DurationFormat.format) ?? "—" }

    static func plural(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }

    public init(_ timing: TopicTimingDTO) {
        runs = timing.runs
        median = Self.duration(timing.total.medianMs)
        best = Self.duration(timing.total.bestMs)
        mean = Self.duration(timing.total.meanMs)
        completeNote =
            "Best, median and mean over complete runs: \(timing.completeRuns.formatted()) of \(Self.plural(timing.runs, "run"))"
        points = timing.series.compactMap { point in
            RunInstant.parse(point.capturedAt).map {
                Point(
                    endedAt: RunInstant.date($0), activeMs: point.activeMs, steps: point.steps,
                    lapTypes: point.lapTypes)
            }
        }
        let longest = timing.steps.compactMap(\.medianMs).max() ?? 0
        func share(_ ms: Int?) -> Double {
            guard let ms, longest > 0 else { return 0 }
            return Swift.min(1, Double(ms) / Double(longest))
        }
        steps = timing.steps.map { s in
            Step(
                key: s.key, label: s.label, retired: !s.current, median: Self.duration(s.medianMs),
                best: Self.duration(s.bestMs), share: share(s.medianMs), bestShare: share(s.bestMs),
                counts: Self.plural(s.done, "run") + (s.skipped > 0 ? " · skipped \(s.skipped.formatted())×" : ""))
        }
        lapTypes = timing.lapTypes.map { t in
            LapType(
                key: t.key, label: t.label, laps: Self.plural(t.laps, "lap"), median: Self.duration(t.medianMs),
                best: Self.duration(t.bestMs), mean: Self.duration(t.meanMs))
        }
        runsWithLaps = timing.laps.runsWithLaps.formatted()
        lapMedian = Self.duration(timing.laps.medianMs)
        runsWithPauses = timing.paused.runsWithPauses.formatted()
        pausedMedian = Self.duration(timing.paused.medianMs)
    }

    /// The time per step per bucket, stacked (`stepsByBucket`), in the steps' order.
    public func stepTotals(by bucket: QuestionSeries.Bucket, calendar: Calendar) -> [StepBucket] {
        meanPerRun(by: bucket, calendar: calendar, order: steps.map(\.key), times: \.steps).map {
            StepBucket(start: $0.start, count: $0.count, meanMs: $0.means.map { StepMean(key: $0.key, ms: $0.ms) })
        }
    }

    /// The time per lap type per bucket, stacked (`lapTypesByBucket`), in the cards' order. A
    /// bucket whose runs have no typed laps is still listed, with no means (an empty bar).
    public func lapTypeTotals(by bucket: QuestionSeries.Bucket, calendar: Calendar) -> [LapTypeBucket] {
        meanPerRun(by: bucket, calendar: calendar, order: lapTypes.map(\.key), times: \.lapTypes).map {
            LapTypeBucket(
                start: $0.start, count: $0.count, meanMs: $0.means.map { LapTypeMean(key: $0.key, ms: $0.ms) })
        }
    }

    /// Each key's floored mean per run in each bucket, oldest first: `order`'s keys first, then
    /// any other key a run has, sorted. A run without a key counts as 0.
    private func meanPerRun(
        by bucket: QuestionSeries.Bucket, calendar: Calendar, order: [String], times: KeyPath<Point, [String: Int]>
    ) -> [(start: Date, count: Int, means: [(key: String, ms: Int)])] {
        let groups = grouped(by: bucket, calendar: calendar)
        return groups.keys.sorted().map { start in
            let runs = groups[start] ?? []
            let seen = Set(runs.flatMap { $0[keyPath: times].keys })
            let keys = order.filter(seen.contains) + seen.subtracting(order).sorted()
            // Durations are non-negative, so integer division is the floor.
            let means = keys.map { key in
                (key: key, ms: runs.reduce(0) { $0 + ($1[keyPath: times][key] ?? 0) } / Swift.max(1, runs.count))
            }
            return (start: start, count: runs.count, means: means)
        }
    }

    /// The runs by the bucket they ended in, in `calendar`'s zone: local midnight, the Monday, or
    /// the 1st (the PWA's `bucketStart`).
    private func grouped(by bucket: QuestionSeries.Bucket, calendar: Calendar) -> [Date: [Point]] {
        var calendar = calendar
        calendar.firstWeekday = 2
        var groups: [Date: [Point]] = [:]
        for point in points {
            let day = calendar.startOfDay(for: point.endedAt)
            let start: Date
            switch bucket {
            case .day: start = day
            case .week: start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            case .month: start = calendar.dateInterval(of: .month, for: day)?.start ?? day
            }
            groups[start, default: []].append(point)
        }
        return groups
    }

    /// The section's state: hidden for an untimed topic without runs; "No runs in this range"
    /// for a timed one; else the stats.
    public enum Shown: Sendable, Hashable {
        case hidden
        case empty
        case stats(TimingOverviewText)
    }

    public static func shown(_ timing: TopicTimingDTO?, timed: Bool) -> Shown {
        if let timing, timing.runs > 0 { return .stats(TimingOverviewText(timing)) }
        return timed ? .empty : .hidden
    }

    public static let emptyText = "No runs in this range. Start one from the topic, or try a wider range."
}
