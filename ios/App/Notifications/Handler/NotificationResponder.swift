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
    /// `UIApplication`'s background tasks; tests pass fakes to `run`.
    var backgroundTasks: any BackgroundTasking = ApplicationBackgroundTasks()

    /// From `QuickRApp.init`, which runs before the delegate can be called.
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// §7.2: shown in the foreground too, unless it is a reminder the active store already
    /// satisfies (then it is suppressed and removed).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let snapshot = NotificationSnapshot(
            id: notification.request.identifier,
            quickr: SystemNotificationCenter.quickr(notification.request.content.userInfo))
        return await shouldPresent(snapshot) ? [.banner, .list, .sound] : []
    }

    private func shouldPresent(_ snapshot: NotificationSnapshot) async -> Bool {
        await environment?.shouldPresentNotification(snapshot) ?? true
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
        Task { @MainActor in await self.respond(input) { completion.call() } }
    }

    /// Handles one response inside a background task (§7.1 steps 0 and 11), then calls `completion`.
    func respond(_ input: NotificationActionResponse, completion: @escaping @MainActor () -> Void) async {
        guard let environment else { return completion() }
        // Tapped while the app is suspended in the background, its GRDB is suspended too: resumed
        // for this response, suspended again after it unless the app came to the foreground.
        await Self.run(tasks: backgroundTasks, hold: environment.session?.holdStoreResumed(), completion: completion) {
            await environment.handleNotificationResponse(input)
        }
    }

    /// Runs `work` inside a background task. The task ends and `completion` is called exactly once:
    /// when the work finishes, or at once when the task expires (the work is then cancelled: a
    /// flush still running releases its lease and leaves its item `uncertain` for the next one).
    /// `hold` keeps the store resumed for the work; it's released before the task ends, so GRDB
    /// is suspended again before the time runs out.
    static func run(
        tasks: any BackgroundTasking, hold: StoreHold? = nil, completion: @escaping @MainActor () -> Void,
        work: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let finisher = ResponseFinisher(end: { tasks.end($0) }, completion: completion)
        // Created first so expiry can cancel it; it starts once this returns to the main actor.
        let job = Task { @MainActor in await work() }
        finisher.started(
            tasks.begin(name: "quickr.notification-action") {
                job.cancel()
                hold?.release()
                finisher.finish()
            })
        await job.value
        hold?.release()
        finisher.finish()
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

/// `UIApplication`'s background tasks, behind a protocol for tests.
@MainActor
protocol BackgroundTasking {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ task: UIBackgroundTaskIdentifier)
}

struct ApplicationBackgroundTasks: BackgroundTasking {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expiration() } }
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// Finishes a response exactly once, whichever comes first: ends its background task and calls
/// the delegate's completion. An expiry before `begin` returned still ends the task it returns.
@MainActor
final class ResponseFinisher {
    private let end: (UIBackgroundTaskIdentifier) -> Void
    private let completion: () -> Void
    private var task: UIBackgroundTaskIdentifier?
    private(set) var isFinished = false

    init(end: @escaping (UIBackgroundTaskIdentifier) -> Void, completion: @escaping () -> Void) {
        self.end = end
        self.completion = completion
    }

    func started(_ task: UIBackgroundTaskIdentifier) {
        if isFinished {
            if task != .invalid { end(task) }
        } else {
            self.task = task
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        if let task, task != .invalid { end(task) }
        completion()
    }
}

/// The delegate's completion handler, carried to the main actor.
private final class Completion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @MainActor func call() { handler() }
}
