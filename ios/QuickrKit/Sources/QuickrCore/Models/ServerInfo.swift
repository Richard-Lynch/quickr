import Foundation

/// The server's input limits (`getLimits`), mirrored by client-side validation.
public struct Limits: Sendable, Hashable {
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

    public init(
        keyPattern: String, slugPattern: String, timePattern: String, maxQuestions: Int, maxEnumOptions: Int,
        maxStrLength: Int, maxLabelLength: Int, maxHelpTextLength: Int, maxUnitLength: Int, maxDecimals: Int,
        maxTopicNameLength: Int, maxDescriptionLength: Int, maxChangeNoteLength: Int, maxSourceLength: Int,
        maxNotesLength: Int, maxMetaEntries: Int, maxMetaKeyLength: Int, maxMetaValueLength: Int,
        capturedAtMin: Date, capturedAtMaxFutureHours: Int, scheduleMaxTimes: Int, intervalMinMinutes: Int,
        intervalMaxMinutes: Int
    ) {
        self.keyPattern = keyPattern
        self.slugPattern = slugPattern
        self.timePattern = timePattern
        self.maxQuestions = maxQuestions
        self.maxEnumOptions = maxEnumOptions
        self.maxStrLength = maxStrLength
        self.maxLabelLength = maxLabelLength
        self.maxHelpTextLength = maxHelpTextLength
        self.maxUnitLength = maxUnitLength
        self.maxDecimals = maxDecimals
        self.maxTopicNameLength = maxTopicNameLength
        self.maxDescriptionLength = maxDescriptionLength
        self.maxChangeNoteLength = maxChangeNoteLength
        self.maxSourceLength = maxSourceLength
        self.maxNotesLength = maxNotesLength
        self.maxMetaEntries = maxMetaEntries
        self.maxMetaKeyLength = maxMetaKeyLength
        self.maxMetaValueLength = maxMetaValueLength
        self.capturedAtMin = capturedAtMin
        self.capturedAtMaxFutureHours = capturedAtMaxFutureHours
        self.scheduleMaxTimes = scheduleMaxTimes
        self.intervalMinMinutes = intervalMinMinutes
        self.intervalMaxMinutes = intervalMaxMinutes
    }
}

/// One question type and its JSON Schema (`listQuestionTypes`).
public struct QuestionTypeInfo: Sendable, Hashable {
    public var type: QuestionType
    public var description: String
    public var jsonSchema: [String: JSONValue]

    public init(type: QuestionType, description: String, jsonSchema: [String: JSONValue]) {
        self.type = type
        self.description = description
        self.jsonSchema = jsonSchema
    }
}

/// The result of checking a draft question set against the current version (`checkTopicVersion`).
public struct CompatibilityReport: Sendable, Hashable {
    public var ok: Bool
    public var nextVersion: Int
    public var issues: [Issue]
    public var changes: [Change]

    public init(ok: Bool, nextVersion: Int, issues: [Issue], changes: [Change]) {
        self.ok = ok
        self.nextVersion = nextVersion
        self.issues = issues
        self.changes = changes
    }

    public struct Issue: Sendable, Hashable {
        public var level: Level
        public var questionKey: String?
        public var message: String

        public init(level: Level, questionKey: String?, message: String) {
            self.level = level
            self.questionKey = questionKey
            self.message = message
        }
    }

    public enum Level: String, Sendable, Hashable, CaseIterable, Codable {
        case error
        case warning
        case info
    }

    public struct Change: Sendable, Hashable {
        public var kind: ChangeKind
        public var questionKey: String
        public var details: [String]

        public init(kind: ChangeKind, questionKey: String, details: [String]) {
            self.kind = kind
            self.questionKey = questionKey
            self.details = details
        }
    }

    public enum ChangeKind: String, Sendable, Hashable, CaseIterable, Codable {
        case added
        case removed
        case modified
        case restored
        case reordered
    }
}

/// Push configuration (`getPushConfig`): the Web Push key, and whether the server can send APNs.
public struct PushConfig: Sendable, Hashable {
    public var publicKey: String
    public var apnsEnabled: Bool

    public init(publicKey: String, apnsEnabled: Bool = false) {
        self.publicKey = publicKey
        self.apnsEnabled = apnsEnabled
    }
}

/// The server's API level, the lowest client level it accepts per platform, and where the iOS
/// app updates (`getClientVersions`, client-versions.md §3.2).
public struct ClientVersions: Sendable, Hashable {
    public var apiLevel: Int
    public var minClientLevelIOS: Int
    public var minClientLevelWeb: Int
    public var iosUpdateURL: String

    public init(apiLevel: Int, minClientLevelIOS: Int, minClientLevelWeb: Int, iosUpdateURL: String) {
        self.apiLevel = apiLevel
        self.minClientLevelIOS = minClientLevelIOS
        self.minClientLevelWeb = minClientLevelWeb
        self.iosUpdateURL = iosUpdateURL
    }
}

/// The APNs environment a device token belongs to (notifications.md §9.1).
public enum ApnsEnvironment: String, Sendable, Hashable, CaseIterable, Codable {
    case sandbox
    case production
}

/// A device registered for APNs reminders (`registerApnsDevice`).
public struct ApnsDevice: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Lowercase hex.
    public var token: String
    public var environment: ApnsEnvironment
    public var bundleId: String?
    public var appVersion: String?
    public var deviceName: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID, token: String, environment: ApnsEnvironment, bundleId: String? = nil, appVersion: String? = nil,
        deviceName: String? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.token = token
        self.environment = environment
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A stored Web Push subscription (`createPushSubscription`).
public struct PushSubscription: Sendable, Hashable {
    public var id: UUID
    public var endpoint: String
    public var createdAt: Date

    public init(id: UUID, endpoint: String, createdAt: Date) {
        self.id = id
        self.endpoint = endpoint
        self.createdAt = createdAt
    }
}

/// The outcome of a test push (`sendTestPush`).
public struct PushTestResult: Sendable, Hashable {
    public var sent: Int
    public var failed: Int

    public init(sent: Int, failed: Int) {
        self.sent = sent
        self.failed = failed
    }
}

/// `GET /health`, for example `{"status": "ok"}`.
public struct Health: Sendable, Hashable {
    public var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public var isOK: Bool { values["status"] == "ok" }
}

extension Limits {
    /// The server's defaults (`GET /limits`, `shared/fixtures/api/getLimits.json`), for checks made
    /// before any limits are fetched; the server enforces its own anyway. A test keeps them in
    /// step with the fixture.
    public static let serverDefaults = Limits(
        keyPattern: "^[a-z][a-z0-9_]{0,62}$", slugPattern: "^[a-z0-9][a-z0-9-]{0,63}$",
        timePattern: "^([01][0-9]|2[0-3]):[0-5][0-9]$", maxQuestions: 100, maxEnumOptions: 200, maxStrLength: 10_000,
        maxLabelLength: 200, maxHelpTextLength: 1000, maxUnitLength: 32, maxDecimals: 10, maxTopicNameLength: 200,
        maxDescriptionLength: 5000, maxChangeNoteLength: 2000, maxSourceLength: 100, maxNotesLength: 5000,
        maxMetaEntries: 50, maxMetaKeyLength: 64, maxMetaValueLength: 500,
        capturedAtMin: Date(timeIntervalSince1970: 946_684_800),  // 2000-01-01T00:00:00Z
        capturedAtMaxFutureHours: 24, scheduleMaxTimes: 24, intervalMinMinutes: 15, intervalMaxMinutes: 129_600)
}
