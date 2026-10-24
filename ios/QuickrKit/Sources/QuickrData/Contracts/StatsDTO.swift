import Foundation
import QuickrCore

/// `TopicStats` (getTopicStats).
public struct TopicStatsDTO: Codable, Sendable, Hashable, WireResponse {
    public var topicId: String
    public var entryCount: Int
    @RequiredKey public var firstCapturedAt: Date?
    @RequiredKey public var lastCapturedAt: Date?
    public var sources: [ValueCountDTO]
    public var questions: [QuestionStatsDTO]

    enum CodingKeys: String, CodingKey {
        case sources, questions
        case topicId = "topic_id"
        case entryCount = "entry_count"
        case firstCapturedAt = "first_captured_at"
        case lastCapturedAt = "last_captured_at"
    }

    public func toDomain() throws -> TopicStats {
        TopicStats(
            topicId: try .wire(topicId, "stats.topic_id"), entryCount: entryCount, firstCapturedAt: firstCapturedAt,
            lastCapturedAt: lastCapturedAt, sources: try sources.toDomain(), questions: try questions.toDomain())
    }
}

public struct ValueCountDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var value: String
    public var count: Int

    public func toDomain() -> ValueCount { ValueCount(value: value, count: count) }
}

/// Per-question stats, tagged by `type`: `int` and `double` are numeric, `str` text, `enum` choice.
public enum QuestionStatsDTO: Codable, Sendable, Hashable, DomainConvertible {
    case numeric(NumericStatsDTO)
    case text(StrStatsDTO)
    case choice(EnumStatsDTO)

    private enum TagKeys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TagKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "int", "double": self = .numeric(try NumericStatsDTO(from: decoder))
        case "str": self = .text(try StrStatsDTO(from: decoder))
        case "enum": self = .choice(try EnumStatsDTO(from: decoder))
        case let tag:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown stats type \(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .numeric(let stats): try stats.encode(to: encoder)
        case .text(let stats): try stats.encode(to: encoder)
        case .choice(let stats): try stats.encode(to: encoder)
        }
    }

    public func toDomain() throws -> QuestionStats {
        switch self {
        case .numeric(let s):
            guard let type = QuestionType(rawValue: s.type), type == .int || type == .double else {
                throw ContractError.invalid("numeric stats of type \(s.type)")
            }
            return .numeric(
                .init(
                    key: s.key, label: s.label, type: type, count: s.count, missing: s.missing, min: s.min, max: s.max,
                    mean: s.mean, median: s.median, stddev: s.stddev, sum: s.sum,
                    histogram: s.histogram.map { .init(lower: $0.lower, upper: $0.upper, count: $0.count) }))
        case .text(let s):
            return .text(
                .init(
                    key: s.key, label: s.label, count: s.count, missing: s.missing, distinct: s.distinct,
                    top: try s.top.toDomain(),
                    recent: try s.recent.map {
                        .init(
                            entryId: try .wire($0.entryId, "recent.entry_id"), value: $0.value,
                            capturedAt: $0.capturedAt)
                    }))
        case .choice(let s):
            return .choice(
                .init(
                    key: s.key, label: s.label, multiple: s.multiple, count: s.count, missing: s.missing,
                    options: s.options.map {
                        .init(
                            option: EnumOption(value: $0.value, label: $0.label, archived: $0.archived),
                            count: $0.count, share: $0.share)
                    }))
        }
    }
}

public struct NumericStatsDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var type: String
    public var count: Int
    public var missing: Int
    @RequiredKey public var min: Double?
    @RequiredKey public var max: Double?
    @RequiredKey public var mean: Double?
    @RequiredKey public var median: Double?
    @RequiredKey public var stddev: Double?
    @RequiredKey public var sum: Double?
    public var histogram: [HistogramBinDTO]
}

public struct HistogramBinDTO: Codable, Sendable, Hashable {
    public var lower: Double
    public var upper: Double
    public var count: Int
}

public struct StrStatsDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var type: String
    public var count: Int
    public var missing: Int
    public var distinct: Int
    public var top: [ValueCountDTO]
    public var recent: [RecentTextDTO]
}

public struct RecentTextDTO: Codable, Sendable, Hashable {
    public var entryId: String
    public var value: String
    public var capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case value
        case entryId = "entry_id"
        case capturedAt = "captured_at"
    }
}

public struct EnumStatsDTO: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var type: String
    public var multiple: Bool
    public var count: Int
    public var missing: Int
    public var options: [EnumOptionCountDTO]
}

public struct EnumOptionCountDTO: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var archived: Bool
    public var count: Int
    public var share: Double
}

/// `QuestionSeries` (getQuestionSeries).
public struct QuestionSeriesDTO: Codable, Sendable, Hashable, WireResponse {
    public var key: String
    public var type: QuestionType
    public var bucket: QuestionSeries.Bucket
    public var points: [Point]

    public struct Point: Codable, Sendable, Hashable {
        public var start: Date
        public var count: Int
        @RequiredKey public var mean: Double?
        @RequiredKey public var min: Double?
        @RequiredKey public var max: Double?
        public var optionCounts: [String: Int]

        enum CodingKeys: String, CodingKey {
            case start, count, mean, min, max
            case optionCounts = "option_counts"
        }
    }

    public func toDomain() -> QuestionSeries {
        QuestionSeries(
            key: key, type: type, bucket: bucket,
            points: points.map {
                .init(
                    start: $0.start, count: $0.count, mean: $0.mean, min: $0.min, max: $0.max,
                    optionCounts: $0.optionCounts)
            })
    }
}

/// `TopicTiming` (getTopicTiming, timers.md §9.2). Durations are integer milliseconds; the
/// timing chart models (I-CORE) read it as it is.
public struct TopicTimingDTO: Codable, Sendable, Hashable, WireResponse {
    /// `TimingSummary`, and the median and mean of `TimingLaps`.
    public struct Summary: Codable, Sendable, Hashable {
        @RequiredKey public var bestMs: Int?
        @RequiredKey public var medianMs: Int?
        @RequiredKey public var meanMs: Int?

        enum CodingKeys: String, CodingKey {
            case bestMs = "best_ms"
            case medianMs = "median_ms"
            case meanMs = "mean_ms"
        }
    }

    /// `TimingStepStats`.
    public struct StepStats: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var current: Bool
        public var done: Int
        public var skipped: Int
        @RequiredKey public var bestMs: Int?
        @RequiredKey public var medianMs: Int?
        @RequiredKey public var meanMs: Int?

        enum CodingKeys: String, CodingKey {
            case key, label, current, done, skipped
            case bestMs = "best_ms"
            case medianMs = "median_ms"
            case meanMs = "mean_ms"
        }
    }

    /// `TimingLaps`.
    public struct Laps: Codable, Sendable, Hashable {
        public var runsWithLaps: Int
        @RequiredKey public var medianMs: Int?
        @RequiredKey public var meanMs: Int?

        enum CodingKeys: String, CodingKey {
            case runsWithLaps = "runs_with_laps"
            case medianMs = "median_ms"
            case meanMs = "mean_ms"
        }
    }

    /// `TimingPaused`.
    public struct Paused: Codable, Sendable, Hashable {
        public var runsWithPauses: Int
        @RequiredKey public var medianMs: Int?

        enum CodingKeys: String, CodingKey {
            case runsWithPauses = "runs_with_pauses"
            case medianMs = "median_ms"
        }
    }

    /// `TimingSeriesPoint`. Instants stay wire strings, as in `TimingDTO`.
    public struct Point: Codable, Sendable, Hashable {
        public var entryId: String
        public var capturedAt: String
        public var startedAt: String
        public var activeMs: Int
        public var pausedMs: Int
        public var complete: Bool
        public var steps: [String: Int]

        enum CodingKeys: String, CodingKey {
            case complete, steps
            case entryId = "entry_id"
            case capturedAt = "captured_at"
            case startedAt = "started_at"
            case activeMs = "active_ms"
            case pausedMs = "paused_ms"
        }
    }

    public var runs: Int
    public var completeRuns: Int
    public var total: Summary
    public var steps: [StepStats]
    public var laps: Laps
    public var paused: Paused
    public var series: [Point]

    enum CodingKeys: String, CodingKey {
        case runs, total, steps, laps, paused, series
        case completeRuns = "complete_runs"
    }

    public func toDomain() -> TopicTimingDTO { self }
}
