import Foundation
import QuickrCore

/// One answer value in a request's `answers` map: a number, a string or a list of strings.
public struct WireAnswer: Codable, Sendable, Hashable {
    public var value: AnswerValue

    public init(_ value: AnswerValue) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            value = .double(double)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else {
            value = .strings(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .int(let int): try container.encode(int)
        case .double(let double): try container.encode(double)
        case .string(let string): try container.encode(string)
        case .strings(let strings): try container.encode(strings)
        }
    }
}

/// One answer of an `EntryOut`, tagged by `type` (`int`, `double`, `str`, `enum`, `enum_list`).
public struct AnswerDTO: Codable, Sendable, Hashable {
    public var key: String
    public var type: String
    public var value: AnswerValue

    enum CodingKeys: String, CodingKey { case key, type, value }

    public init(key: String, type: String, value: AnswerValue) {
        self.key = key
        self.type = type
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(String.self, forKey: .type)
        switch type {
        case "int": value = .int(try container.decode(Int.self, forKey: .value))
        case "double": value = .double(try container.decode(Double.self, forKey: .value))
        case "str", "enum": value = .string(try container.decode(String.self, forKey: .value))
        case "enum_list": value = .strings(try container.decode([String].self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown answer type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(type, forKey: .type)
        try container.encode(WireAnswer(value), forKey: .value)
    }
}

/// `EntryOut`: the response of getEntry, createEntry and updateEntry, an item of listEntries, and
/// the record in a feed `entry` item.
public struct EntryDTO: Codable, Sendable, Hashable, WireResponse {
    public var id: String
    public var topicId: String
    public var version: Int
    public var revision: Int
    public var source: String
    public var channel: Channel
    public var capturedAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var notes: String
    public var meta: [String: String]
    public var answers: [AnswerDTO]
    /// A finished run's times; `nil` for an untimed entry (timers.md §2.3).
    @RequiredKey public var timing: TimingDTO?

    enum CodingKeys: String, CodingKey {
        case id, version, revision, source, channel, notes, meta, answers, timing
        case topicId = "topic_id"
        case capturedAt = "captured_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func toDomain() throws -> Entry {
        var byKey: [String: AnswerValue] = [:]
        for answer in answers {
            guard byKey.updateValue(answer.value, forKey: answer.key) == nil else {
                throw ContractError.invalid("entry \(id) answers \(answer.key) twice")
            }
        }
        return Entry(
            id: try .wire(id, "entry.id"), topicId: try .wire(topicId, "entry.topic_id"), version: version,
            revision: revision, source: source, channel: channel, capturedAt: capturedAt, createdAt: createdAt,
            updatedAt: updatedAt, notes: notes, meta: meta, answers: byKey, timing: try timing?.toDomain())
    }
}

// MARK: - Requests

/// `EntryCreate` (createEntry). iOS always sets `id`, `version` and `captured_at`
/// (outbox.md §1).
public struct EntryCreateDTO: Codable, Sendable, Hashable {
    public var id: String?
    /// A `null` value is accepted by the server and treated as unanswered.
    public var answers: [String: WireAnswer?]
    public var source: String?
    public var capturedAt: Date?
    public var notes: String?
    public var meta: [String: String]?
    public var version: Int?

    enum CodingKeys: String, CodingKey {
        case id, answers, source, notes, meta, version
        case capturedAt = "captured_at"
    }

    public init(
        id: UUID?, answers: [String: AnswerValue], source: String?, capturedAt: Date?, notes: String? = nil,
        meta: [String: String]? = nil, version: Int?
    ) {
        self.id = id?.wireString
        self.answers = answers.mapValues { WireAnswer($0) }
        self.source = source
        self.capturedAt = capturedAt
        self.notes = notes
        self.meta = meta
        self.version = version
    }

    /// The answers as domain values, typed by `questions` (the version the entry is pinned to).
    /// Use this, not `answers[k]?.value`, when rebuilding answers from a stored payload.
    public func domainAnswers(for questions: [Question]) -> [String: AnswerValue] {
        answers.compactMapValues { $0?.value }.normalized(for: questions)
    }
}

/// `EntryUpdate` (updateEntry). Only changed keys are sent; in `answers`, a `null` removes the
/// key (sync-protocol.md §3.2).
public struct EntryUpdateDTO: Codable, Sendable, Hashable {
    public var answers: [String: WireAnswer?]?
    public var source: String?
    public var capturedAt: Date?
    public var notes: String?
    public var meta: [String: String]?
    public var expectedRevision: Int?

    enum CodingKeys: String, CodingKey {
        case answers, source, notes, meta
        case capturedAt = "captured_at"
        case expectedRevision = "expected_revision"
    }

    public init(
        answers: [String: AnswerValue?]? = nil, source: String? = nil, capturedAt: Date? = nil, notes: String? = nil,
        meta: [String: String]? = nil, expectedRevision: Int? = nil
    ) {
        self.answers = answers?.mapValues { $0.map(WireAnswer.init) }
        self.source = source
        self.capturedAt = capturedAt
        self.notes = notes
        self.meta = meta
        self.expectedRevision = expectedRevision
    }

    /// The answer patch as domain values, typed by `questions`; a `nil` value removes the key.
    public func domainAnswers(for questions: [Question]) -> [String: AnswerValue?]? {
        guard let answers else { return nil }
        let byKey = Dictionary(questions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return answers.reduce(into: [:]) { result, answer in
            let value = answer.value?.value
            result[answer.key] = .some(value.map { value in byKey[answer.key].map(value.normalized(for:)) ?? value })
        }
    }
}
