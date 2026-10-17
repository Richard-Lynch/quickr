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
        /// Logs a fixed answer (`UNNotificationAction`).
        case log
        /// Asks for a number (`UNTextInputNotificationAction`).
        case input(buttonTitle: String, placeholder: String)
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

/// The `quickr` object of a payload (notifications.md §2.1). The descriptor is kept as JSON;
/// the handler decodes it against the version it names.
public struct QuickrNotificationInfo: Sendable, Hashable {
    public var v: Int
    /// `due`, `test` or `sync`
    public var kind: String
    public var serverId: String
    public var topicId: String?
    public var topicSlug: String?
    public var version: Int?
    /// Canonical slot: UTC, whole seconds, `Z` (notifications.md §11.1).
    public var dueSince: String?

    public init(
        v: Int = 1, kind: String, serverId: String, topicId: String? = nil, topicSlug: String? = nil,
        version: Int? = nil, dueSince: String? = nil
    ) {
        self.v = v
        self.kind = kind
        self.serverId = serverId
        self.topicId = topicId
        self.topicSlug = topicSlug
        self.version = version
        self.dueSince = dueSince
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

    public init(
        id: String, title: String, body: String, categoryIdentifier: String? = nil, threadIdentifier: String? = nil,
        quickr: QuickrNotificationInfo? = nil, fireDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.threadIdentifier = threadIdentifier
        self.quickr = quickr
        self.fireDate = fireDate
    }
}
