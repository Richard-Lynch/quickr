import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/due-vectors.json`, decoded once (see shared/fixtures/README.md for the shape).
struct DueVectors: Sendable {
    struct DueCase: Sendable, CustomTestStringConvertible {
        var name: String
        var schedule: Schedule
        var now: Date
        var lastEntryAt: Date?
        var scheduleSince: Date
        var archived: Bool
        var expected: DueStatus
        var testDescription: String { name }
    }

    struct SlotCase: Sendable, CustomTestStringConvertible {
        var name: String
        var schedule: Schedule.Daily
        var start: Date
        var end: Date
        var expected: [Date]
        var testDescription: String { name }
    }

    struct MessageCase: Sendable, CustomTestStringConvertible {
        var name: String
        var timezone: String
        var dueSince: Date
        var now: Date
        var expected: String
        var testDescription: String { name }
    }

    var due: [DueCase]
    var slots: [SlotCase]
    var messages: [MessageCase]
    var counts: [String: Int]
    var earlyWindowMaxSeconds: Int
    var lookbackDays: Int
    var lookaheadDays: Int
    var tzdata: String

    static let shared: DueVectors = {
        do {
            return try DueVectors(json: Fixtures.dueVectors())
        } catch {
            fatalError("due-vectors.json: \(error)")
        }
    }()

    private struct Malformed: Error, CustomStringConvertible {
        var description: String
    }

    init(json: Data) throws {
        let root = try Self.object(JSONSerialization.jsonObject(with: json), "root")
        let meta = try Self.object(root["meta"], "meta")
        counts = try Self.cast(meta["counts"], "meta.counts")
        earlyWindowMaxSeconds = try Self.cast(meta["early_window_max_seconds"], "meta.early_window_max_seconds")
        lookbackDays = try Self.cast(meta["lookback_days"], "meta.lookback_days")
        lookaheadDays = try Self.cast(meta["lookahead_days"], "meta.lookahead_days")
        tzdata = try Self.cast(meta["tzdata"], "meta.tzdata")

        let rawSchedules = try Self.object(root["schedules"], "schedules")
        var schedules: [String: Schedule] = [:]
        for (id, raw) in rawSchedules { schedules[id] = try Self.schedule(Self.object(raw, id)) }
        func schedule(_ value: Any?) throws -> Schedule {
            let id: String = try Self.cast(value, "schedule id")
            guard let schedule = schedules[id] else { throw Malformed(description: "unknown schedule \(id)") }
            return schedule
        }

        due = try Self.cases(root["due"], "due").map { raw in
            let name: String = try Self.cast(raw["name"], "due.name")
            let expected = try Self.object(raw["expected"], name)
            return DueCase(
                name: name, schedule: try schedule(raw["schedule"]), now: try Self.date(raw["now"]),
                lastEntryAt: try Self.optionalDate(raw["last_entry_at"]),
                scheduleSince: try Self.date(raw["schedule_since"]), archived: try Self.cast(raw["archived"], name),
                expected: DueStatus(
                    isDue: try Self.cast(expected["is_due"], name),
                    dueSince: try Self.optionalDate(expected["due_since"]),
                    nextDueAt: try Self.optionalDate(expected["next_due_at"]),
                    lastEntryAt: try Self.optionalDate(expected["last_entry_at"])))
        }
        slots = try Self.cases(root["slots"], "slots").map { raw in
            let name: String = try Self.cast(raw["name"], "slots.name")
            guard case .daily(let daily) = try schedule(raw["schedule"]) else {
                throw Malformed(description: "\(name): slots need a daily schedule")
            }
            let expected: [Any] = try Self.cast(raw["expected"], name)
            return SlotCase(
                name: name, schedule: daily, start: try Self.date(raw["start"]), end: try Self.date(raw["end"]),
                expected: try expected.map(Self.date))
        }
        messages = try Self.cases(root["messages"], "messages").map { raw in
            let name: String = try Self.cast(raw["name"], "messages.name")
            return MessageCase(
                name: name, timezone: try Self.cast(raw["timezone"], name), dueSince: try Self.date(raw["due_since"]),
                now: try Self.date(raw["now"]), expected: try Self.cast(raw["expected"], name))
        }
    }

    private static func schedule(_ raw: [String: Any]) throws -> Schedule {
        let timezone: String = try cast(raw["timezone"], "timezone")
        let notify = raw["notify"] as? Bool ?? true
        switch raw["kind"] as? String ?? "daily" {
        case "daily":
            let texts: [String] = try cast(raw["times"], "times")
            let times = try texts.map { text in
                guard let time = TimeOfDay(text) else { throw Malformed(description: "bad time \(text)") }
                return time
            }
            let days = raw["days"] as? [Int] ?? Schedule.Daily.everyDay
            return .daily(.init(times: times, days: days, timezone: timezone, notify: notify))
        case "interval":
            return .interval(.init(everyMinutes: try cast(raw["every_minutes"], "every_minutes"), timezone: timezone))
        case let kind:
            throw Malformed(description: "unknown schedule kind \(kind)")
        }
    }

    private static func cases(_ value: Any?, _ what: String) throws -> [[String: Any]] {
        try cast(value, what)
    }

    private static func object(_ value: Any?, _ what: String) throws -> [String: Any] { try cast(value, what) }

    private static func cast<T>(_ value: Any?, _ what: String) throws -> T {
        guard let value = value as? T else { throw Malformed(description: "\(what): expected \(T.self)") }
        return value
    }

    /// Second-precision UTC with a `Z` suffix (the fixture's only datetime form).
    static func date(_ value: Any?) throws -> Date {
        guard let text = value as? String, let date = try? Date(text, strategy: .iso8601) else {
            throw Malformed(description: "bad datetime \(String(describing: value))")
        }
        return date
    }

    private static func optionalDate(_ value: Any?) throws -> Date? {
        value == nil || value is NSNull ? nil : try date(value)
    }
}
