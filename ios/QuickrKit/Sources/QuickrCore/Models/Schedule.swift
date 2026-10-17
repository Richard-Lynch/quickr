/// A topic's reminder schedule. Times and days are local to `timezone` (an IANA identifier).
public enum Schedule: Sendable, Hashable {
    case daily(Daily)
    case interval(Interval)

    public var timezone: String {
        switch self {
        case .daily(let daily): daily.timezone
        case .interval(let interval): interval.timezone
        }
    }

    public var notify: Bool {
        switch self {
        case .daily(let daily): daily.notify
        case .interval(let interval): interval.notify
        }
    }

    /// Due at each of `times` on each of `days` (ISO weekdays, 1 = Monday … 7 = Sunday).
    public struct Daily: Sendable, Hashable {
        public static let everyDay = [1, 2, 3, 4, 5, 6, 7]

        public var times: [TimeOfDay]
        public var days: [Int]
        public var timezone: String
        public var notify: Bool

        public init(times: [TimeOfDay], days: [Int] = Self.everyDay, timezone: String, notify: Bool = true) {
            self.times = times
            self.days = days
            self.timezone = timezone
            self.notify = notify
        }
    }

    /// Due `everyMinutes` after the last entry (or after the schedule started).
    public struct Interval: Sendable, Hashable {
        public var everyMinutes: Int
        public var timezone: String
        public var notify: Bool

        public init(everyMinutes: Int, timezone: String, notify: Bool = true) {
            self.everyMinutes = everyMinutes
            self.timezone = timezone
            self.notify = notify
        }
    }
}

/// A 24-hour local time, written `HH:MM` on the wire.
public struct TimeOfDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses `HH:MM` (the server's `time_pattern`, `^([01][0-9]|2[0-3]):[0-5][0-9]$`).
    public init?(_ text: String) {
        let utf8 = Array(text.utf8)
        guard utf8.count == 5, utf8[2] == UInt8(ascii: ":") else { return nil }
        let digits = [utf8[0], utf8[1], utf8[3], utf8[4]].map { Int($0) - 48 }
        guard digits.allSatisfy({ (0...9).contains($0) }) else { return nil }
        let hour = digits[0] * 10 + digits[1]
        let minute = digits[2] * 10 + digits[3]
        guard hour < 24, minute < 60 else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var description: String {
        (hour < 10 ? "0" : "") + String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}
