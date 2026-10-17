import UserNotifications

/// M0 placeholder: delivers the notification unchanged. Dedupe, badge and category
/// registration arrive in M3 (docs/ios/specs/notifications.md).
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        contentHandler(request.content)
    }
}
