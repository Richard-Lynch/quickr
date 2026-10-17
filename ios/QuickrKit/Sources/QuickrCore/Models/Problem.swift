/// The error envelope of every 4xx and 5xx from `/api/v1` (the server's `Problem`).
public struct Problem: Sendable, Hashable, Error {
    public var code: ProblemCode
    public var detail: String
    public var errors: [FieldIssue]

    public init(code: ProblemCode, detail: String, errors: [FieldIssue] = []) {
        self.code = code
        self.detail = detail
        self.errors = errors
    }
}

/// One field-level problem. `location` mirrors the JSON the client sent, for example
/// `["answers", "glasses"]` or `["questions", 0, "max"]`.
public struct FieldIssue: Sendable, Hashable {
    public var location: [PathComponent]
    public var message: String

    public init(location: [PathComponent], message: String) {
        self.location = location
        self.message = message
    }

    public enum PathComponent: Sendable, Hashable {
        case key(String)
        case index(Int)
    }
}

/// `Problem.code`. Every code the server sends (`backend/app/errors.py`, `main.py`,
/// `api/identity.py`); anything else decodes as `.unknown` so a newer server never breaks parsing.
public enum ProblemCode: Sendable, Hashable, RawRepresentable {
    case badRequest
    case notFound
    case conflict
    case invalidRequest
    case invalidAnswers
    case incompatibleVersion
    case topicArchived
    /// The entry id was deleted or reserved by a delete, and can never be created (§6a rule 2).
    case entryDeleted
    /// `expected_revision` didn't match (§6a rule 6).
    case staleRevision
    /// `X-QuickR-Expect-Server-Id` didn't match; nothing executed (F10).
    case serverMismatch
    /// `X-QuickR-Expect-Epoch` didn't match; nothing executed (F10).
    case epochMismatch
    case internalError
    case unknown(String)

    public static let known: [ProblemCode] = [
        .badRequest, .notFound, .conflict, .invalidRequest, .invalidAnswers, .incompatibleVersion, .topicArchived,
        .entryDeleted, .staleRevision, .serverMismatch, .epochMismatch, .internalError,
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .badRequest: "bad_request"
        case .notFound: "not_found"
        case .conflict: "conflict"
        case .invalidRequest: "invalid_request"
        case .invalidAnswers: "invalid_answers"
        case .incompatibleVersion: "incompatible_version"
        case .topicArchived: "topic_archived"
        case .entryDeleted: "entry_deleted"
        case .staleRevision: "stale_revision"
        case .serverMismatch: "server_mismatch"
        case .epochMismatch: "epoch_mismatch"
        case .internalError: "internal_error"
        case .unknown(let raw): raw
        }
    }
}
