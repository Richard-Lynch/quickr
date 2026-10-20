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
