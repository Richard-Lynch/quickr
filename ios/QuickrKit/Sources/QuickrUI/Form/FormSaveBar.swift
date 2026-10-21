#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// A form screen's Save: a sticky bar at the bottom while no field is being edited, and the last
    /// item in the keyboard's toolbar (after Next/Done) while one is, whether the software keyboard
    /// is up, minimized or replaced by a hardware keyboard (`FormEditing`). Apply it to the
    /// `FormView`. Exactly one Save exists at a time, under `identifier`, and it stays one tap.
    ///
    /// A bar of its own above the keyboard isn't used: SwiftUI's keyboard safe area dropped the
    /// keyboard's toolbar whenever the form changed (the first keystroke), and the bar slid under
    /// Next/Done until the next layout. In the toolbar, Save also keeps the field being typed in
    /// visible at accessibility text sizes.
    ///
    /// - Parameters:
    ///   - title: "Save", "Save again", …
    ///   - isSaving: shows progress in the bar and disables both.
    ///   - onBarHeight: the bar's height as it changes (toasts sit above it).
    ///   - save: the tap, from either place.
    public func formSaveBar(
        _ title: String, identifier: String, isSaving: Bool = false,
        onBarHeight: ((CGFloat) -> Void)? = nil, save: @escaping () -> Void
    ) -> some View {
        modifier(
            FormSaveBar(title: title, identifier: identifier, isSaving: isSaving, onBarHeight: onBarHeight, save: save))
    }
}

/// The Save that `formSaveBar` hands to `FormView` for the keyboard's toolbar.
struct FormSave {
    let title: String
    let identifier: String
    let isSaving: Bool
    let action: () -> Void
}

extension EnvironmentValues {
    @Entry var formSave: FormSave? = nil
}

struct FormSaveBar: ViewModifier {
    let title: String
    let identifier: String
    let isSaving: Bool
    let onBarHeight: ((CGFloat) -> Void)?
    let save: () -> Void
    @State private var editing = FormEditing()

    func body(content: Content) -> some View {
        // Below the form, not over it: in a safe-area inset the form's scroll view ran on under the
        // bar, so whatever was at the bottom of the screen sat behind Save (a11y F8: unreadable, and
        // "clipped" to the accessibility audit at large text sizes). The form now ends where the
        // bar begins, and the bar is opaque.
        VStack(spacing: 0) {
            content
            if !editing.isEditing {
                PrimaryButton(title, icon: .check, isLoading: isSaving, action: save)
                    .accessibilityIdentifier(identifier)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { onBarHeight?($0) })
                    .frame(maxWidth: .infinity)
                    .background(Color.qr.paper)
            }
        }
        // FormView puts it in the keyboard's toolbar, after its Next/Done: one toolbar, in order.
        .environment(\.formSave, FormSave(title: title, identifier: identifier, isSaving: isSaving, action: save))
        // Editing, not the keyboard's frame: the toolbar shows while a field edits, whether the
        // keyboard is up, minimized (iOS 27) or a hardware one (then it's off screen, or never shows).
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) {
            editing.began(ObjectIdentifier($0.object as AnyObject))
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) {
            editing.began(ObjectIdentifier($0.object as AnyObject))
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) {
            editing.ended(ObjectIdentifier($0.object as AnyObject))
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) {
            editing.ended(ObjectIdentifier($0.object as AnyObject))
        }
    }
}
#endif
