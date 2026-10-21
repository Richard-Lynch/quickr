import QuickrUI
import UIKit

/// The app's `UIApplication` (Info.plist `NSPrincipalClass`), for the one thing SwiftUI can't do:
/// a VoiceOver magic tap (two-finger double-tap) that runs the newest toast's Undo, and declines
/// when there is none, so the system's own (play/pause) still works.
///
/// VoiceOver sends the magic tap to the focused element and then up the responder chain, which
/// ends here (before SwiftUI's internal app delegate). A SwiftUI `.accessibilityAction(.magicTap)`
/// can't decline, so it would swallow the system's (audit X1).
@objc(QuickrApplication)
final class QuickrApplication: UIApplication {
    /// The toasts the magic tap acts on: `AppEnvironment.toasts`, set at launch.
    weak var toasts: ToastCenter?

    override func accessibilityPerformMagicTap() -> Bool {
        toasts?.performNewestAction() ?? false
    }

    /// `UIApplication.shared` as this class (always, unless Info.plist lost `NSPrincipalClass`).
    static var current: QuickrApplication? { UIApplication.shared as? QuickrApplication }
}
