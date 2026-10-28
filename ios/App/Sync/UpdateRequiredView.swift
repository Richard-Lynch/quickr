import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// "Update required" (client-versions.md §4.1): over everything else while this build is below the
/// server's minimum. Open TestFlight goes to `update_url.ios`; Check again asks the server, and the
/// view leaves once its minimum is one this build meets. Settings stays reachable, so the user can
/// switch to another server (whose store isn't outdated).
struct UpdateRequiredView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var showsSettings = false

    var body: some View {
        let update = environment.clientUpdate
        ScrollView {
            VStack(spacing: 16) {
                QIcon.download.view(size: 36).foregroundStyle(.qr.accentStrong).accessibilityHidden(true)
                Text("Update required")
                    .font(.qr(.largeTitle))
                    .foregroundStyle(.qr.ink)
                    .accessibilityAddTraits(.isHeader)
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
                        .accessibilityValue(update.updateURL.absoluteString)
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
        .task { await update.checkAgain() }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettings = false }.accessibilityIdentifier("update.settingsDone")
                        }
                    }
            }
        }
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
