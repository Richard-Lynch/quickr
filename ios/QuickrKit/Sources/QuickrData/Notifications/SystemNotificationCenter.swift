#if canImport(UserNotifications)
import Foundation
@preconcurrency import UserNotifications

/// `NotificationCenterProtocol` over `UNUserNotificationCenter.current()`: the minimal adapter
/// that lets the app register reminder categories now (notifications.md §5; spike F1). Its
/// delegate and the action handler are M3's (HANDLER). Registering categories needs no
/// permission, so nothing here prompts unless `requestAuthorization()` is called.
///
/// Created lazily: `UNUserNotificationCenter.current()` needs an app (or extension) bundle.
public struct SystemNotificationCenter: NotificationCenterProtocol {
    public init() {}

    private var center: UNUserNotificationCenter { .current() }

    public func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        center.setNotificationCategories(Set(categories.map(Self.category)))
    }

    public func notificationCategories() async -> [NotificationCategorySpec] {
        await center.notificationCategories().map(Self.spec).sorted { $0.id < $1.id }
    }

    public func deliveredNotifications() async -> [NotificationSnapshot] {
        await center.deliveredNotifications().map { Self.snapshot($0.request, date: $0.date) }
    }

    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func pendingNotificationRequests() async -> [NotificationSnapshot] {
        await center.pendingNotificationRequests().map { request in
            // T2-M1: an interval trigger's `nextTriggerDate()` counts from now, not from when it was
            // added; a run alert carries its instant (`fire_at_ms`).
            let fireAt = Self.quickr(request.content.userInfo)?.fireAtMs.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            return Self.snapshot(
                request, date: fireAt ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
            // end T2-M1
        }
    }

    public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func add(_ request: LocalNotificationRequest) async throws {
        // T2-M1 (timers2.md §9.1, OQ-6)
        try await center.add(Self.systemRequest(request, now: Date()))
        // end T2-M1
    }

    // T2-M1 (timers2.md §9.1, §12.3 R23)
    /// The request `add` hands the system: the content (sound, `quickr` info, interruption level)
    /// and `trigger(_:now:)`'s trigger. Public so the app's tests can check it on the simulator,
    /// where the system lists no pending request for an app without notification permission.
    public static func systemRequest(_ request: LocalNotificationRequest, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if let category = request.categoryIdentifier { content.categoryIdentifier = category }
        if let thread = request.threadIdentifier { content.threadIdentifier = thread }
        if request.sound { content.sound = .default }
        if let quickr = request.quickr,
            let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(quickr))
        {
            content.userInfo = ["quickr": object]
        }
        content.interruptionLevel = level(request.interruptionLevel)
        return UNNotificationRequest(identifier: request.id, content: content, trigger: trigger(request, now: now))
    }
    // end T2-M1

    // T2-M1 (timers2.md §9.1)
    /// `fireAt`: an interval trigger, at least 1 s (the system's minimum). Otherwise `fireDate`'s
    /// calendar trigger, or none (delivered now).
    static func trigger(_ request: LocalNotificationRequest, now: Date) -> UNNotificationTrigger? {
        if let fireAt = request.fireAt {
            return UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireAt.timeIntervalSince(now)), repeats: false)
        }
        return request.fireDate.map {
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: $0),
                repeats: false)
        }
    }

    static func level(_ level: NotificationInterruptionLevel) -> UNNotificationInterruptionLevel {
        switch level {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        case .critical: .critical
        }
    }

    static func level(_ level: UNNotificationInterruptionLevel) -> NotificationInterruptionLevel {
        switch level {
        case .passive: .passive
        case .timeSensitive: .timeSensitive
        case .critical: .critical
        default: .active
        }
    }
    // end T2-M1

    public func setBadgeCount(_ count: Int) async throws {
        try await center.setBadgeCount(count)
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: .authorized
        case .denied: .denied
        case .provisional: .provisional
        #if os(iOS)
        case .ephemeral: .ephemeral
        #endif
        default: .notDetermined
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    // MARK: - Mapping

    static func category(_ spec: NotificationCategorySpec) -> UNNotificationCategory {
        let actions: [UNNotificationAction] = spec.actions.map { action in
            var options: UNNotificationActionOptions = []
            if action.kind.opensApp { options.insert(.foreground) }
            if action.requiresAuthentication { options.insert(.authenticationRequired) }
            switch action.kind {
            case .log, .open:
                return UNNotificationAction(identifier: action.id, title: action.title, options: options)
            case .input(let buttonTitle, let placeholder):
                return UNTextInputNotificationAction(
                    identifier: action.id, title: action.title, options: options, textInputButtonTitle: buttonTitle,
                    textInputPlaceholder: placeholder)
            }
        }
        return UNNotificationCategory(identifier: spec.id, actions: actions, intentIdentifiers: [], options: [])
    }

    static func spec(_ category: UNNotificationCategory) -> NotificationCategorySpec {
        NotificationCategorySpec(
            id: category.identifier,
            actions: category.actions.map { action in
                let kind: NotificationActionSpec.Kind =
                    if let input = action as? UNTextInputNotificationAction {
                        .input(buttonTitle: input.textInputButtonTitle, placeholder: input.textInputPlaceholder)
                    } else if action.options.contains(.foreground) {
                        .open
                    } else {
                        .log
                    }
                return NotificationActionSpec(
                    id: action.identifier, title: action.title, kind: kind,
                    requiresAuthentication: action.options.contains(.authenticationRequired))
            })
    }

    /// `userInfo.quickr`, decoded; nil when it is missing or isn't quickR's shape.
    public static func quickr(_ userInfo: [AnyHashable: Any]) -> QuickrNotificationInfo? {
        userInfo["quickr"].flatMap { object -> QuickrNotificationInfo? in
            guard JSONSerialization.isValidJSONObject(object),
                let data = try? JSONSerialization.data(withJSONObject: object)
            else { return nil }
            return try? JSONDecoder().decode(QuickrNotificationInfo.self, from: data)
        }
    }

    static func snapshot(_ request: UNNotificationRequest, date: Date?) -> NotificationSnapshot {
        let quickr = quickr(request.content.userInfo)
        let content = request.content
        return NotificationSnapshot(
            id: request.identifier, categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier, date: date, quickr: quickr, title: content.title,
            body: content.body, sound: content.sound != nil, interruptionLevel: level(content.interruptionLevel))
    }
}
#endif
