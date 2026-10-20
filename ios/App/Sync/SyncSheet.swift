import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI

/// The sync sheet (the PWA's `OutboxPanel`): what is waiting or failed, with Retry, Fix, Discard
/// and Dismiss per item (outbox.md §11), "Sync now", the last sync, and pull to refresh.
struct SyncSheet: View {
    /// Opens a route (Fix); the presenter closes the sheet first.
    let open: (Route) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var syncing = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            // Re-read every 30 s so "retrying in N min" and "Last synced" stay true.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                content(environment.sync.sheet(lastSyncAt: environment.session?.syncStatus.lastSyncAt))
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("sync.done")
                }
            }
            .alert(
                "Couldn’t do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }),
                actions: { Button("OK", role: .cancel) {} }, message: { Text(problem ?? "") })
        }
        .accessibilityIdentifier("sync.sheet")
    }

    private func content(_ model: SyncSheetModel) -> some View {
        List {
            if environment.session?.syncStatus.identityMismatch == true {
                banner(
                    "This address now points to a different quickR server",
                    "Nothing is sent or pulled until it answers as this server again (checked every 5 minutes), "
                        + "or you change the server in Settings.", tone: .danger, id: "sync.mismatchBanner")
                Button("Check again") { Task { await environment.sync.checkIdentityAgain() } }
                    .accessibilityIdentifier("sync.checkIdentity")
            }
            if !model.online {
                banner(
                    "You’re offline",
                    "Entries are kept on this device and sync automatically when the connection is back.",
                    tone: .warn, id: "sync.offlineBanner")
            }
            Section {
                header(model)
            }
            if !model.rows.isEmpty {
                Section {
                    // Keyed by store too: a row's state (a pending discard) never carries over to
                    // another store's item with the same id.
                    ForEach(Array(model.rows.enumerated()), id: \.element.scopedId) { index, row in
                        SyncItemRowView(row: row, index: index, open: open, perform: perform)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await environment.sync.refresh() }
    }

    private func header(_ model: SyncSheetModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.headline)
                .font(.qr(.body))
                .accessibilityIdentifier("sync.headline")
            Text(lastSync(model.lastSyncAt))
                .font(.qr(.footnote))
                .foregroundStyle(Color.qr.inkSoft)
                .accessibilityIdentifier("sync.lastSynced")
            if model.canSyncNow {
                Button {
                    syncing = true
                    Task {
                        await environment.sync.syncNow()
                        syncing = false
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.qr(.primary, size: .small))
                .disabled(!model.online || syncing)
                .accessibilityIdentifier("sync.syncNow")
            }
        }
        .padding(.vertical, 4)
    }

    private func lastSync(_ date: Date?) -> String {
        guard let date else { return "Not synced yet" }
        if Date.now.timeIntervalSince(date) < 60 { return "Last synced just now" }
        return "Last synced \(date.formatted(.relative(presentation: .named)))"
    }

    private func banner(_ title: String, _ text: String, tone: QuickrTone, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.qr(.label))
            Text(text).font(.qr(.footnote))
        }
        .foregroundStyle(tone.foreground)
        .listRowBackground(tone.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                problem =
                    (error as? OutboxError)?.description ?? (error as? SyncActionError)?.description
                    ?? String(describing: error)
            }
        }
    }
}

/// One item: what it is, when, its status, and its actions. Discard asks first ("Discard for
/// good"), as in the PWA.
private struct SyncItemRowView: View {
    let row: SyncItemRow
    let index: Int
    let open: (Route) -> Void
    let perform: (@escaping () async throws -> Void) -> Void
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.qr(.label)).accessibilityIdentifier("sync.row.\(index).title")
                    Text(row.when.formatted(date: .abbreviated, time: .shortened))
                        .font(.qr(.caption))
                        .foregroundStyle(Color.qr.inkSoft)
                    Text(row.status)
                        .font(.qr(.subheadline))
                        .foregroundStyle(row.tone == .failed ? Color.qr.danger : Color.qr.inkSoft)
                        .accessibilityIdentifier("sync.row.\(index).status")
                }
            }
            .accessibilityElement(children: .combine)
            // On the summary only: on the row it would replace its buttons' identifiers.
            .accessibilityIdentifier("sync.row.\(index)")
            actions
        }
        .padding(.vertical, 4)
    }

    private var icon: some View {
        let failed = row.tone == .failed
        return (failed ? QIcon.alert : QIcon.clock).view(size: 16)
            .foregroundStyle(failed ? Color.white : Color.qr.info)
            .frame(width: 28, height: 28)
            .background(failed ? Color.qr.danger : Color.qr.infoSoft, in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        // Wraps at large text sizes instead of squeezing.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var buttons: some View {
        if confirmingDiscard {
            Button("Keep") { confirmingDiscard = false }
                .buttonStyle(.qr(.ghost, size: .small))
                .accessibilityIdentifier("sync.row.\(index).keep")
            Button("Discard for good") {
                confirmingDiscard = false
                perform { try await environment.sync.discard(row) }
            }
            .buttonStyle(.qr(.danger, size: .small))
            .accessibilityIdentifier("sync.row.\(index).discardConfirm")
        } else {
            if row.canDismiss {
                Button("Dismiss") { perform { try await environment.sync.dismiss(row) } }
                    .buttonStyle(.qr(.secondary, size: .small))
                    .accessibilityIdentifier("sync.row.\(index).dismiss")
            }
            if row.canDiscard {
                Button("Discard") { confirmingDiscard = true }
                    .buttonStyle(.qr(.quietDanger, size: .small))
                    .accessibilityIdentifier("sync.row.\(index).discard")
            }
            if row.fix != nil {
                Button {
                    perform { open(try environment.sync.fixRoute(row)) }
                } label: {
                    Label("Fix", systemImage: "pencil")
                }
                .buttonStyle(.qr(.primary, size: .small))
                .accessibilityIdentifier("sync.row.\(index).fix")
            }
            if row.canRetry {
                Button {
                    perform { try await environment.sync.retry(row) }
                } label: {
                    Label(row.retryTitle, systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.qr(row.tone == .failed ? .secondary : .primary, size: .small))
                .accessibilityIdentifier("sync.row.\(index).retry")
            }
        }
    }
}
