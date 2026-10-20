import Foundation
import QuickrCore
import QuickrData
import QuickrUI

/// The record screen's toasts, on the app's one `ToastCenter` so they outlive the screen. Undo is
/// tied to the store the entry went to: after a server switch or a reset it does nothing there.
/// (TILES' `EntryToasts` takes over once it lands; the texts follow the PWA's.)
@MainActor
final class RecordToasts: RecordNotices {
    let center: ToastCenter
    let session: AppSession

    init(center: ToastCenter, session: AppSession) {
        self.center = center
        self.session = session
    }

    func logged(entryId: UUID, topic: Topic, sent: Bool) {
        let scope = session.binding.map(Self.scope)
        center.show(
            Toast(
                sent ? "Logged \(topic.name)" : "Saved on this device",
                message: sent ? nil : "It will sync automatically when you’re back online.",
                tone: sent ? .ok : .info,
                action: Toast.Action("Undo") { [weak self] in
                    Task { await self?.undo(entryId, topic: topic, scope: scope) }
                }))
    }

    func fixed(topic: Topic, sent: Bool) {
        center.show(
            Toast(
                sent ? "Logged \(topic.name)" : "Saved on this device",
                message: sent ? nil : "It will sync automatically when you’re back online.", tone: sent ? .ok : .info))
    }

    func failed(topic: Topic, _ failure: RecordFailure) {
        switch failure {
        case .notSaved:
            center.show(Toast("Not saved", message: "This entry was deleted, so it won’t be recorded.", tone: .danger))
        case .message(let message):
            center.show(Toast("Couldn’t log \(topic.name)", message: message, tone: .danger))
        }
    }

    private func undo(_ entryId: UUID, topic: Topic, scope: String?) async {
        guard let scope, session.binding.map(Self.scope) == scope else {
            center.show(
                Toast("Couldn’t undo", message: "The server changed since then. Nothing was undone.", tone: .danger))
            return
        }
        do {
            switch try await session.undoLog(entryId: entryId) {
            case .removed, .deleteQueued:
                center.show(Toast("Undone", message: "\(topic.name) entry removed.", tone: .info))
            case .nothingToDo:
                center.show(Toast("Nothing to undo", message: "This entry was already removed.", tone: .info))
            }
        } catch {
            center.show(
                Toast("Couldn’t undo", message: "\(error) — delete it from \(topic.name) › Entries.", tone: .danger))
        }
    }

    /// The store: server and generation (not the address: a new address keeps the same store).
    static func scope(_ binding: AppSession.Binding) -> String { "\(binding.serverId)/\(binding.storeGen)" }
}
