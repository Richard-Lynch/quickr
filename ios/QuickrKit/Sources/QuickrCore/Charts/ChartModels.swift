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

extension EntryRange {
    /// The Overview's bucket until one is picked (`defaultBucket`): days up to 30 days, weeks
    /// beyond.
    public var defaultChartBucket: QuestionSeries.Bucket {
        switch self {
        case .sevenDays, .thirtyDays: .day
        case .ninetyDays, .all: .week
        }
    }
}

// MARK: - Activity strip (content-display.md §4.2)

/// The Overview's activity strip (`activityStrip` in the PWA's `charts/timingModels.ts`):
/// entries per **local calendar day** over the last 12 Monday-started weeks, today last. The
/// first cell is the Monday 11 weeks before this week's Monday (calendar arithmetic on dates,
/// never `now − 84 days`); the grid's slots after today are blank and not listed. An entry counts
/// in the day of its `captured_at` in `timeZone`; entries outside the grid aren't counted. The
/// entries are read from `localMidnight(firstDay)` on, so the query bound and the cells derive
/// from the same date. Checked against `stats-chart-vectors.json` `activity[]`.
public struct ActivityStrip: Sendable, Hashable {
    /// Weeks in the strip (`ACTIVITY_WEEKS`).
    public static let weeks = 12

    public struct Cell: Sendable, Hashable {
        /// The local date, "YYYY-MM-DD".
        public var day: String
        public var count: Int
        /// The intensity step (``ActivityStrip/level(_:)``).
        public var level: Int { ActivityStrip.level(count) }
    }

    /// One column of the grid: a Monday and the entries of its days up to today.
    public struct Week: Sendable, Hashable {
        /// The Monday, "YYYY-MM-DD".
        public var firstDay: String
        public var count: Int

        public init(firstDay: String, count: Int) {
            self.firstDay = firstDay
            self.count = count
        }
    }

    /// The first cell: the Monday 11 weeks before this week's Monday.
    public let firstDay: String
    /// One cell per day from `firstDay` to today, in order (78–84 of them).
    public let cells: [Cell]
    /// The largest cell count (0 when empty).
    public let max: Int
    /// The entries that fell in a cell.
    public let total: Int

    /// `today` is the local date in `timeZone` (``localDay(_:timeZone:)`` of now).
    public init(capturedAt: [Date], today: String, timeZone: TimeZone) {
        let end = Self.dayNumber(today)
        let start = Self.firstDayNumber(end)
        let calendar = Self.calendar(timeZone)
        var counts: [String: Int] = [:]
        for date in capturedAt { counts[Self.localDay(date, calendar: calendar), default: 0] += 1 }
        let cells = (start...end).map { n in
            let day = Self.dayString(n)
            return Cell(day: day, count: counts[day] ?? 0)
        }
        firstDay = Self.dayString(start)
        self.cells = cells
        max = cells.map(\.count).max() ?? 0
        total = cells.reduce(0) { $0 + $1.count }
    }

    /// The grid's columns, oldest first: each Monday and its entries (the last one up to today).
    public var columns: [Week] {
        stride(from: 0, to: cells.count, by: 7).map { index in
            Week(firstDay: cells[index].day, count: cells[index..<Swift.min(index + 7, cells.count)].reduce(0) { $0 + $1.count })
        }
    }

    /// A column as VoiceOver reads it: "Week of 3 Nov: 5 entries" (en-GB; "Week of Nov 3" in
    /// en-US).
    public static func spokenWeek(_ week: Week, locale: Locale = .autoupdatingCurrent) -> String {
        "\(weekLabel(week.firstDay, locale: locale)): \(ChartFormat.plural(week.count, "entry", "entries", locale: locale))"
    }

    /// A column's name: "Week of 3 Nov" (its Monday, a calendar date, so in no zone).
    public static func weekLabel(_ monday: String, locale: Locale = .autoupdatingCurrent) -> String {
        let utc = TimeZone(identifier: "UTC")!
        return ChartFormat.bucket(localMidnight(monday, timeZone: utc), .week, style: .long, timeZone: utc, locale: locale)
    }

    /// The caption: "12 entries in the last 12 weeks".
    public func caption(locale: Locale = .autoupdatingCurrent) -> String {
        "\(ChartFormat.plural(total, "entry", "entries", locale: locale)) in the last \(Self.weeks) weeks"
    }

    /// The first cell for `today` (the query bound's date), without counting anything.
    public static func firstDay(today: String) -> String { dayString(firstDayNumber(dayNumber(today))) }

    /// `activityLevel`: 0, 1, 2–3, 4+ → 0–3 (`sunken`, then the tint at 35/65/100 %).
    public static func level(_ count: Int) -> Int {
        count <= 0 ? 0 : count == 1 ? 1 : count <= 3 ? 2 : 3
    }

    /// `localDay`: `date`'s local calendar date in `timeZone`, "YYYY-MM-DD".
    public static func localDay(_ date: Date, timeZone: TimeZone) -> String {
        localDay(date, calendar: calendar(timeZone))
    }

    /// `localMidnight`: the first instant of `day` in `timeZone`: local midnight, or the end of
    /// the gap when the clocks skip midnight (America/Santiago). Searched to the millisecond like
    /// the PWA, so both send the same `captured_from`.
    public static func localMidnight(_ day: String, timeZone: TimeZone) -> Date {
        let calendar = calendar(timeZone)
        // Every zone's offset is within ±14 h, so the answer is within 15 h of UTC midnight.
        let utc = Int64(dayNumber(day)) * dayMs
        var lo = utc - 15 * 3_600_000
        var hi = utc + 15 * 3_600_000
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if localDay(date(ms: mid), calendar: calendar) >= day { hi = mid } else { lo = mid }
        }
        return date(ms: hi)
    }

    private static let dayMs: Int64 = 86_400_000

    private static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func localDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return dayString(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The Monday 11 weeks before the Monday of day number `end`'s week.
    private static func firstDayNumber(_ end: Int) -> Int {
        // 1970-01-01 was a Thursday: Monday is 0 here.
        let weekday = ((end + 3) % 7 + 7) % 7
        return end - weekday - 7 * (weeks - 1)
    }

    /// `addDays`: `day` plus `n` calendar days.
    public static func addDays(_ day: String, _ n: Int) -> String { dayString(dayNumber(day) + n) }

    /// Days since 1970-01-01 of a "YYYY-MM-DD" date (proleptic Gregorian, no zone).
    private static func dayNumber(_ day: String) -> Int {
        let parts = day.split(separator: "-").map { Int($0) ?? 0 }
        guard parts.count == 3 else { return 0 }
        // Howard Hinnant's days_from_civil.
        let (m, d) = (parts[1], parts[2])
        let y = m <= 2 ? parts[0] - 1 : parts[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The "YYYY-MM-DD" date of day number `n` (`civil_from_days`).
    private static func dayString(_ n: Int) -> String {
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return dayString(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    private static func dayString(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - Sparklines (content-display.md §4.3)

/// A numeric card's trend (`sparkline` in the PWA's `charts/timingModels.ts`): the bucket means
/// as a small line `width` × 48 pt. x by bucket start (the first drawn point at the inset, the
/// last at `width − inset`; one point sits at the right edge), y from the smallest mean (bottom)
/// to the largest (top), a flat line in the middle. Buckets without a mean are skipped; nil when
/// none has one. Coordinates are rounded half up to 0.01 like the PWA's. Checked against
/// `stats-chart-vectors.json` `sparklines[]`.
public struct SparklineModel: Sendable, Hashable {
    /// `SPARK_LAYOUT`: the height and the inset (room for the last point's dot).
    public static let height: Double = 48
    public static let pad: Double = 4

    public struct Point: Sendable, Hashable {
        public var x: Double
        public var y: Double
    }

    /// One point per bucket with a mean, in time order; y grows downward.
    public let path: [Point]
    /// The marked point (the last one) and its unrounded mean.
    public let last: Point
    public let lastValue: Double
    /// The smallest and largest mean drawn (the end labels).
    public let min: Double
    public let max: Double

    public init?(series points: [QuestionSeries.Point], width: Double) {
        let data = points.compactMap { point in point.mean.map { (start: point.start, mean: $0) } }
        guard let lastPoint = data.last, let first = data.first else { return nil }
        let (height, pad) = (Self.height, Self.pad)
        let means = data.map(\.mean)
        let min = means.min() ?? 0
        let max = means.max() ?? 0
        let t0 = LineChartModel.milliseconds(first.start)
        let t1 = LineChartModel.milliseconds(lastPoint.start)
        func x(_ t: Double) -> Double { t1 == t0 ? width - pad : pad + (t - t0) / (t1 - t0) * (width - 2 * pad) }
        func y(_ v: Double) -> Double { max == min ? height / 2 : pad + (max - v) / (max - min) * (height - 2 * pad) }
        let path = data.map { Point(x: Self.round2(x(LineChartModel.milliseconds($0.start))), y: Self.round2(y($0.mean))) }
        self.path = path
        last = path[path.count - 1]
        lastValue = lastPoint.mean
        self.min = min
        self.max = max
    }

    /// `Math.round(v * 100) / 100`: a half toward +∞.
    static func round2(_ value: Double) -> Double { Double(ChartFormat.jsRound(value * 100)) / 100 }
}
