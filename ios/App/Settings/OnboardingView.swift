import QuickrData
import QuickrUI
import SwiftUI

/// First launch: connect to a quickR server, then the reminders explainer, then the topic list.
/// Shown while no server is configured (`AppSession.phase == .noServer`) until `finish` runs.
struct OnboardingView: View {
    @State private var setup: ServerSetup
    @State private var permission = NotificationPermission()
    @State private var step = Step.server
    let finish: () -> Void

    private enum Step {
        case server
        case reminders
    }

    init(
        session: AppSession, settings: AppSettings, credentials: KeychainAccessCredentials?,
        finish: @escaping () -> Void
    ) {
        _setup = State(initialValue: ServerSetup(session: session, settings: settings, credentials: credentials))
        self.finish = finish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch step {
                case .server: serverStep
                case .reminders: remindersStep
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .qrPaperBackground()
        .onChange(of: setup.state) { _, state in
            if case .connected = state { advance() }
        }
    }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("quickR")
                    .font(.qr(.largeTitle))
                    .foregroundStyle(.qr.accent)
                    .accessibilityAddTraits(.isHeader)
                Text("Log the things you track in a tap or two. Connect to your quickR server to start.")
                    .font(.qr(.body))
                    .foregroundStyle(.qr.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card(padding: 20) {
                ServerForm(setup: setup)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.server")
    }

    private var remindersStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Connected")
                .font(.qr(.largeTitle))
                .foregroundStyle(.qr.ink)
                .accessibilityAddTraits(.isHeader)
            if case .connected(let note?) = setup.state {
                Text(note)
                    .font(.qr(.subheadline))
                    .foregroundStyle(QuickrTone.warn.foreground)
            }
            Card(padding: 20) {
                NotificationExplainer(permission: permission)
            }
            PrimaryButton(permission.status == .allowed ? "Continue" : "Not now", icon: .chevronRight, action: finish)
                .accessibilityIdentifier("onboarding.done")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.reminders")
    }

    private func advance() {
        Task {
            await permission.refresh()
            // Nothing to explain once the user has decided.
            if permission.status == .notDetermined { step = .reminders } else { finish() }
        }
    }
}
