import UIKit

/// The app delegate: the APNs token callbacks (notifications.md §9.2), handed to
/// `RemoteNotificationTokens`. The notification response handler is M3's (HANDLER); in DEBUG the
/// spike's delegate subclasses this one.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemoteNotificationTokens.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        RemoteNotificationTokens.shared.didFail(error)
    }
}
