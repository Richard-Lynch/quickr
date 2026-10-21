import ObjectiveC
import QuickrUI
import UIKit

/// The app's `UIApplication`, for the one thing SwiftUI can't do: a VoiceOver magic tap
/// (two-finger double-tap) that runs the newest toast's Undo, and declines when there is none, so
/// the system's own (play/pause) still works. A SwiftUI `.accessibilityAction(.magicTap)` can't
/// decline, so it would swallow the system's (audit X1).
///
/// VoiceOver sends the magic tap to the focused element and then up the responder chain, which
/// ends at the application (before SwiftUI's internal app delegate). A SwiftUI `App` ignores
/// Info.plist's `NSPrincipalClass`, so ``install(toasts:)`` makes the running application this
/// subclass (as KVO does: it adds no stored properties, only an override).
final class QuickrApplication: UIApplication {
    /// The toasts the magic tap acts on: `AppEnvironment.toasts`.
    private(set) static weak var toasts: ToastCenter?

    override func accessibilityPerformMagicTap() -> Bool {
        if let toasts = Self.toasts, toasts.performNewestAction() { return true }
        return super.accessibilityPerformMagicTap()
    }

    /// At launch (`QuickRApp.init`): the shared application becomes a `QuickrApplication` acting
    /// on `toasts`. Idempotent.
    static func install(toasts: ToastCenter) {
        self.toasts = toasts
        let app = UIApplication.shared
        if !(app is QuickrApplication) { object_setClass(app, QuickrApplication.self) }
    }

    /// `UIApplication.shared` as this class, once installed.
    static var current: QuickrApplication? { UIApplication.shared as? QuickrApplication }
}
