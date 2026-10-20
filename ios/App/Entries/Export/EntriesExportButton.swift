import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import UIKit

/// "Export CSV" on a topic's entries (the PWA's, beside the filters): the server's CSV of the
/// entries the list's filters select, through the share sheet. Online only: offline it says so
/// and sends nothing. The file is temporary, removed once the share sheet closes.
struct EntriesExportButton: View {
    let session: AppSession
    let slug: String
    let filters: EntryListFilters
    @Environment(AppEnvironment.self) private var environment
    @State private var exporting = false
    private let export = EntriesExport()

    var body: some View {
        Button {
            Task { await run() }
        } label: {
            HStack(spacing: 6) {
                if exporting {
                    ProgressView().controlSize(.small)
                } else {
                    QIcon.download.view(size: 16, weight: .bold)
                }
                Text("Export CSV")
            }
        }
        .buttonStyle(.qr(.secondary, size: .small))
        .disabled(exporting)
        .accessibilityHint("Shares these entries as a CSV file")
        .accessibilityIdentifier("entries.export")
    }

    private func run() async {
        guard environment.sync.online else {
            showOffline()
            return
        }
        guard let binding = session.binding, let store = session.store else { return }
        exporting = true
        defer { exporting = false }
        let identity = try? await store.requestContext().identity
        let client = APIClient(
            baseURL: binding.baseURL, transport: session.configuration.transport,
            identity: StaticServerIdentity(identity), credentials: session.configuration.credentials, origin: .app)
        let now = Date()
        let outcome = await export.export(
            client: client, slug: slug, filters: EntriesExport.filters(filters, now: now, calendar: .current),
            identity: identity, now: now, calendar: .current)
        switch outcome {
        case .file(let url):
            let export = export
            SharePresenter.share(url) { export.cleanUp() }
        case .offline:
            showOffline()
        case .failed(let message):
            _ = environment.toasts.show(Toast("Couldn’t export", message: message, tone: .danger))
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
