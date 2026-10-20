import Foundation

/// How a topic's due status reads on its tile: the PWA's `dueParts` and `dueView`
/// (`frontend/src/lib/schedule.ts`), checked against `shared/fixtures/home-due-vectors.json`.
///
/// `kind` is the decision (which sentence, which instant, how many minutes) and doesn't depend on
/// the locale. `label(locale:timeZone:)` renders it with the device's formats, as the PWA does
/// with the browser's.
public struct DueView: Sendable, Hashable {
    /// The pill's colour.
    public enum Tone: String, Sendable, Hashable {
        case none
        case due
        case overdue
        case soon
        case later
    }

    public enum Kind: Sendable, Hashable {
        /// No pill: unscheduled, archived, or nothing coming up.
        case none
        /// "Due now": due, with no instant to show.
        case dueNow
        /// "Due now · since 08:00": due for less than `freshFor`.
        case dueSince(When)
        /// "Overdue · since Mon 08:00".
        case overdueSince(When)
        /// "Due in 5 min" / "Due in 1 h": within `soonWithin`.
        case dueIn(minutes: Int)
        /// "Next 21:00": later today.
        case next(When)
        /// "Tomorrow 08:00", "Mon 08:00", "12 Oct".
        case when(When)
    }

    /// An instant and how many local calendar days it is from now (negative in the past).
    public struct When: Sendable, Hashable {
        public var at: Date
        public var dayOffset: Int

        public init(at: Date, dayOffset: Int) {
            self.at = at
            self.dayOffset = dayOffset
        }

        /// The PWA's `whenParts`: the day offset in `calendar`'s timezone.
        public init(at: Date, now: Date, calendar: Calendar) {
            let from = calendar.startOfDay(for: now)
            let to = calendar.startOfDay(for: at)
            // Rounded like the PWA, so a 23 h or 25 h day (DST) still counts as one.
            self.init(at: at, dayOffset: Int((to.timeIntervalSince(from) / 86_400).rounded()))
        }
    }

    /// Due less than this long reads "Due now"; longer, "Overdue" (the PWA's `FRESH_DUE_MS`).
    public static let freshFor: TimeInterval = 30 * 60
    /// The next slot within this reads "Due in …" (`SOON_MS`).
    public static let soonWithin: TimeInterval = 60 * 60

    public var tone: Tone
    public var kind: Kind

    public init(tone: Tone, kind: Kind) {
        self.tone = tone
        self.kind = kind
    }

    /// Due right now: the status says so, or its next slot has passed since it was computed.
    public static func isDueNow(_ due: DueStatus?, now: Date) -> Bool {
        guard let due else { return false }
        if due.isDue { return true }
        guard let next = due.nextDueAt else { return false }
        return next <= now
    }

    /// The PWA's `dueParts(due, now)`, with day offsets in `calendar`'s timezone.
    public init(due: DueStatus?, now: Date, calendar: Calendar = .current) {
        guard let due else {
            self.init(tone: .none, kind: .none)
            return
        }
        if Self.isDueNow(due, now: now) {
            guard let since = due.isDue ? due.dueSince : due.nextDueAt else {
                self.init(tone: .due, kind: .dueNow)
                return
            }
            let when = When(at: since, now: now, calendar: calendar)
            if now.timeIntervalSince(since) < Self.freshFor {
                self.init(tone: .due, kind: .dueSince(when))
            } else {
                self.init(tone: .overdue, kind: .overdueSince(when))
            }
            return
        }
        guard let next = due.nextDueAt else {
            self.init(tone: .none, kind: .none)
            return
        }
        let wait = next.timeIntervalSince(now)
        if wait <= Self.soonWithin {
            self.init(tone: .soon, kind: .dueIn(minutes: Self.minutes(wait)))
            return
        }
        let when = When(at: next, now: now, calendar: calendar)
        self.init(tone: .later, kind: when.dayOffset == 0 ? .next(when) : .when(when))
    }

    /// Whole minutes, at least 1, rounded like JS `Math.round` (halves up).
    public static func minutes(_ seconds: TimeInterval) -> Int { max(1, jsRound(seconds / 60)) }

    /// JS `Math.round`: halves round up, towards +∞.
    static func jsRound(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

    /// The pill's text, "" for `.none`.
    public func label(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch kind {
        case .none: ""
        case .dueNow: "Due now"
        case .dueSince(let when): "Due now · since " + Self.format(when, locale: locale, timeZone: timeZone)
        case .overdueSince(let when): "Overdue · since " + Self.format(when, locale: locale, timeZone: timeZone)
        case .dueIn(let minutes):
            "Due in " + (minutes >= 60 ? "\(Self.jsRound(Double(minutes) / 60)) h" : "\(minutes) min")
        case .next(let when): "Next " + Self.format(when, locale: locale, timeZone: timeZone)
        case .when(let when): Self.capitalized(Self.format(when, locale: locale, timeZone: timeZone))
        }
    }

    /// The PWA's `formatWhen`: "08:00", "yesterday 21:00", "tomorrow 08:00", "Mon 08:00", "12 Oct".
    public static func format(_ when: When, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        time.timeZone = timeZone
        let clock = when.at.formatted(time)
        switch when.dayOffset {
        case 0: return clock
        case -1: return "yesterday " + clock
        case 1: return "tomorrow " + clock
        case -6...6:
            var weekday = Date.FormatStyle(locale: locale).weekday(.abbreviated)
            weekday.timeZone = timeZone
            return when.at.formatted(weekday) + " " + clock
        default:
            var date = Date.FormatStyle(locale: locale).day().month(.abbreviated)
            date.timeZone = timeZone
            return when.at.formatted(date)
        }
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first, !first.isNumber else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
