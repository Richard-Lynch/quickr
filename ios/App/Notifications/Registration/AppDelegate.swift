import QuickrUI
import UIKit
import UserNotifications

/// The app delegate: the APNs token callbacks (notifications.md §9.2), handed to
/// `RemoteNotificationTokens`, and the notification center's delegate (`NotificationResponder`,
/// §7), set before launch ends. In DEBUG the spike's delegate subclasses this one.
///
/// A `UIResponder`, so it ends the responder chain: a VoiceOver magic tap (two-finger double-tap)
/// that no element handled arrives here and runs the newest toast's Undo, or declines so the
/// system's own (play/pause) still works. A SwiftUI `.accessibilityAction(.magicTap)` can't
/// decline (audit X1).
class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The toasts the magic tap acts on: `AppEnvironment.toasts`, set in `QuickRApp.init`.
    static weak var toasts: ToastCenter?

    override func accessibilityPerformMagicTap() -> Bool {
        Self.toasts?.performNewestAction() ?? false
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG || QUICKR_PERF
        PerfProbe.mark("didFinishLaunching")
        #endif
        UNUserNotificationCenter.current().delegate = NotificationResponder.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemoteNotificationTokens.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        RemoteNotificationTokens.shared.didFail(error)
    }
}
