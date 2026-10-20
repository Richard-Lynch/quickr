import Foundation

/// The Overview's text: the PWA's `formatNumber`, `formatPercent`, `plural` (`lib/format.ts`),
/// `formatTick` and `formatBucket` (`components/charts/chartUtils.ts`) and `formatDate`
/// (`lib/dates.ts`). The PWA formats in the browser's locale and zone; here they are parameters,
/// `.autoupdatingCurrent` in the app. Checked in en-US against
/// `shared/fixtures/stats-chart-vectors.json`.
public enum ChartFormat {
    /// `formatNumber`: grouped, at most `maxDecimals` fraction digits, halves away from zero
    /// (ICU's default); "—" for nil, NaN and infinities.
    public static func number(_ value: Double?, maxDecimals: Int = 2, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(
            .number.precision(.fractionLength(0...maxDecimals)).rounded(rule: .toNearestOrAwayFromZero).locale(locale))
    }

    /// An integer as `toLocaleString()` prints it: grouped.
    public static func count(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }

    /// `formatPercent`: `Math.round(share * 100)` and "%". `Math.round` takes a half up (toward +∞).
    public static func percent(_ share: Double) -> String {
        "\(jsRound(share * 100))%"
    }

    /// `plural`: "1 distinct answer", "2 distinct answers".
    public static func plural(_ n: Int, _ one: String, _ many: String? = nil, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        "\(count(n, locale: locale)) \(n == 1 ? one : many ?? "\(one)s")"
    }

    /// `formatTick`: compact ("1.5K", "2.46M"), at most 2 fraction digits.
    public static func tick(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...2)).rounded(rule: .toNearestOrAwayFromZero)
                .locale(locale))
    }

    public enum BucketStyle: Sendable {
        /// Axis labels: "Mar 29"; months "Mar 25" (two-digit year).
        case short
        /// Tooltips: "Mar 29", "Week of Mar 29", "March 2025".
        case long
    }

    /// `formatBucket`: a bucket's start in the reader's zone.
    public static func bucket(
        _ start: Date, _ bucket: QuestionSeries.Bucket, style: BucketStyle = .short,
        timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if bucket == .month {
            return format(start, template: style == .short ? "MMMyy" : "MMMMyyyy", timeZone: timeZone, locale: locale)
        }
        let day = format(start, template: "MMMd", timeZone: timeZone, locale: locale)
        return bucket == .week && style == .long ? "Week of \(day)" : day
    }

    /// `formatDate`: the medium date style ("Mar 29, 2025").
    public static func date(
        _ date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    )
        -> String
    {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func format(_ date: Date, template: String, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// JavaScript's `Math.round`: the nearest integer, a half toward +∞.
    static func jsRound(_ x: Double) -> Int {
        let floor = x.rounded(.down)
        return Int(x - floor >= 0.5 ? floor + 1 : floor)
    }
}
