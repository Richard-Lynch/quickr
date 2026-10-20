import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import UIKit

/// "Export CSV" on a topic's entries (the PWA's, beside the filters): the server's CSV of the
/// entries the list's filters select, through the share sheet. Online only: offline it says so
/// and sends nothing. The export belongs to the store bound when it started: leaving the screen
/// cancels it, and one that finishes after a server switch is deleted, never shared. Its file is
/// removed once its share sheet closes.
struct EntriesExportButton: View {
    let session: AppSession
    let slug: String
    let filters: EntryListFilters
    @Environment(AppEnvironment.self) private var environment
    @State private var running: Task<Void, Never>?
    private let export = EntriesExport()

    var body: some View {
        Button {
            running = Task { await run() }
        } label: {
            HStack(spacing: 6) {
                if running != nil {
                    ProgressView().controlSize(.small)
                } else {
                    QIcon.download.view(size: 16, weight: .bold)
                }
                Text("Export CSV")
            }
        }
        .buttonStyle(.qr(.secondary, size: .small))
        .disabled(running != nil)
        .accessibilityHint("Shares these entries as a CSV file")
        .accessibilityIdentifier("entries.export")
        .onDisappear {
            running?.cancel()
            running = nil
        }
    }

    private func run() async {
        defer { running = nil }
        guard environment.sync.online else {
            showOffline()
            return
        }
        let store = session.store
        guard
            let scope = await EntriesExport.scope(
                binding: session.binding,
                context: {
                    guard let store else { throw AppSession.SessionError.noStore }
                    return try await store.requestContext()
                })
        else {
            _ = environment.toasts.show(
                Toast("Couldn’t export", message: EntriesExport.notReadyMessage, tone: .danger))
            return
        }
        let now = Date()
        let session = session
        let outcome = await export.export(
            scope: scope, transport: session.configuration.transport, credentials: session.configuration.credentials,
            slug: slug, filters: EntriesExport.filters(filters, now: now, calendar: .current), now: now,
            calendar: .current, isCurrent: { session.binding == scope.binding })
        switch outcome {
        case .file(let file):
            SharePresenter.share(file.url) { file.remove() }
        case .offline:
            showOffline()
        case .failed(let message):
            _ = environment.toasts.show(Toast("Couldn’t export", message: message, tone: .danger))
        case .discarded:
            break
        }
    }

    private func showOffline() {
        _ = environment.toasts.show(
            Toast(EntriesExport.offlineTitle, message: EntriesExport.offlineMessage, tone: .info))
    }
}

/// The system share sheet for a file, over whatever is on screen; `done` runs once it closes.
@MainActor
enum SharePresenter {
    static func share(_ url: URL, done: @escaping @MainActor () -> Void) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard var top = window?.rootViewController else {
            done()
            return
        }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in done() }
        }
        // iPad: a popover from the middle of the window.
        if let popover = sheet.popoverPresentationController, let window {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}
