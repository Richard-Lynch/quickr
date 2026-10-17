import QuickrCore

// Schedules come in two shapes, as in `openapi.json`: `ScheduleDTO` (`*Schedule-Output`, every
// key required) for responses and storage, `ScheduleInputDTO` (`*Schedule-Input`, defaults may be
// omitted) for request bodies.

/// A schedule in a response, tagged by `kind`.
public enum ScheduleDTO: Codable, Sendable, Hashable {
    case daily(DailyScheduleDTO)
    case interval(IntervalScheduleDTO)

    private enum TagKeys: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TagKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "daily": self = .daily(try DailyScheduleDTO(from: decoder))
        case "interval": self = .interval(try IntervalScheduleDTO(from: decoder))
        case let tag:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown schedule kind \(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var tag = encoder.container(keyedBy: TagKeys.self)
        switch self {
        case .daily(let schedule):
            try tag.encode("daily", forKey: .kind)
            try schedule.encode(to: encoder)
        case .interval(let schedule):
            try tag.encode("interval", forKey: .kind)
            try schedule.encode(to: encoder)
        }
    }
}

public struct DailyScheduleDTO: Codable, Sendable, Hashable {
    /// `HH:MM` local times.
    public var times: [String]
    /// ISO weekdays.
    public var days: [Int]
    public var timezone: String
    public var notify: Bool
}

public struct IntervalScheduleDTO: Codable, Sendable, Hashable {
    public var everyMinutes: Int
    public var timezone: String
    public var notify: Bool

    enum CodingKeys: String, CodingKey {
        case timezone, notify
        case everyMinutes = "every_minutes"
    }
}

extension ScheduleDTO: DomainConvertible {
    public func toDomain() throws -> Schedule {
        switch self {
        case .daily(let daily):
            .daily(
                .init(
                    times: try Self.times(daily.times), days: daily.days, timezone: daily.timezone,
                    notify: daily.notify))
        case .interval(let interval):
            .interval(.init(everyMinutes: interval.everyMinutes, timezone: interval.timezone, notify: interval.notify))
        }
    }

    public init(_ schedule: Schedule) {
        switch schedule {
        case .daily(let daily):
            self = .daily(
                DailyScheduleDTO(
                    times: daily.times.map(\.description), days: daily.days, timezone: daily.timezone,
                    notify: daily.notify))
        case .interval(let interval):
            self = .interval(
                IntervalScheduleDTO(
                    everyMinutes: interval.everyMinutes, timezone: interval.timezone, notify: interval.notify))
        }
    }

    static func times(_ texts: [String]) throws -> [TimeOfDay] {
        try texts.map { text in
            guard let time = TimeOfDay(text) else { throw ContractError.invalid("schedule time \(text)") }
            return time
        }
    }
}

// MARK: - Requests

/// A schedule in a request body (`TopicCreate`, `TopicUpdate`). `kind` defaults to daily.
public enum ScheduleInputDTO: Codable, Sendable, Hashable {
    case daily(DailyScheduleInputDTO)
    case interval(IntervalScheduleInputDTO)

    private enum TagKeys: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TagKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) ?? "daily" {
        case "daily": self = .daily(try DailyScheduleInputDTO(from: decoder))
        case "interval": self = .interval(try IntervalScheduleInputDTO(from: decoder))
        case let tag:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown schedule kind \(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var tag = encoder.container(keyedBy: TagKeys.self)
        switch self {
        case .daily(let schedule):
            try tag.encode("daily", forKey: .kind)
            try schedule.encode(to: encoder)
        case .interval(let schedule):
            try tag.encode("interval", forKey: .kind)
            try schedule.encode(to: encoder)
        }
    }
}

public struct DailyScheduleInputDTO: Codable, Sendable, Hashable {
    public var times: [String]
    /// Defaults to every day.
    public var days: [Int]?
    public var timezone: String
    public var notify: Bool?
}

public struct IntervalScheduleInputDTO: Codable, Sendable, Hashable {
    public var everyMinutes: Int
    public var timezone: String
    public var notify: Bool?

    enum CodingKeys: String, CodingKey {
        case timezone, notify
        case everyMinutes = "every_minutes"
    }
}

extension ScheduleInputDTO: DomainConvertible {
    public func toDomain() throws -> Schedule {
        switch self {
        case .daily(let daily):
            .daily(
                .init(
                    times: try ScheduleDTO.times(daily.times), days: daily.days ?? Schedule.Daily.everyDay,
                    timezone: daily.timezone, notify: daily.notify ?? true))
        case .interval(let interval):
            .interval(
                .init(everyMinutes: interval.everyMinutes, timezone: interval.timezone, notify: interval.notify ?? true)
            )
        }
    }

    public init(_ schedule: Schedule) {
        switch schedule {
        case .daily(let daily):
            self = .daily(
                DailyScheduleInputDTO(
                    times: daily.times.map(\.description), days: daily.days, timezone: daily.timezone,
                    notify: daily.notify))
        case .interval(let interval):
            self = .interval(
                IntervalScheduleInputDTO(
                    everyMinutes: interval.everyMinutes, timezone: interval.timezone, notify: interval.notify))
        }
    }
}
