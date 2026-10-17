import Foundation

/// Server-computed statistics for one topic (`getTopicStats`). Cached; shown as stale offline.
public struct TopicStats: Sendable, Hashable {
    public var topicId: UUID
    public var entryCount: Int
    public var firstCapturedAt: Date?
    public var lastCapturedAt: Date?
    public var sources: [ValueCount]
    public var questions: [QuestionStats]

    public init(
        topicId: UUID, entryCount: Int, firstCapturedAt: Date?, lastCapturedAt: Date?, sources: [ValueCount],
        questions: [QuestionStats]
    ) {
        self.topicId = topicId
        self.entryCount = entryCount
        self.firstCapturedAt = firstCapturedAt
        self.lastCapturedAt = lastCapturedAt
        self.sources = sources
        self.questions = questions
    }
}

public struct ValueCount: Sendable, Hashable {
    public var value: String
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

/// Per-question statistics, by question type.
public enum QuestionStats: Sendable, Hashable {
    case numeric(Numeric)
    case text(Text)
    case choice(Choice)

    public var key: String {
        switch self {
        case .numeric(let stats): stats.key
        case .text(let stats): stats.key
        case .choice(let stats): stats.key
        }
    }

    /// `int` and `double` questions.
    public struct Numeric: Sendable, Hashable {
        public var key: String
        public var label: String
        public var type: QuestionType
        public var count: Int
        public var missing: Int
        public var min: Double?
        public var max: Double?
        public var mean: Double?
        public var median: Double?
        public var stddev: Double?
        public var sum: Double?
        public var histogram: [HistogramBin]

        public init(
            key: String, label: String, type: QuestionType, count: Int, missing: Int, min: Double?, max: Double?,
            mean: Double?, median: Double?, stddev: Double?, sum: Double?, histogram: [HistogramBin]
        ) {
            self.key = key
            self.label = label
            self.type = type
            self.count = count
            self.missing = missing
            self.min = min
            self.max = max
            self.mean = mean
            self.median = median
            self.stddev = stddev
            self.sum = sum
            self.histogram = histogram
        }
    }

    public struct HistogramBin: Sendable, Hashable {
        public var lower: Double
        public var upper: Double
        public var count: Int

        public init(lower: Double, upper: Double, count: Int) {
            self.lower = lower
            self.upper = upper
            self.count = count
        }
    }

    /// `str` questions.
    public struct Text: Sendable, Hashable {
        public var key: String
        public var label: String
        public var count: Int
        public var missing: Int
        public var distinct: Int
        public var top: [ValueCount]
        public var recent: [RecentText]

        public init(
            key: String, label: String, count: Int, missing: Int, distinct: Int, top: [ValueCount],
            recent: [RecentText]
        ) {
            self.key = key
            self.label = label
            self.count = count
            self.missing = missing
            self.distinct = distinct
            self.top = top
            self.recent = recent
        }
    }

    public struct RecentText: Sendable, Hashable {
        public var entryId: UUID
        public var value: String
        public var capturedAt: Date

        public init(entryId: UUID, value: String, capturedAt: Date) {
            self.entryId = entryId
            self.value = value
            self.capturedAt = capturedAt
        }
    }

    /// `enum` questions, single- or multi-select.
    public struct Choice: Sendable, Hashable {
        public var key: String
        public var label: String
        public var multiple: Bool
        public var count: Int
        public var missing: Int
        public var options: [OptionCount]

        public init(key: String, label: String, multiple: Bool, count: Int, missing: Int, options: [OptionCount]) {
            self.key = key
            self.label = label
            self.multiple = multiple
            self.count = count
            self.missing = missing
            self.options = options
        }
    }

    public struct OptionCount: Sendable, Hashable {
        public var option: EnumOption
        public var count: Int
        public var share: Double

        public init(option: EnumOption, count: Int, share: Double) {
            self.option = option
            self.count = count
            self.share = share
        }
    }
}

/// A time series for one question (`getQuestionSeries`).
public struct QuestionSeries: Sendable, Hashable {
    public var key: String
    public var type: QuestionType
    public var bucket: Bucket
    public var points: [Point]

    public init(key: String, type: QuestionType, bucket: Bucket, points: [Point]) {
        self.key = key
        self.type = type
        self.bucket = bucket
        self.points = points
    }

    public enum Bucket: String, Sendable, Hashable, CaseIterable, Codable {
        case day
        case week
        case month
    }

    public struct Point: Sendable, Hashable {
        public var start: Date
        public var count: Int
        public var mean: Double?
        public var min: Double?
        public var max: Double?
        public var optionCounts: [String: Int]

        public init(start: Date, count: Int, mean: Double?, min: Double?, max: Double?, optionCounts: [String: Int]) {
            self.start = start
            self.count = count
            self.mean = mean
            self.min = min
            self.max = max
            self.optionCounts = optionCounts
        }
    }
}
