import Foundation

/// The parts of `UNUserNotificationCenter` that quickR uses, in value types so fakes and tests
/// don't touch UserNotifications (notifications.md §5–§11). The production adapter lands in M3.
///
/// No method may be called inside a SQLite transaction except `setNotificationCategories`, which
/// is synchronous by design (notifications.md §5.2).
public protocol NotificationCenterProtocol: Sendable {
    /// Replaces the app's whole category set.
    func setNotificationCategories(_ categories: [NotificationCategorySpec])
    func notificationCategories() async -> [NotificationCategorySpec]

    func deliveredNotifications() async -> [NotificationSnapshot]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])

    func pendingNotificationRequests() async -> [NotificationSnapshot]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    /// Schedules a local notification (the future local fallback, notifications.md §11).
    func add(_ request: LocalNotificationRequest) async throws

    func setBadgeCount(_ count: Int) async throws
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async throws -> Bool
}

public enum NotificationAuthorization: String, Sendable, Hashable, CaseIterable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    /// The statuses under which quickR registers for remote notifications (notifications.md §9.2).
    public var allowsDelivery: Bool { self == .authorized || self == .provisional || self == .ephemeral }
}

/// A `UNNotificationCategory`, as quickR builds it (notifications.md §4).
public struct NotificationCategorySpec: Sendable, Hashable, Identifiable {
    /// `quickr.t.{topic_id}.{hash}`
    public var id: String
    public var actions: [NotificationActionSpec]

    public init(id: String, actions: [NotificationActionSpec]) {
        self.id = id
        self.actions = actions
    }
}

public struct NotificationActionSpec: Sendable, Hashable, Identifiable {
    /// `q1|{server_id}|{topic_id}|{version}|{key}|{k}|{value}` (notifications.md §4.2)
    public var id: String
    public var title: String
    public var kind: Kind
    public var requiresAuthentication: Bool

    public init(id: String, title: String, kind: Kind, requiresAuthentication: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.requiresAuthentication = requiresAuthentication
    }

    public enum Kind: Sendable, Hashable {
        /// Logs a fixed answer (`UNNotificationAction`, no options: it runs in the background).
        case log
        /// Asks for a number (`UNTextInputNotificationAction`).
        case input(buttonTitle: String, placeholder: String)
        /// "More…": opens the record screen (`UNNotificationAction` with `.foreground`, §4.1).
        case open

        /// Whether the action opens the app (`UNNotificationActionOptions.foreground`).
        public var opensApp: Bool { self == .open }
    }
}

/// A delivered notification or a pending request, reduced to what quickR reads.
public struct NotificationSnapshot: Sendable, Hashable, Identifiable {
    public var id: String
    public var categoryIdentifier: String
    public var threadIdentifier: String
    public var date: Date?
    /// `userInfo.quickr`, or nil when the notification isn't quickR's.
    public var quickr: QuickrNotificationInfo?

    public init(
        id: String, categoryIdentifier: String = "", threadIdentifier: String = "", date: Date? = nil,
        quickr: QuickrNotificationInfo? = nil
    ) {
        self.id = id
        self.categoryIdentifier = categoryIdentifier
        self.threadIdentifier = threadIdentifier
        self.date = date
        self.quickr = quickr
    }
}

/// The `quickr` object of a payload (notifications.md §2.1, §11.1). Clients ignore unknown keys.
/// Codable with the payload's snake_case keys, so the adapter can read it from `userInfo` and
/// write it back for local requests unchanged.
public struct QuickrNotificationInfo: Codable, Sendable, Hashable {
    public var v: Int
    /// `due`, `test`, `sync` or `fix`
    public var kind: String
    /// Remote (APNs) unless the payload says `"origin": "local"` (the local fallback, §11.1).
    public var origin: Origin
    public var serverId: String
    public var topicId: String?
    public var topicSlug: String?
    /// The topic's `current_version` when the reminder was built; actions log against it.
    public var version: Int?
    /// Canonical slot: UTC, whole seconds, `Z` (notifications.md §11.1).
    public var dueSince: String?
    /// `/t/{slug}/record`
    public var url: String?
    /// What the actions log; the handler validates every action against it (§7.1 step 1).
    public var quickLog: QuickLogDescriptor?
    /// A tap-to-fix notification's raw text per question key, for the record screen (§7.3).
    public var prefill: [String: String]?

    public enum Origin: String, Codable, Sendable, Hashable {
        case remote
        case local
    }

    enum CodingKeys: String, CodingKey {
        case v, kind, origin, version, url
        case serverId = "server_id"
        case topicId = "topic_id"
        case topicSlug = "topic_slug"
        case dueSince = "due_since"
        case quickLog = "quick_log"
        case prefill
    }

    public init(
        v: Int = 1, kind: String, origin: Origin = .remote, serverId: String, topicId: String? = nil,
        topicSlug: String? = nil, version: Int? = nil, dueSince: String? = nil, url: String? = nil,
        quickLog: QuickLogDescriptor? = nil, prefill: [String: String]? = nil
    ) {
        self.v = v
        self.kind = kind
        self.origin = origin
        self.serverId = serverId
        self.topicId = topicId
        self.topicSlug = topicSlug
        self.version = version
        self.dueSince = dueSince
        self.url = url
        self.quickLog = quickLog
        self.prefill = prefill
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        kind = try container.decode(String.self, forKey: .kind)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .remote
        serverId = try container.decode(String.self, forKey: .serverId)
        topicId = try container.decodeIfPresent(String.self, forKey: .topicId)
        topicSlug = try container.decodeIfPresent(String.self, forKey: .topicSlug)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        dueSince = try container.decodeIfPresent(String.self, forKey: .dueSince)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        // A quick_log type this build doesn't know (a newer server's) is a plain reminder: no
        // actions, a tap opens the topic. The rest of the payload still counts (slot, badge).
        let tagged = try container.decodeIfPresent(QuickLogDescriptor.Tag.self, forKey: .quickLog)
        quickLog =
            tagged.map { QuickLogDescriptor.knownTypes.contains($0.type) } == true
            ? try container.decode(QuickLogDescriptor.self, forKey: .quickLog) : nil
        prefill = try container.decodeIfPresent([String: String].self, forKey: .prefill)
    }

    /// The reminder slot this notification is for; nil unless it is a `due` reminder with a
    /// topic and a slot.
    public var slot: ReminderSlot? {
        guard kind == "due", let topicId, let dueSince else { return nil }
        return ReminderSlot(serverId: serverId, topicId: topicId, dueSince: dueSince)
    }
}

/// The `quick_log` descriptor of a reminder (notifications.md §2.3), tagged by `type`.
public enum QuickLogDescriptor: Codable, Sendable, Hashable {
    /// A single-select enum: at most 4 options, in display order.
    case choice(Choice)
    /// An int or double question, with the latest valid value.
    case number(Number)
    /// No questions (`{"type": "single"}`): one "Log it", an entry with no answers.
    case single

    /// The quick question's key; empty for `single`, as in its action identifier.
    public var key: String {
        switch self {
        case .choice(let choice): choice.key
        case .number(let number): number.key
        case .single: ""
        }
    }

    public struct Choice: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var options: [Option]
        /// The number of active options (may exceed `options.count`).
        public var totalOptions: Int

        public init(key: String, label: String, options: [Option], totalOptions: Int) {
            self.key = key
            self.label = label
            self.options = options
            self.totalOptions = totalOptions
        }

        public struct Option: Codable, Sendable, Hashable {
            public var value: String
            public var label: String

            public init(value: String, label: String) {
                self.value = value
                self.label = label
            }
        }

        enum CodingKeys: String, CodingKey {
            case key, label, options
            case totalOptions = "total_options"
        }
    }

    public struct Number: Codable, Sendable, Hashable {
        /// `int` or `double`
        public var type: String
        public var key: String
        public var label: String
        public var unit: String?
        /// Bounds, typed like the question: exact for an int (they may exceed 2^53).
        public var min: QuickLogNumber?
        public var max: QuickLogNumber?
        public var decimals: Int?
        /// nil when there is no previous entry or it no longer validates. An int question's is an
        /// exact `.int` (it may exceed 2^53), a double question's a `.double`.
        public var lastValue: QuickLogNumber?

        public init(
            type: String, key: String, label: String, unit: String? = nil, min: QuickLogNumber? = nil,
            max: QuickLogNumber? = nil, decimals: Int? = nil, lastValue: QuickLogNumber? = nil
        ) {
            self.type = type
            self.key = key
            self.label = label
            self.unit = unit
            self.min = min
            self.max = max
            self.decimals = decimals
            self.lastValue = lastValue
        }

        enum CodingKeys: String, CodingKey {
            case type, key, label, unit, min, max, decimals
            case lastValue = "last_value"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
            decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
            // Typed by the question: an int's numbers stay exact (JSON ints beyond 2^53).
            let isInt = type == "int"
            func number(_ key: CodingKeys) throws -> QuickLogNumber? {
                isInt
                    ? try c.decodeIfPresent(Int.self, forKey: key).map(QuickLogNumber.int)
                    : try c.decodeIfPresent(Double.self, forKey: key).map(QuickLogNumber.double)
            }
            min = try number(.min)
            max = try number(.max)
            lastValue = try number(.lastValue)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try c.encode(key, forKey: .key)
            try c.encode(label, forKey: .label)
            try c.encode(unit, forKey: .unit)
            try c.encode(decimals, forKey: .decimals)
            for (key, number) in [(CodingKeys.min, min), (.max, max), (.lastValue, lastValue)] {
                switch number {
                case .int(let n): try c.encode(n, forKey: key)
                case .double(let x): try c.encode(x, forKey: key)
                case nil: try c.encodeNil(forKey: key)
                }
            }
        }
    }

    private enum TagKeys: String, CodingKey { case type }

    /// The `type` values this build reads; any other quick_log is ignored (a plain reminder).
    static let knownTypes: Set<String> = ["enum", "int", "double", "single"]

    /// Just a quick_log's `type`, to tell a known one from a newer server's.
    struct Tag: Decodable {
        var type: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TagKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "enum": self = .choice(try Choice(from: decoder))
        case "int", "double": self = .number(try Number(from: decoder))
        case "single": self = .single
        case let tag:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown quick_log type \(tag)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .choice(let choice):
            var tag = encoder.container(keyedBy: TagKeys.self)
            try tag.encode("enum", forKey: .type)
            try choice.encode(to: encoder)
        case .number(let number):
            try number.encode(to: encoder)
        case .single:
            var tag = encoder.container(keyedBy: TagKeys.self)
            try tag.encode("single", forKey: .type)
        }
    }
}

/// One reminder slot: what local and remote reminders are de-duplicated on (§11.1). Matching
/// always uses this key from `userInfo.quickr`, never a request identifier.
public struct ReminderSlot: Sendable, Hashable {
    public var serverId: String
    public var topicId: String
    /// Canonical `due_since`.
    public var dueSince: String

    public init(serverId: String, topicId: String, dueSince: String) {
        self.serverId = serverId
        self.topicId = topicId
        self.dueSince = dueSince
    }

    /// The identifier of our own pending local request for this slot: `due-{topic_id}-{due_since}`.
    public var localRequestIdentifier: String { "due-\(topicId)-\(dueSince)" }
}

/// The local/remote de-duplication rules L1–L3 (notifications.md §11.2) on snapshots, so every
/// process applies them the same way. The fallback that produces local reminders is not built in
/// v1; the data contract is.
public enum ReminderDedup {
    /// The delivered notifications to remove when `arriving` is delivered. A remote reminder
    /// removes delivered local ones for its slot (L1, L3). A local reminder for a slot that
    /// already has a delivered remote one is itself the duplicate, so its own id is returned
    /// (L2). Empty when `arriving` isn't a `due` reminder.
    public static func identifiersToRemove(arriving: NotificationSnapshot, delivered: [NotificationSnapshot])
        -> [String]
    {
        guard let info = arriving.quickr, let slot = info.slot else { return [] }
        let sameSlot = delivered.filter { $0.id != arriving.id && $0.quickr?.slot == slot }
        switch info.origin {
        case .remote:
            return sameSlot.filter { $0.quickr?.origin == .local }.map(\.id)
        case .local:
            return sameSlot.contains { $0.quickr?.origin == .remote } ? [arriving.id] : []
        }
    }
}

/// A local notification to schedule.
public struct LocalNotificationRequest: Sendable, Hashable, Identifiable {
    /// `due-{topic_id}-{due_since}` for the fallback (§6a rule 11).
    public var id: String
    public var title: String
    public var body: String
    public var categoryIdentifier: String?
    public var threadIdentifier: String?
    public var quickr: QuickrNotificationInfo?
    /// nil delivers now.
    public var fireDate: Date?
    /// Plays the default sound (a reminder's `"sound": "default"`); silent otherwise.
    public var sound: Bool

    public init(
        id: String, title: String, body: String, categoryIdentifier: String? = nil, threadIdentifier: String? = nil,
        quickr: QuickrNotificationInfo? = nil, fireDate: Date? = nil, sound: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.threadIdentifier = threadIdentifier
        self.quickr = quickr
        self.fireDate = fireDate
        self.sound = sound
    }
}

/// A number quick-log's value: exact for an int question, binary64 for a double one.
public enum QuickLogNumber: Sendable, Hashable {
    case int(Int)
    case double(Double)
}
