import Observation
import QuickrUI
import SwiftUI
import UIKit
import UserNotifications

/// Whether quickR may post reminders, and asking for it. Registering this device with the server
/// for push is REG's (M3); this only covers the permission.
@MainActor @Observable
final class NotificationPermission {
    enum Status: Equatable {
        case unknown
        case notDetermined
        case allowed
        case denied
    }

    private(set) var status: Status = .unknown

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status =
            switch settings.authorizationStatus {
            case .notDetermined: .notDetermined
            case .denied: .denied
            case .authorized, .provisional, .ephemeral: .allowed
            @unknown default: .unknown
            }
    }

    /// Shows the system prompt (once; after that, only Settings can change it).
    func request() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }
}

/// Why quickR asks for notifications, and the one button that fits the current status.
struct NotificationExplainer: View {
    let permission: NotificationPermission
    @Environment(\.openURL) private var openURL
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                QIcon.bell.view(size: 20, weight: .bold)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.qr.accentStrong)
                    .background(Color.qr.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                Text("Reminders")
                    .font(.qr(.section))
                    .foregroundStyle(.qr.ink)
            }
            Text(
                "quickR reminds you when a topic is due, and you can log straight from the reminder without opening the app. It never sends anything else."
            )
            .font(.qr(.body))
            .foregroundStyle(.qr.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            switch permission.status {
            case .allowed:
                Label("Reminders are on", systemImage: "checkmark.circle.fill")
                    .font(.qr(.callout))
                    .foregroundStyle(QuickrTone.ok.foreground)
                    .accessibilityIdentifier("notifications.allowed")
            case .denied:
                Text("Reminders are off for quickR. Turn them on in Settings ▸ Notifications ▸ quickR.")
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.qr(.secondary))
                .accessibilityIdentifier("notifications.openSettings")
            case .notDetermined, .unknown:
                Button("Allow reminders") {
                    Task {
                        await permission.request()
                        // Granted: register this device for push now (notifications.md §9.2).
                        if permission.status == .allowed { await environment.push?.permissionGranted() }
                    }
                }
                .buttonStyle(.qr(.secondary))
                .accessibilityIdentifier("notifications.allow")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications.explainer")
        .task { await permission.refresh() }
    }
}
