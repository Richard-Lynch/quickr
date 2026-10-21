import QuickrData
import QuickrUI
import SwiftUI

/// Settings ▸ Notifications, once reminders are allowed: this device's push registration, a setup
/// error when the profile has no valid APNs environment (notifications.md §9.1), and "Test this
/// device" (online only).
struct PushDeviceRow: View {
    let push: PushLifecycle
    @State private var testing = false
    /// Counts tests, so each result is read, even the same one again.
    @State private var tests = 0
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch push.status {
            case .environmentError:
                Text(ProvisioningProfile.failureMessage)
                    .font(.qr(.subheadline))
                    .foregroundStyle(QuickrTone.danger.foreground)
                    .accessibilityIdentifier("push.environmentError")
            case .failed(let message):
                Text(message)
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.muted)
                    .accessibilityIdentifier("push.failed")
            default:
                EmptyView()
            }
            Button {
                Task { await test() }
            } label: {
                Text(testing ? "Sending…" : "Test this device")
            }
            .buttonStyle(.qr(.secondary))
            .disabled(testing || isEnvironmentError)
            .accessibilityIdentifier("push.test")
            if let result {
                Text(result)
                    .font(.qr(.subheadline))
                    .foregroundStyle(.qr.inkSoft)
                    .accessibilityIdentifier("push.testResult")
                    // Read as it appears: the button only changes back from "Sending…" (audit SE8).
                    .qrMovesVoiceOverFocus(on: tests)
            }
        }
        .padding(.vertical, 4)
    }

    private var isEnvironmentError: Bool {
        if case .environmentError = push.status { true } else { false }
    }

    private func test() async {
        result = nil  // never the last test's outcome while this one runs
        testing = true
        defer { testing = false }
        let outcome =
            switch await push.testThisDevice() {
            case .sent: "Sent. It should arrive in a few seconds."
            case .notRegistered: "This device isn't registered for reminders yet. Try again in a moment."
            case .disabled: "This server isn't set up to send reminders to iPhones."
            case .offline: "You're offline. Try again when you're connected."
            case .failed(let message): message
            }
        // The outcome and its focus request together, so each test's own result is read.
        result = outcome
        tests += 1
    }
}
