import Foundation
import QuickrCore

/// The tile's texts, ported from the PWA (`lib/dates.ts`, `lib/answerDisplay.ts`, `lib/format.ts`), in
/// the device's calendar and locale like the PWA's `Intl` formats; answers are the summary line's
/// (`EntrySummary`), the same on every device. Due texts are QuickrCore's `DueView`.
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

    /// One answer as text, or nil when it can't be shown for this question: the summary line's
    /// `EntrySummary.answerText` (content-display.md §1.1), so a row, a tile and a widget read an
    /// answer the same way on every client: no thousands grouping, `.` decimal point rounded half
    /// away from zero, text with its whitespace collapsed (nil when blank).
    public func answer(_ value: AnswerValue, for question: Question) -> String? {
        EntrySummary.answerText(value, for: question)
    }

    /// "1 entry", "1,234 entries" (`plural`).
    public func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted(.number.locale(locale))) \(n == 1 ? one : many ?? one + "s")"
    }
}
