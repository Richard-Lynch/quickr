import Foundation
import QuickrCore

/// `GET /health`: a flat string map.
public struct HealthDTO: Codable, Sendable, Hashable, WireResponse {
    public var values: [String: String]

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public func toDomain() -> Health { Health(values: values) }
}

/// `Limits` (getLimits).
public struct LimitsDTO: Codable, Sendable, Hashable, WireResponse {
    public var keyPattern: String
    public var slugPattern: String
    public var timePattern: String
    public var maxQuestions: Int
    public var maxEnumOptions: Int
    public var maxStrLength: Int
    public var maxLabelLength: Int
    public var maxHelpTextLength: Int
    public var maxUnitLength: Int
    public var maxDecimals: Int
    public var maxTopicNameLength: Int
    public var maxDescriptionLength: Int
    public var maxChangeNoteLength: Int
    public var maxSourceLength: Int
    public var maxNotesLength: Int
    public var maxMetaEntries: Int
    public var maxMetaKeyLength: Int
    public var maxMetaValueLength: Int
    public var capturedAtMin: Date
    public var capturedAtMaxFutureHours: Int
    public var scheduleMaxTimes: Int
    public var intervalMinMinutes: Int
    public var intervalMaxMinutes: Int

    enum CodingKeys: String, CodingKey {
        case keyPattern = "key_pattern"
        case slugPattern = "slug_pattern"
        case timePattern = "time_pattern"
        case maxQuestions = "max_questions"
        case maxEnumOptions = "max_enum_options"
        case maxStrLength = "max_str_length"
        case maxLabelLength = "max_label_length"
        case maxHelpTextLength = "max_help_text_length"
        case maxUnitLength = "max_unit_length"
        case maxDecimals = "max_decimals"
        case maxTopicNameLength = "max_topic_name_length"
        case maxDescriptionLength = "max_description_length"
        case maxChangeNoteLength = "max_change_note_length"
        case maxSourceLength = "max_source_length"
        case maxNotesLength = "max_notes_length"
        case maxMetaEntries = "max_meta_entries"
        case maxMetaKeyLength = "max_meta_key_length"
        case maxMetaValueLength = "max_meta_value_length"
        case capturedAtMin = "captured_at_min"
        case capturedAtMaxFutureHours = "captured_at_max_future_hours"
        case scheduleMaxTimes = "schedule_max_times"
        case intervalMinMinutes = "interval_min_minutes"
        case intervalMaxMinutes = "interval_max_minutes"
    }

    public func toDomain() -> Limits {
        Limits(
            keyPattern: keyPattern, slugPattern: slugPattern, timePattern: timePattern, maxQuestions: maxQuestions,
            maxEnumOptions: maxEnumOptions, maxStrLength: maxStrLength, maxLabelLength: maxLabelLength,
            maxHelpTextLength: maxHelpTextLength, maxUnitLength: maxUnitLength, maxDecimals: maxDecimals,
            maxTopicNameLength: maxTopicNameLength, maxDescriptionLength: maxDescriptionLength,
            maxChangeNoteLength: maxChangeNoteLength, maxSourceLength: maxSourceLength, maxNotesLength: maxNotesLength,
            maxMetaEntries: maxMetaEntries, maxMetaKeyLength: maxMetaKeyLength,
            maxMetaValueLength: maxMetaValueLength, capturedAtMin: capturedAtMin,
            capturedAtMaxFutureHours: capturedAtMaxFutureHours, scheduleMaxTimes: scheduleMaxTimes,
            intervalMinMinutes: intervalMinMinutes, intervalMaxMinutes: intervalMaxMinutes)
    }
}

/// `QuestionTypeInfo` (listQuestionTypes).
public struct QuestionTypeInfoDTO: Codable, Sendable, Hashable, DomainConvertible {
    public var type: QuestionType
    public var description: String
    public var jsonSchema: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case type, description
        case jsonSchema = "json_schema"
    }

    public func toDomain() -> QuestionTypeInfo {
        QuestionTypeInfo(type: type, description: description, jsonSchema: jsonSchema)
    }
}

/// `Problem`: the body of every error response.
public struct ProblemDTO: Codable, Sendable, Hashable, WireResponse {
    public var code: String
    public var detail: String
    public var errors: [FieldIssueDTO]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        detail = try container.decode(String.self, forKey: .detail)
        errors = try container.decode([FieldIssueDTO].self, forKey: .errors)
    }

    public func toDomain() -> Problem {
        Problem(
            code: ProblemCode(rawValue: code), detail: detail,
            errors: errors.map { FieldIssue(location: $0.loc.map(\.component), message: $0.message) })
    }
}

public struct FieldIssueDTO: Codable, Sendable, Hashable {
    public var loc: [LocationDTO]
    public var message: String

    /// One `loc` segment: a key or an array index.
    public struct LocationDTO: Codable, Sendable, Hashable {
        public var component: FieldIssue.PathComponent

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) {
                component = .index(index)
            } else {
                component = .key(try container.decode(String.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch component {
            case .key(let key): try container.encode(key)
            case .index(let index): try container.encode(index)
            }
        }
    }
}

// MARK: - Web Push

/// `PushConfig` (getPushConfig).
public struct PushConfigDTO: Codable, Sendable, Hashable, WireResponse {
    public var publicKey: String
    public var apnsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case apnsEnabled = "apns_enabled"
    }

    public func toDomain() -> PushConfig { PushConfig(publicKey: publicKey, apnsEnabled: apnsEnabled) }
}

/// `PushSubscriptionOut` (createPushSubscription).
public struct PushSubscriptionDTO: Codable, Sendable, Hashable, WireResponse {
    public var id: String
    public var endpoint: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, endpoint
        case createdAt = "created_at"
    }

    public func toDomain() throws -> PushSubscription {
        PushSubscription(id: try .wire(id, "subscription.id"), endpoint: endpoint, createdAt: createdAt)
    }
}

/// `PushTestResult` (sendTestPush).
public struct PushTestResultDTO: Codable, Sendable, Hashable, WireResponse {
    public var sent: Int
    public var failed: Int

    public func toDomain() -> PushTestResult { PushTestResult(sent: sent, failed: failed) }
}

/// `PushSubscriptionIn` (createPushSubscription request).
public struct PushSubscriptionInDTO: Codable, Sendable, Hashable {
    public var endpoint: String
    public var keys: Keys
    public var userAgent: String?

    public struct Keys: Codable, Sendable, Hashable {
        public var p256dh: String
        public var auth: String
    }

    enum CodingKeys: String, CodingKey {
        case endpoint, keys
        case userAgent = "user_agent"
    }
}

/// `PushSubscriptionDelete` (deletePushSubscription request).
public struct PushSubscriptionDeleteDTO: Codable, Sendable, Hashable {
    public var endpoint: String
}

// MARK: - APNs (B6; notifications.md §9.2)

/// `ApnsDeviceIn` (registerApnsDevice request). An upsert keyed by `token`.
public struct ApnsDeviceInDTO: Codable, Sendable, Hashable {
    /// Lowercase hex.
    public var token: String
    public var environment: ApnsEnvironment
    public var bundleId: String?
    public var appVersion: String?
    public var deviceName: String?

    enum CodingKeys: String, CodingKey {
        case token, environment
        case bundleId = "bundle_id"
        case appVersion = "app_version"
        case deviceName = "device_name"
    }

    public init(
        token: String, environment: ApnsEnvironment, bundleId: String? = nil, appVersion: String? = nil,
        deviceName: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.deviceName = deviceName
    }
}

/// `ApnsDeviceOut` (registerApnsDevice response).
public struct ApnsDeviceDTO: Codable, Sendable, Hashable, WireResponse {
    public var id: String
    public var token: String
    public var environment: ApnsEnvironment
    @RequiredKey public var bundleId: String?
    @RequiredKey public var appVersion: String?
    @RequiredKey public var deviceName: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, token, environment
        case bundleId = "bundle_id"
        case appVersion = "app_version"
        case deviceName = "device_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func toDomain() throws -> ApnsDevice {
        ApnsDevice(
            id: try .wire(id, "apns_device.id"), token: token, environment: environment, bundleId: bundleId,
            appVersion: appVersion, deviceName: deviceName, createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// `ApnsDeviceRef` (deleteApnsDevice and sendApnsTestPush requests).
public struct ApnsDeviceRefDTO: Codable, Sendable, Hashable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}
