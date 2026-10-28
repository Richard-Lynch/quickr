import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import UIKit

/// Shows "Update required" in a window of its own above the app's (client-versions.md §4.1), so it
/// covers every sheet, alert and dialog already open, whichever screen presented them. They stay
/// where they were, under it, and come back when it leaves.
@MainActor
final class UpdateRequiredWindow {
    private var window: UIWindow?

    func update(outdated: Bool, environment: AppEnvironment) {
        outdated ? show(environment) : hide()
    }

    private func show(_ environment: AppEnvironment) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }
        let host = UIHostingController(rootView: UpdateRequiredRoot().environment(environment))
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        // VoiceOver reads this window only.
        window.accessibilityViewIsModal = true
        window.makeKeyAndVisible()
        self.window = window
    }

    private func hide() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        scenes.flatMap(\.windows).first { !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
    }
}

/// The window's content: the view, and in UI tests the debug controls, which the app's own copy
/// under it can't be reached through.
private struct UpdateRequiredRoot: View {
    var body: some View {
        UpdateRequiredView()
            #if DEBUG
        .overlay(alignment: .bottom) {
            if UITestLaunch.showsSyncControls { UITestSyncControls().padding(.bottom, 24) }
        }
            #endif
    }
}

/// Settings reached from "Update required": nothing in it may present over the app beneath (the
/// sync sheet's "Review changes…").
struct FromUpdateRequiredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var fromUpdateRequired: Bool {
        get { self[FromUpdateRequiredKey.self] }
        set { self[FromUpdateRequiredKey.self] = newValue }
    }
}

/// "Update required" (client-versions.md §4.1): over everything else while this build is below the
/// server's minimum. Open TestFlight goes to `update_url.ios`; Check again asks the server, and the
/// view leaves once its minimum is one this build meets. Settings stays reachable, so the user can
/// switch to another server (whose store isn't outdated).
struct UpdateRequiredView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var showsSettings = false
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        let update = environment.clientUpdate
        ScrollView {
            VStack(spacing: 16) {
                QIcon.download.view(size: 36).foregroundStyle(.qr.accentStrong).accessibilityHidden(true)
                Text("Update required")
                    .font(.qr(.largeTitle))
                    .foregroundStyle(.qr.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .accessibilityIdentifier("update.title")
                Text(ClientUpdate.message(unsynced: unsynced))
                    .font(.qr(.body))
                    .foregroundStyle(.qr.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update.message")
                VStack(spacing: 12) {
                    PrimaryButton("Open TestFlight", icon: .download) { openURL(update.updateURL) }
                        .accessibilityIdentifier("update.open")
                        .accessibilityValue(Self.testValue(update.updateURL))
                    Button {
                        Task { await update.checkAgain() }
                    } label: {
                        HStack(spacing: 8) {
                            if update.checking { ProgressView() }
                            Text("Check again")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.qr(.secondary, size: .large))
                    .disabled(update.checking)
                    .accessibilityIdentifier("update.check")
                    if update.checkFailed {
                        Text(Self.checkFailedMessage)
                            .font(.qr(.footnote))
                            .foregroundStyle(QuickrTone.danger.foreground)
                            .multilineTextAlignment(.center)
                            .qrAnnouncesError(Self.checkFailedMessage)
                            .accessibilityIdentifier("update.checkError")
                    }
                    Button("Server settings") { showsSettings = true }
                        .buttonStyle(.qr(.ghost))
                        .accessibilityIdentifier("update.settings")
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        }
        .qrPaperBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("update.required")
        // The server's update link; a foreground checks again too (`ClientUpdate.didBecomeActive`).
        .task {
            titleFocused = true
            await update.checkAgain()
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .environment(\.fromUpdateRequired, true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettings = false }.accessibilityIdentifier("update.settingsDone")
                        }
                    }
            }
        }
    }

    static let checkFailedMessage = "Couldn’t reach the server. Check your connection and try again."

    /// The link, for UI tests only: VoiceOver has no use for it.
    private static func testValue(_ url: URL) -> String {
        #if DEBUG
        UITestLaunch.isActive ? url.absoluteString : ""
        #else
        ""
        #endif
    }

    /// Everything on this iPhone the server doesn't have yet: queued (held included) and failed.
    private var unsynced: Int {
        let summary = environment.sync.summary
        return (summary?.queued ?? 0) + (summary?.failed ?? 0)
    }
}

/// The "server needs updating" note at the top of Home (client-versions.md §4.5): it blocks
/// nothing, and the user can dismiss it for this launch.
struct ServerBehindBanner: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            QIcon.info.view(size: 16, weight: .bold).foregroundStyle(.qr.info).accessibilityHidden(true)
            Text(ClientUpdate.serverBehindMessage)
                .font(.qr(.footnote))
                .foregroundStyle(.qr.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("home.serverBehind.text")
            Button(action: dismiss) {
                QIcon.x.view(size: 14, weight: .bold).foregroundStyle(.qr.muted)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("home.serverBehind.dismiss")
            .padding(.vertical, -12)
            .padding(.trailing, -12)
        }
        .padding(16)
        .background(Color.qr.infoSoft, in: RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.serverBehind")
    }
}
