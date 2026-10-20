import Foundation

/// The Overview's charts as data: what each chart shows, its value axis and which x labels fit.
/// Ports of the PWA's `components/charts/chartModels.ts` and `chartUtils.ts`, with the same
/// arithmetic in the same order, so positions and ticks agree to the bit. The server buckets;
/// these only lay its buckets out. Checked against `shared/fixtures/stats-chart-vectors.json`.
public enum ChartScale {
    /// `niceTicks`: steps of 1, 2, 2.5 or 5 × 10ⁿ that cover `[min, max]` in about `count` steps.
    /// A flat range is padded by 10% (or 1 around zero). `[0]` for a non-finite bound.
    public static func niceTicks(min: Double, max: Double, count: Int = 4) -> [Double] {
        guard min.isFinite, max.isFinite else { return [0] }
        var low = min
        var high = max
        if low == high {
            let pad = abs(low) * 0.1
            let padding = pad == 0 ? 1 : pad
            low -= padding
            high += padding
        }
        let span = high - low
        let raw = span / Double(count)
        let mag = pow(10, (log10(raw)).rounded(.down))
        let step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { span / $0 <= Double(count) } ?? 10 * mag
        let start = (low / step).rounded(.down) * step
        let end = (high / step).rounded(.up) * step
        var ticks: [Double] = []
        var value = start
        while value <= end + step * 1e-9 {
            ticks.append(toFixed10(value))
            value += step
        }
        return ticks
    }

    /// `scaleLinear`: maps `[d0, d1]` onto `[r0, r1]` (a zero-width domain counts as 1).
    public static func linear(_ d0: Double, _ d1: Double, _ r0: Double, _ r1: Double) -> @Sendable (Double) -> Double {
        let span = d1 - d0 == 0 ? 1 : d1 - d0
        return { v in r0 + ((v - d0) / span) * (r1 - r0) }
    }

    /// `pickLabels`: the indices of the x positions to label so labels never collide. Always the
    /// last; then walking left, every one at least `minGap` from the last kept.
    public static func pickLabels(_ xs: [Double], minGap: Double) -> Set<Int> {
        var keep = Set<Int>()
        var lastX = Double.infinity
        for index in xs.indices.reversed() where lastX - xs[index] >= minGap {
            keep.insert(index)
            lastX = xs[index]
        }
        return keep
    }

    /// `Number(v.toFixed(10))`: rounded to 10 decimals, which absorbs the step's float drift.
    static func toFixed10(_ value: Double) -> Double {
        Double(String(format: "%.10f", value)) ?? value
    }
}

/// The minimum gap between two x labels, in points (the PWA's px).
public let chartLabelGap: Double = 52

/// The mean per bucket, with a min–max band (`lineModel`). Nil when no bucket has a mean.
public struct LineChartModel: Sendable {
    public static let height: Double = 170
    public static let padTop: Double = 10
    public static let padRight: Double = 8
    public static let padBottom: Double = 22
    public static let padLeft: Double = 36

    /// The buckets with a mean, in order, and their indices in the series.
    public let points: [QuestionSeries.Point]
    public let kept: [Int]
    /// The value axis: its first and last ticks are the domain.
    public let ticks: [Double]
    /// Each kept bucket's x position in a chart `width` wide.
    public let xs: [Double]
    /// Indices of `points` whose x label is drawn.
    public let labelled: Set<Int>

    public init?(series points: [QuestionSeries.Point], width: Double) {
        let kept = points.indices.filter { points[$0].mean != nil }
        guard !kept.isEmpty else { return nil }
        let data = kept.map { points[$0] }
        let lows = data.map { $0.min ?? $0.mean ?? 0 }
        let highs = data.map { $0.max ?? $0.mean ?? 0 }
        let ticks = ChartScale.niceTicks(min: lows.min()!, max: highs.max()!, count: 4)
        let t0 = Self.milliseconds(data[0].start)
        let t1 = Self.milliseconds(data[data.count - 1].start)
        let x = ChartScale.linear(
            t0, t1 == t0 ? t0 + 1 : t1,
            Self.padLeft + (t1 == t0 ? (width - Self.padLeft - Self.padRight) / 2 : 0), width - Self.padRight)
        let xs = data.map { x(Self.milliseconds($0.start)) }
        self.points = data
        self.kept = kept
        self.ticks = ticks
        self.xs = xs
        labelled = ChartScale.pickLabels(xs, minGap: chartLabelGap)
    }

    /// The value domain (the first and last ticks).
    public var domain: ClosedRange<Double> { (ticks.first ?? 0)...(ticks.last ?? 1) }

    /// `Date.getTime()`.
    static func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
}

/// Counts per option per bucket, stacked (`stackedModel`). Nil when no bucket has an answer.
public struct StackedBarsModel: Sendable {
    public static let height: Double = 150
    public static let padTop: Double = 6
    public static let padBottom: Double = 20
    public static let gap: Double = 3

    public struct LegendItem: Sendable, Hashable {
        public var value: String
        public var label: String
    }

    /// The buckets with answers, in order, and their indices in the series.
    public let points: [QuestionSeries.Point]
    public let kept: [Int]
    /// The tallest bucket's total (at least 1).
    public let max: Int
    public let barWidth: Double
    public let offset: Double
    /// The options that appear: config order first, then unknown values (a retired option) in
    /// order of appearance, each bucket's sorted.
    public let legend: [LegendItem]
    public let labelled: Set<Int>

    public init?(series points: [QuestionSeries.Point], options: [EnumOption], width: Double) {
        let kept = points.indices.filter { points[$0].count > 0 }
        guard !kept.isEmpty else { return nil }
        let data = kept.map { points[$0] }
        let gap = Self.gap
        let max = Swift.max(1, data.map(Self.total).max() ?? 0)
        let barWidth = Swift.min(36, (width - gap * Double(data.count - 1)) / Double(data.count))
        let used = barWidth * Double(data.count) + gap * Double(data.count - 1)
        let offset = (width - used) / 2
        var seen: [String] = []
        for point in data {
            for value in point.optionCounts.keys.sorted() where !seen.contains(value) { seen.append(value) }
        }
        let known = Set(options.map(\.value))
        let legend =
            options.filter { seen.contains($0.value) }.map { LegendItem(value: $0.value, label: $0.label) }
            + seen.filter { !known.contains($0) }.map { LegendItem(value: $0, label: $0) }
        self.points = data
        self.kept = kept
        self.max = max
        self.barWidth = barWidth
        self.offset = offset
        self.legend = legend
        labelled = ChartScale.pickLabels(
            data.indices.map { offset + Double($0) * (barWidth + gap) + barWidth / 2 }, minGap: chartLabelGap)
    }

    /// A bucket's total: every selection (a multi-select entry counts once per option).
    public static func total(_ point: QuestionSeries.Point) -> Int { point.optionCounts.values.reduce(0, +) }

    /// `stackSegments`: a bucket's segments bottom up, in legend order, without empty ones.
    public func segments(_ point: QuestionSeries.Point) -> [(value: String, count: Int)] {
        legend.compactMap { item in
            let count = point.optionCounts[item.value] ?? 0
            return count > 0 ? (item.value, count) : nil
        }
    }
}

/// An enum question's card (`enumView`, `optionColors`).
public struct ChoiceView: Sendable {
    /// The bars: archived options only when they were picked.
    public let visible: [QuestionStats.OptionCount]
    /// "Most often": the first option with the highest count, when any was picked.
    public let top: QuestionStats.OptionCount?

    public init(_ stats: QuestionStats.Choice) {
        visible = stats.options.filter { !$0.option.archived || $0.count > 0 }
        let best = stats.options.map(\.count).max() ?? 0
        top = best > 0 ? stats.options.first { $0.count == best } : nil
    }

    /// The option's colour slot: its position in the question's options, for the first six;
    /// nil ("other") after that or for a value the question doesn't have.
    public static func colorSlot(_ value: String, in options: [EnumOption]) -> Int? {
        guard let index = options.firstIndex(where: { $0.value == value }), index < chartSeriesColors else {
            return nil
        }
        return index
    }
}

/// The number of series colours before options share the "other" colour.
public let chartSeriesColors = 6

/// The Overview's default bucket (`defaultBucket`): days up to 30 days, weeks beyond.
public enum ChartDefaults {
    public static func bucket(forRangeDays days: Int?) -> QuestionSeries.Bucket {
        guard let days else { return .week }
        return days <= 30 ? .day : .week
    }
}
