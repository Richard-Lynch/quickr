import UIKit
import UserNotifications

/// The app delegate: the APNs token callbacks (notifications.md §9.2), handed to
/// `RemoteNotificationTokens`, and the notification center's delegate (`NotificationResponder`,
/// §7), set before launch ends. In DEBUG the spike's delegate subclasses this one.
class AppDelegate: NSObject, UIApplicationDelegate {
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
