import Foundation
import QuickrCore

/// How a topic's due status reads on its tile (the PWA's `DueView`).
public struct DueView: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        /// Due for 30 minutes or more.
        case overdue
        case due
        /// Due within the hour.
        case soon
        case later
        /// No schedule: no badge.
        case none
    }

    public var tone: Tone
    public var label: String

    public init(tone: Tone, label: String) {
        self.tone = tone
        self.label = label
    }

    /// Due now or overdue: the tile gets its accent bar and the loud Log block.
    public var isDue: Bool { tone == .due || tone == .overdue }
}

/// The tile's texts, ported from the PWA (`lib/schedule.ts`, `lib/dates.ts`, `lib/answerDisplay.ts`,
/// `lib/format.ts`). Times are in the device's calendar and locale, like the PWA's `Intl` formats.
public struct TopicText: Sendable {
    /// A due slot is "Due now" for 30 minutes, then "Overdue" (`FRESH_DUE_MS`).
    public static let freshDue: TimeInterval = 30 * 60
    /// The next slot within the hour reads "Due in 25 min" (`SOON_MS`).
    public static let soon: TimeInterval = 60 * 60

    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    /// Due right now: the server says so, or the next slot has passed since it last looked.
    public static func isDueNow(_ due: DueStatus?, now: Date) -> Bool {
        guard let due else { return false }
        if due.isDue { return true }
        return due.nextDueAt.map { $0 <= now } ?? false
    }

    public func dueView(_ due: DueStatus?, now: Date) -> DueView {
        guard let due else { return DueView(tone: .none, label: "") }
        if Self.isDueNow(due, now: now) {
            guard let since = due.isDue ? due.dueSince : due.nextDueAt else { return DueView(tone: .due, label: "Due now") }
            return now.timeIntervalSince(since) < Self.freshDue
                ? DueView(tone: .due, label: "Due now · since \(when(since, now: now))")
                : DueView(tone: .overdue, label: "Overdue · since \(when(since, now: now))")
        }
        guard let next = due.nextDueAt else { return DueView(tone: .none, label: "") }
        let wait = next.timeIntervalSince(now)
        if wait <= Self.soon { return DueView(tone: .soon, label: "Due in \(Self.minutes(wait))") }
        // "Next 9:00 PM" today; "Tomorrow 8:00 AM", "Mon 8:00 AM" or "12 Oct" further out.
        let text = when(next, now: now)
        if text.first?.isNumber == true { return DueView(tone: .later, label: "Next \(text)") }
        return DueView(tone: .later, label: text.prefix(1).uppercased() + text.dropFirst())
    }

    /// "8:00 AM", "yesterday 9:00 PM", "Mon 8:00 AM", "12 Oct", relative to `now` (`formatWhen`).
    public func when(_ date: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date))
            .day ?? 0
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        switch days {
        case 0: return time
        case -1: return "yesterday \(time)"
        case 1: return "tomorrow \(time)"
        case -6...6:
            let weekday = date.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
            return "\(weekday) \(time)"
        default:
            return date.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
        }
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

    /// "25 min", "2 h" (`minutesText`).
    static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        return m >= 60 ? "\(Int((Double(m) / 60).rounded())) h" : "\(m) min"
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
