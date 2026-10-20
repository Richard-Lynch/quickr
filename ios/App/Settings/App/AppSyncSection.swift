import QuickrData
import QuickrUI
import SwiftUI

/// Settings ▸ "Offline & sync" (the PWA's `SyncSection`): online or offline, what is waiting, the
/// last pull and why pulls keep failing; "Sync now", and the sync sheet (SYNC-UX) for the items.
struct AppSyncSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var syncing = false

    private var summary: SettingsSyncSummary {
        SettingsSyncSummary(
            summary: environment.sync.summary, status: environment.session?.syncStatus ?? SyncStatus(),
            online: environment.sync.online)
    }

    var body: some View {
        let summary = summary
        Section {
            LabeledContent("Status") {
                Text(summary.headline).accessibilityIdentifier("settings.sync.headline")
            }
            LabeledContent("Last synced") {
                Text(summary.lastSyncAt.map(Self.relative) ?? "Never")
                    .accessibilityIdentifier("settings.sync.last")
            }
            if let problem = summary.problem {
                Text(problem)
                    .foregroundStyle(QuickrTone.danger.foreground)
                    .accessibilityIdentifier("settings.sync.problem")
            }
            Button {
                Task {
                    syncing = true
                    await environment.sync.syncNow()
                    syncing = false
                }
            } label: {
                HStack {
                    Text("Sync now")
                    if syncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(syncing || environment.session?.binding == nil)
            .accessibilityIdentifier("settings.syncNow")
            if summary.hasItems {
                Button("Review changes…") { environment.sync.isSheetPresented = true }
                    .accessibilityIdentifier("settings.sync.review")
            }
        } header: {
            HStack {
                Text("Offline & sync")
                Spacer()
                QuickrBadge(
                    summary.connection == .online ? "Online" : "Offline",
                    tone: summary.connection == .online ? .ok : .warn
                )
                .accessibilityIdentifier("settings.sync.connection")
            }
        } footer: {
            Text(
                "Your topics and entries are kept on this iPhone. Changes made offline wait here and are sent automatically."
            )
        }
    }

    /// "5 minutes ago".
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
