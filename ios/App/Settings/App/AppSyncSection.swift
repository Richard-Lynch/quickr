import QuickrData
import QuickrUI
import SwiftUI

/// Settings ▸ "Offline & sync" (the PWA's `SyncSection`): online or offline, what is waiting, the
/// last pull and why pulls keep failing; "Sync now", and the sync sheet (SYNC-UX) for the items.
struct AppSyncSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.fromUpdateRequired) private var fromUpdateRequired
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
            // Re-read every 30 s, so "2 minutes ago" doesn't stand still while the screen is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                LabeledContent("Last synced") {
                    Text(summary.lastSyncAt.map { Self.relative($0, now: context.date) } ?? "Never")
                        .accessibilityIdentifier("settings.sync.last")
                }
            }
            if let problem = summary.problem {
                Text(problem)
                    .foregroundStyle(QuickrTone.danger.foreground)
                    .accessibilityIdentifier("settings.sync.problem")
                    .qrAnnouncesError(problem)
            }
            Button {
                Task {
                    syncing = true
                    // Sends what waits and pulls (pull to refresh's), so "Last synced" moves even
                    // with nothing to send.
                    await environment.sync.refresh()
                    syncing = false
                    QuickrAnnouncer.announce("Sync finished")
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
            // Not under "Update required": the sync sheet would open beneath it.
            if summary.hasItems, !fromUpdateRequired {
                Button("Review changes…") { environment.sync.isSheetPresented = true }
                    .accessibilityIdentifier("settings.sync.review")
            }
        } header: {
            // Stacks at accessibility sizes rather than squeezing the title (audit SE4).
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Offline & sync")
                    Spacer()
                    connectionBadge
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offline & sync")
                    connectionBadge
                }
            }
        } footer: {
            Text(
                "Your topics and entries are kept on this iPhone. Changes made offline wait here and are sent automatically."
            )
        }
    }

    private var connectionBadge: some View {
        QuickrBadge(
            summary.connection == .online ? "Online" : "Offline",
            tone: summary.connection == .online ? .ok : .warn
        )
        .accessibilityIdentifier("settings.sync.connection")
    }

    /// "5 minutes ago".
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
