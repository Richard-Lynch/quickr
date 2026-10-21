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
        await center.pendingNotificationRequests().map {
            Self.snapshot($0, date: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
        }
    }

    public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func add(_ request: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if let category = request.categoryIdentifier { content.categoryIdentifier = category }
        if let thread = request.threadIdentifier { content.threadIdentifier = thread }
        if let quickr = request.quickr,
            let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(quickr))
        {
            content.userInfo = ["quickr": object]
        }
        let trigger = request.fireDate.map {
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: $0),
                repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }

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

    static func snapshot(_ request: UNNotificationRequest, date: Date?) -> NotificationSnapshot {
        let quickr = request.content.userInfo["quickr"].flatMap { object -> QuickrNotificationInfo? in
            guard JSONSerialization.isValidJSONObject(object),
                let data = try? JSONSerialization.data(withJSONObject: object)
            else { return nil }
            return try? JSONDecoder().decode(QuickrNotificationInfo.self, from: data)
        }
        return NotificationSnapshot(
            id: request.identifier, categoryIdentifier: request.content.categoryIdentifier,
            threadIdentifier: request.content.threadIdentifier, date: date, quickr: quickr)
    }
}
#endif
