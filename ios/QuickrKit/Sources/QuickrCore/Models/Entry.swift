import Foundation

/// One answer value. The wire distinguishes `enum` from `str` and `enum_list` from nothing else;
/// the question says which one a value is, so the domain keeps only the shape.
public enum AnswerValue: Sendable, Hashable {
    case int(Int)
    case double(Double)
    /// A `str` answer or a single-select `enum` answer.
    case string(String)
    /// A multi-select `enum` answer (`enum_list` on the wire).
    case strings([String])
}

/// One logged entry (the server's `EntryOut`).
public struct Entry: Sendable, Hashable, Identifiable {
    /// Client-generated for creates from iOS, so a create is idempotent.
    public var id: UUID
    public var topicId: UUID
    /// The topic version the answers were validated against.
    public var version: Int
    /// Starts at 1 and increases with every change to the entry (F4).
    public var revision: Int
    /// Free-form origin, for example `ios`, `ios.widget` or `api`.
    public var source: String
    public var channel: Channel
    public var capturedAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var notes: String
    public var meta: [String: String]
    /// Answers by question key. Unanswered optional questions are absent.
    public var answers: [String: AnswerValue]

    public init(
        id: UUID, topicId: UUID, version: Int, revision: Int, source: String, channel: Channel, capturedAt: Date,
        createdAt: Date, updatedAt: Date, notes: String = "", meta: [String: String] = [:],
        answers: [String: AnswerValue]
    ) {
        self.id = id
        self.topicId = topicId
        self.version = version
        self.revision = revision
        self.source = source
        self.channel = channel
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
        self.meta = meta
        self.answers = answers
    }
}
