import Foundation

/// The schedule editor's state and rules, ported from the PWA's `frontend/src/lib/schedule.ts`:
/// an editable draft, its validation (the PWA's messages, in its order), the API shape it sends,
/// the draft a saved schedule opens as, and the human description. `schedule-vectors.json` pins
/// it to the PWA.
public struct ScheduleDraft: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case none, daily, interval
    }

    public enum Unit: String, Sendable, Hashable, CaseIterable {
        case minutes, hours, days

        public var minutes: Int {
            switch self {
            case .minutes: 1
            case .hours: 60
            case .days: 1440
            }
        }
    }

    public var kind: Kind
    /// `HH:MM` texts, as edited.
    public var times: [String]
    /// ISO weekdays, 1 = Monday … 7 = Sunday.
    public var days: [Int]
    public var timezone: String
    /// The interval's count, as typed.
    public var every: String
    public var unit: Unit
    public var notify: Bool

    public static let allDays = [1, 2, 3, 4, 5, 6, 7]

    public init(
        kind: Kind, times: [String], days: [Int], timezone: String, every: String, unit: Unit, notify: Bool
    ) {
        self.kind = kind
        self.times = times
        self.days = days
        self.timezone = timezone
        self.every = every
        self.unit = unit
        self.notify = notify
    }

    /// No schedule yet; switching to Daily starts at 08:00 every day (`emptyScheduleDraft`).
    public static func empty(timezone: String) -> ScheduleDraft {
        ScheduleDraft(
            kind: .none, times: ["08:00"], days: allDays, timezone: timezone, every: "1", unit: .days, notify: true)
    }

    /// The draft a saved schedule opens as (`draftFromSchedule`); `timezone` fills what it doesn't
    /// set (the device's zone).
    public init(schedule: Schedule?, timezone: String) {
        self = .empty(timezone: timezone)
        switch schedule {
        case nil:
            break
        case .daily(let daily):
            kind = .daily
            times = daily.times.map(\.description)
            days = daily.days
            self.timezone = daily.timezone
            notify = daily.notify
        case .interval(let interval):
            kind = .interval
            (every, unit) = Self.split(minutes: interval.everyMinutes)
            self.timezone = interval.timezone
            notify = interval.notify
        }
    }

    /// The largest unit that holds `minutes` exactly: "every 2 days", not 2880 minutes
    /// (`splitInterval`).
    public static func split(minutes: Int) -> (every: String, unit: Unit) {
        if minutes % 1440 == 0 { return (String(minutes / 1440), .days) }
        if minutes % 60 == 0 { return (String(minutes / 60), .hours) }
        return (String(minutes), .minutes)
    }

    /// The time "+ Time" adds: 12 hours after the last one, else 08:00 (`nextScheduleTime`).
    public static func nextTime(after times: [String]) -> String {
        guard let last = times.last, let (hour, minute) = twoByTwoDigits(last) else { return "08:00" }
        let h = (hour + 12) % 24
        let candidate = (h < 10 ? "0" : "") + String(h) + ":" + minute
        return times.contains(candidate) ? "12:00" : candidate
    }

    /// `^(\d{2}):(\d{2})$` with ASCII digits: the hour as a number, the minutes as written.
    private static func twoByTwoDigits(_ text: String) -> (Int, String)? {
        let utf8 = Array(text.utf8)
        guard utf8.count == 5, utf8[2] == UInt8(ascii: ":"),
            [utf8[0], utf8[1], utf8[3], utf8[4]].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return (Int(utf8[0] - 48) * 10 + Int(utf8[1] - 48), String(text.suffix(2)))
    }
}

// MARK: - Validation

/// A schedule field, where a validation message belongs (the PWA's draft paths, without the
/// `schedule.` prefix).
public enum ScheduleField: Sendable, Hashable {
    case kind
    /// One time, by index.
    case time(Int)
    /// The list of times as a whole.
    case times
    case days
    case every
    case timezone
    case notify

    /// The PWA's path (`times.0.value`, `every`…).
    public var path: String {
        switch self {
        case .kind: "kind"
        case .time(let i): "times.\(i).value"
        case .times: "times"
        case .days: "days"
        case .every: "every"
        case .timezone: "timezone"
        case .notify: "notify"
        }
    }

    /// The field a server error lands on: `path` is relative to the request body
    /// (`schedule.times.0`, `schedule.every_minutes`…). Nil when it isn't a schedule path
    /// (`scheduleFieldFor`).
    public init?(serverPath path: String) {
        if path == "schedule" || path == "schedule.kind" {
            self = .kind
            return
        }
        guard path.hasPrefix("schedule."), path.count > "schedule.".count else { return nil }
        let rest = String(path.dropFirst("schedule.".count))
        if rest.hasPrefix("times."), let i = Self.asciiIndex(rest.dropFirst("times.".count)) {
            self = .time(i)
        } else if rest == "times" {
            self = .times
        } else if rest == "days" || rest.hasPrefix("days.") {
            self = .days
        } else if rest == "every_minutes" {
            self = .every
        } else if rest == "timezone" {
            self = .timezone
        } else if rest == "notify" {
            self = .notify
        } else {
            self = .kind
        }
    }

    /// `\d+` (ASCII) as an index.
    private static func asciiIndex(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(text)
    }
}

public struct ScheduleIssue: Sendable, Hashable {
    public var field: ScheduleField
    public var message: String

    public init(field: ScheduleField, message: String) {
        self.field = field
        self.message = message
    }
}

/// Why a schedule draft can't be saved: every issue, in the PWA's order.
public struct ScheduleIssues: Error, Sendable, Hashable {
    public var issues: [ScheduleIssue]

    public init(_ issues: [ScheduleIssue]) { self.issues = issues }

    /// The first message for each field (what the field shows).
    public var byField: [ScheduleField: String] {
        var result: [ScheduleField: String] = [:]
        for issue in issues where result[issue.field] == nil { result[issue.field] = issue.message }
        return result
    }
}

extension ScheduleDraft {
    /// Validates the draft and converts it to the schedule it saves; nil means "no schedule"
    /// (`scheduleFromDraft`). `isKnownTimeZone` is the platform's zone list (the server checks its
    /// own).
    public func validated(
        limits: Limits, isKnownTimeZone: (String) -> Bool = ScheduleDraft.isKnownTimeZone
    ) -> Result<Schedule?, ScheduleIssues> {
        if kind == .none { return .success(nil) }
        var issues: [ScheduleIssue] = []
        let zone = JSNumber.trim(timezone)
        if zone.isEmpty {
            issues.append(ScheduleIssue(field: .timezone, message: ScheduleMessage.pickZone))
        } else if zone.utf16.count > 64 || !isKnownTimeZone(zone) {
            issues.append(ScheduleIssue(field: .timezone, message: ScheduleMessage.unknownZone))
        }

        if kind == .daily {
            let pattern = Self.timeRegex(limits.timePattern)
            var seen: Set<String> = []
            var parsed: [TimeOfDay] = []
            for (i, raw) in times.enumerated() {
                let value = JSNumber.trim(raw)
                if value.isEmpty {
                    issues.append(ScheduleIssue(field: .time(i), message: ScheduleMessage.enterTime))
                } else if value.firstMatch(of: pattern) == nil {  // RegExp.test: a search
                    issues.append(ScheduleIssue(field: .time(i), message: ScheduleMessage.twentyFourHour))
                } else if seen.contains(value) {
                    issues.append(ScheduleIssue(field: .time(i), message: ScheduleMessage.duplicateTime(value)))
                } else if let time = TimeOfDay(value) {
                    parsed.append(time)
                } else {
                    // A server pattern wider than `HH:MM`: the wire format can't carry it.
                    issues.append(ScheduleIssue(field: .time(i), message: ScheduleMessage.twentyFourHour))
                }
                seen.insert(value)
            }
            if times.isEmpty {
                issues.append(ScheduleIssue(field: .times, message: ScheduleMessage.addTime))
            } else if times.count > limits.scheduleMaxTimes {
                issues.append(
                    ScheduleIssue(field: .times, message: ScheduleMessage.tooManyTimes(limits.scheduleMaxTimes)))
            }
            var unique: [Int] = []
            for day in days where (1...7).contains(day) && !unique.contains(day) { unique.append(day) }
            if unique.isEmpty { issues.append(ScheduleIssue(field: .days, message: ScheduleMessage.pickDay)) }
            guard issues.isEmpty else { return .failure(ScheduleIssues(issues)) }
            return .success(
                .daily(Schedule.Daily(times: parsed, days: unique.sorted(), timezone: zone, notify: notify)))
        }

        let raw = JSNumber.trim(every)
        var minutes: Int?
        if raw.isEmpty {
            issues.append(ScheduleIssue(field: .every, message: ScheduleMessage.enterHowOften))
        } else if !raw.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
            || (Double(raw) ?? 0) < 1
        {
            issues.append(ScheduleIssue(field: .every, message: ScheduleMessage.wholeNumber))
        } else {
            // JS arithmetic: a number, so an enormous count is merely "too much", never an overflow.
            let total = (Double(raw) ?? .infinity) * Double(unit.minutes)
            if total < Double(limits.intervalMinMinutes) {
                issues.append(
                    ScheduleIssue(field: .every, message: ScheduleMessage.atLeast(limits.intervalMinMinutes)))
            } else if total > Double(limits.intervalMaxMinutes) {
                issues.append(
                    ScheduleIssue(field: .every, message: ScheduleMessage.atMost(limits.intervalMaxMinutes)))
            } else {
                minutes = Int(total)
            }
        }
        guard issues.isEmpty, let minutes else { return .failure(ScheduleIssues(issues)) }
        return .success(.interval(Schedule.Interval(everyMinutes: minutes, timezone: zone, notify: notify)))
    }

    /// An IANA zone this device knows (the PWA asks `Intl`).
    public static func isKnownTimeZone(_ identifier: String) -> Bool {
        TimeZone(identifier: identifier) != nil
    }

    /// The server's `time_pattern`; a broken one falls back to the default (`patternOf`).
    static func timeRegex(_ pattern: String) -> Regex<AnyRegexOutput> {
        // swift-format-ignore: NeverUseForceTry
        (try? Regex(pattern)) ?? (try! Regex(Limits.serverDefaults.timePattern))
    }
}

/// The schedule editor's messages (`schedule.ts`).
public enum ScheduleMessage {
    public static let pickZone = "Pick a time zone"
    public static let unknownZone = "Unknown time zone (e.g. Europe/London, UTC)"
    public static let enterTime = "Enter a time"
    public static let twentyFourHour = "Use a 24-hour time like 08:00"
    public static let addTime = "Add at least one time"
    public static let pickDay = "Pick at least one day"
    public static let enterHowOften = "Enter how often"
    public static let wholeNumber = "Enter a whole number"

    public static func duplicateTime(_ time: String) -> String { "\(time) is already in the list" }
    public static func tooManyTimes(_ max: Int) -> String { "At most \(max) times a day" }
    public static func atLeast(_ minutes: Int) -> String { "At least every \(ScheduleText.minutes(minutes))" }
    public static func atMost(_ minutes: Int) -> String { "At most every \(ScheduleText.minutes(minutes))" }
}

// MARK: - Text

/// How a schedule reads (`describeSchedule`): "Daily 08:00, 21:00 · weekdays", "Every 3 hours".
public enum ScheduleText {
    public static let dayShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    public static func describe(_ schedule: Schedule?) -> String {
        switch schedule {
        case nil:
            return "No schedule"
        case .interval(let interval):
            return "Every \(minutes(interval.everyMinutes))"
        case .daily(let daily):
            let range = dayRange(daily.days)
            return "Daily \(daily.times.map(\.description).joined(separator: ", "))"
                + (range == "every day" ? "" : " · \(range)")
        }
    }

    /// "1 minute", "15 minutes", "3 hours", "1 day" (`formatMinutes`).
    public static func minutes(_ n: Int) -> String {
        let (every, unit) = ScheduleDraft.split(minutes: n)
        return "\(every) \(every == "1" ? String(unit.rawValue.dropLast()) : unit.rawValue)"
    }

    /// "every day", "weekdays", "weekends" or "Mon, Wed, Fri" (`dayRange`).
    public static func dayRange(_ days: [Int]) -> String {
        let set = Set(days).sorted()
        if set.count == 7 { return "every day" }
        if set == [1, 2, 3, 4, 5] { return "weekdays" }
        if set == [6, 7] { return "weekends" }
        return set.map { (1...7).contains($0) ? dayShort[$0 - 1] : "?" }.joined(separator: ", ")
    }
}
