import Foundation
import QuickrCore

// MARK: - Live Activity tokens (timers.md §10.3)

/// `kind` of a Live Activity token: the device's push-to-start token, or one activity's.
public enum LiveActivityTokenKind: String, Codable, Sendable, Hashable, CaseIterable {
    case start, update
}

/// `LiveActivityIn` (registerLiveActivity request). An upsert keyed by `token`; an `update`
/// token carries its topic and run, a `start` token neither.
public struct LiveActivityInDTO: Codable, Sendable, Hashable {
    /// Lowercase hex.
    public var token: String
    public var kind: LiveActivityTokenKind
    /// The APNs device token of this phone.
    public var deviceToken: String
    public var environment: ApnsEnvironment
    public var topicId: String?
    public var runId: String?

    enum CodingKeys: String, CodingKey {
        case token, kind, environment
        case deviceToken = "device_token"
        case topicId = "topic_id"
        case runId = "run_id"
    }

    public init(
        token: String, kind: LiveActivityTokenKind, deviceToken: String, environment: ApnsEnvironment,
        topicId: String? = nil, runId: String? = nil
    ) {
        self.token = token
        self.kind = kind
        self.deviceToken = deviceToken
        self.environment = environment
        self.topicId = topicId
        self.runId = runId
    }
}

/// `LiveActivityOut` (registerLiveActivity response).
public struct LiveActivityDTO: Codable, Sendable, Hashable, WireResponse {
    public var token: String
    public var kind: LiveActivityTokenKind
    public var deviceToken: String
    public var environment: ApnsEnvironment
    @RequiredKey public var topicId: String?
    @RequiredKey public var runId: String?
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case token, kind, environment
        case deviceToken = "device_token"
        case topicId = "topic_id"
        case runId = "run_id"
        case createdAt = "created_at"
    }

    public func toDomain() -> LiveActivityDTO { self }
}

/// `LiveActivityRef` (deleteLiveActivity request).
public struct LiveActivityRefDTO: Codable, Sendable, Hashable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}
