import QuickrData
import UIKit
@preconcurrency import UserNotifications

/// The notification center's delegate (notifications.md §7). A reminder's action logs through
/// QuickrData's `NotificationActionHandler` inside a background task, which iOS may have launched
/// the app for; a tap on a body (a reminder, a failure or a tap-to-fix notification) opens its
/// record screen. Becomes the delegate in `AppDelegate`'s `didFinishLaunching`, before launch
/// ends, or an action that launches the app in the background is lost.
@MainActor
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponder()

    private weak var environment: AppEnvironment?

    /// From `QuickRApp.init`, which runs before the delegate can be called.
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// §7.2: shown in the foreground too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // The completion-handler variant: UIKit asserts the completion runs on the main thread, which
    // the async variant doesn't guarantee (the spike crashed on it after every action).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let input = Self.input(
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            content: response.notification.request.content)
        let completion = Completion(completionHandler)
        Task { @MainActor in
            await self.respond(input)
            completion.call()
        }
    }

    /// Handles one response inside a background task (§7.1 steps 0 and 11). The task's expiry
    /// cancels the work, so a flush still running releases its lease and leaves its item
    /// `uncertain` for the next one.
    func respond(_ input: NotificationActionResponse) async {
        guard let environment else { return }
        let application = UIApplication.shared
        let work = Task { await environment.handleNotificationResponse(input) }
        let task = application.beginBackgroundTask(withName: "quickr.notification-action") { work.cancel() }
        await work.value
        if task != .invalid { application.endBackgroundTask(task) }
    }

    /// The handler's input from a response's parts (a `UNNotificationResponse` can't be built in tests).
    nonisolated static func input(actionIdentifier: String, userText: String?, content: UNNotificationContent)
        -> NotificationActionResponse
    {
        let action: NotificationActionResponse.Action =
            switch actionIdentifier {
            case UNNotificationDefaultActionIdentifier: .open
            case UNNotificationDismissActionIdentifier: .dismiss
            default: .custom(actionIdentifier)
            }
        return NotificationActionResponse(
            action: action, userText: userText, title: content.title,
            quickr: SystemNotificationCenter.quickr(content.userInfo))
    }
}

/// The delegate's completion handler, carried to the main actor.
private final class Completion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @MainActor func call() { handler() }
}
