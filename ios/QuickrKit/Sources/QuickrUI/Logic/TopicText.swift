import Foundation
import QuickrCore

/// The tile's texts, ported from the PWA (`lib/dates.ts`, `lib/answerDisplay.ts`, `lib/format.ts`), in
/// the device's calendar and locale like the PWA's `Intl` formats. Due texts are QuickrCore's `DueView`.
public struct TopicText: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    /// "4 hours ago", "yesterday", "just now", "never" (`formatRelative`: the largest whole unit,
    /// rounded, with named days like `Intl.RelativeTimeFormat`'s `numeric: 'auto'`).
    public func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = date.timeIntervalSince(now)
        let units: [(Calendar.Component, TimeInterval)] = [
            (.year, 365 * 86_400), (.month, 30 * 86_400), (.weekOfMonth, 7 * 86_400), (.day, 86_400),
            (.hour, 3600), (.minute, 60),
        ]
        for (unit, size) in units where abs(seconds) >= size {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            var components = DateComponents()
            components.setValue(Int((seconds / size).rounded()), for: unit)
            return formatter.localizedString(from: components)
        }
        return "just now"
    }

    /// One answer as text, or nil when it can't be shown for this question (`formatAnswer`).
    public func answer(_ value: AnswerValue, for question: Question) -> String? {
        switch question.kind {
        case .int(let rules):
            guard let n = value.number else { return nil }
            return number(n, maxDecimals: 0) + (rules.unit.map { " \($0)" } ?? "")
        case .double(let rules):
            guard let n = value.number else { return nil }
            return number(n, maxDecimals: rules.decimals ?? 3) + (rules.unit.map { " \($0)" } ?? "")
        case .choice(let rules):
            let label = { (value: String) in rules.options.first { $0.value == value }?.label ?? value }
            switch value {
            case .string(let v): return label(v)
            case .strings(let vs): return vs.isEmpty ? nil : vs.map(label).joined(separator: ", ")
            default: return nil
            }
        case .string:
            if case .string(let s) = value { return s }
            return nil
        }
    }

    /// "1 entry", "1,234 entries" (`plural`).
    public func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted(.number.locale(locale))) \(n == 1 ? one : many ?? one + "s")"
    }

    /// `toLocaleString(undefined, { maximumFractionDigits })`.
    public func number(_ n: Double, maxDecimals: Int) -> String {
        n.formatted(.number.precision(.fractionLength(0...max(0, maxDecimals))).locale(locale))
    }
}

extension AnswerValue {
    fileprivate var number: Double? {
        switch self {
        case .int(let n): Double(n)
        case .double(let x): x
        default: nil
        }
    }
}
