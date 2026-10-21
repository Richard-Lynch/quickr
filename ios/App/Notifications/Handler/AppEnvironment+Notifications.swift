import Foundation
import QuickrData
import UIKit
import WidgetKit

extension AppEnvironment {
    /// A notification response (notifications.md §7): actions log through the handler, over the
    /// session's stores (the reminder's server's, active or not); a body tap opens its path, with
    /// a tap-to-fix's text kept for the record screen.
    func handleNotificationResponse(_ response: NotificationActionResponse) async {
        guard let session else { return }
        // `NotificationResponder` holds the store resumed around this (a tap while suspended).
        let outcome = await notificationHandler(session).handle(response)
        guard case .open(let path, let prefill) = outcome else { return }
        recordPrefill = prefill
        router.handle(path: path)
    }

    /// §7.2: whether a notification arriving in the foreground is shown.
    func shouldPresentNotification(_ notification: NotificationSnapshot) async -> Bool {
        guard let session else { return true }
        return await notificationHandler(session).shouldPresent(notification)
    }

    /// The tap-to-fix text for `topicId`'s record screen, once.
    func takeRecordPrefill(topicId: UUID) -> [String: String]? {
        guard let prefill = recordPrefill, prefill.topicId == topicId.wireString else { return nil }
        recordPrefill = nil
        return prefill.texts
    }

    /// The handler, sending each store's outbox to that store's server with its Access token.
    /// Its own `flush` owner: it may run beside the session's scheduler in this process.
    private func notificationHandler(_ session: AppSession) -> NotificationActionHandler {
        let configuration = session.configuration
        let (transport, credentials) = (configuration.transport, configuration.credentials)
        return NotificationActionHandler(
            partitions: session.partitions, center: configuration.categoryCenter ?? SystemNotificationCenter(),
            sender: { store in
                guard let state = try? await store.syncState.syncState(), let url = URL(string: state.baseURL)
                else { return nil }
                return APIClient(
                    baseURL: url, transport: transport, identity: StaticServerIdentity(nil), credentials: credentials,
                    origin: .notification)
            },
            owner: LeaseClaim.owner(kind: "app", launchId: UUID()), wallClock: configuration.wallClock,
            isProtectedDataAvailable: { await UIApplication.shared.isProtectedDataAvailable },
            onSignal: session.coordinator.outboxSignalHandler,
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
            // The badge and the flush follow the session's binding, decided where it changes.
            gate: SessionActiveGate(session: session))
    }
}
