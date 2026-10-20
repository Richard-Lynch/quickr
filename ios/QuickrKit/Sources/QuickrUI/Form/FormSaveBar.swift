#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// A form screen's Save: a sticky bar at the bottom while the keyboard is down, and an item in
    /// the keyboard's toolbar (beside FORM's Next/Done) while it is up. Exactly one Save exists at
    /// a time, under `identifier`, and it stays one tap.
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

struct FormSaveBar: ViewModifier {
    let title: String
    let identifier: String
    let isSaving: Bool
    let onBarHeight: ((CGFloat) -> Void)?
    let save: () -> Void
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if !keyboardUp {
                    PrimaryButton(title, icon: .check, isLoading: isSaving, action: save)
                        .accessibilityIdentifier(identifier)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { onBarHeight?($0) })
                }
            }
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button(action: save) {
                        Label(title, systemImage: "checkmark").labelStyle(.titleAndIcon)
                    }
                    .font(.qr(.callout))
                    .fontWeight(.semibold)
                    .tint(.qr.accent)
                    .disabled(isSaving)
                    .accessibilityIdentifier(identifier)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
    }
}
#endif
