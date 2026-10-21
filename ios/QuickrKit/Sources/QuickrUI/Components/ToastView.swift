#if os(iOS)
import SwiftUI
import UIKit

/// One toast: an ink card with a tone dot, the message, an optional action (44 pt) and a
/// 44 pt dismiss button.
public struct ToastView: View {
    let toast: Toast
    let onAction: () -> Void
    let onDismiss: () -> Void

    public init(_ toast: Toast, onAction: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.toast = toast
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            toneIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.qr(.sansSemiBold, size: 14, relativeTo: .subheadline))
                if let message = toast.message {
                    Text(message).font(.qr(.sansRegular, size: 12, relativeTo: .caption)).opacity(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("toast.text")
            if let action = toast.action {
                Button(action.label, action: onAction)
                    .font(.qr(.sansSemiBold, size: 14, relativeTo: .subheadline))
                    .padding(.horizontal, 16)
                    .frame(minHeight: QuickrMetrics.tapTarget)
                    .background(Color.qr.paper.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
                    .buttonStyle(QuickrPressStyle())
                    .accessibilityIdentifier("toast.action")
            }
            Button(action: onDismiss) {
                QIcon.x.view(size: 16)
                    .frame(width: QuickrMetrics.tapTarget, height: QuickrMetrics.tapTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .padding(.trailing, -8)
            .accessibilityLabel("Dismiss \(toast.title)")
        }
        .foregroundStyle(.qr.paper)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 384)
        .background(Color.qr.ink, in: RoundedRectangle(cornerRadius: QuickrMetrics.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuickrMetrics.chipRadius, style: .continuous)
                .strokeBorder(Color.qr.line, lineWidth: 1)
        )
        .qrShadow(.float)
    }

    private var toneIcon: some View {
        let (icon, color): (QIcon, Color) =
            switch toast.tone {
            case .ok: (.check, .qr.ok)
            case .info: (.info, .qr.info)
            case .danger: (.x, .qr.danger)
            }
        return icon.view(size: 12, weight: .black)
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: Circle())
    }
}

private struct ToastHostModifier: ViewModifier {
    let center: ToastCenter
    let bottomInset: CGFloat
    private let voiceOverStatus = NotificationCenter.default.publisher(
        for: UIAccessibility.voiceOverStatusDidChangeNotification)
    @QuickrReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(center)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    ForEach(center.items) { item in
                        ToastView(
                            item.toast,
                            onAction: { center.performAction(item.id) },
                            onDismiss: { center.dismiss(item.id) }
                        )
                        .transition(
                            reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, bottomInset)
                .animation(reduceMotion ? nil : QuickrMotion.rise, value: center.items.map(\.id))
            }
            .onChange(of: center.items.last?.id) { _, id in
                guard let id, let item = center.items.first(where: { $0.id == id }) else { return }
                AccessibilityNotification.Announcement(item.toast.announcement).post()
            }
            .onReceive(voiceOverStatus) { _ in center.voiceOverStatusChanged() }
    }
}

extension View {
    /// Shows `center`'s toasts at the bottom (thumb reach), `bottomInset` above the safe area,
    /// and puts `center` in the environment for `@Environment(ToastCenter.self)`.
    public func toastHost(_ center: ToastCenter, bottomInset: CGFloat = 8) -> some View {
        modifier(ToastHostModifier(center: center, bottomInset: bottomInset))
    }
}

private struct ToastPreview: View {
    @State var center = ToastCenter()

    var body: some View {
        VStack(spacing: 12) {
            Button("Logged (undo)") {
                center.show(Toast("Logged Mild", message: "Headache", action: .init("Undo") {}))
            }
            Button("Info") { center.show(Toast("Saved offline", message: "Will sync when back online", tone: .info)) }
            Button("Error") { center.show(Toast("Couldn’t save", tone: .danger)) }
        }
        .buttonStyle(.qr(.secondary))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qrPaperBackground()
        .toastHost(center)
    }
}

#Preview("Toasts") { ToastPreview() }
#endif
