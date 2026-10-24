import Foundation
import OSLog
import QuickrCore
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
        #if DEBUG
        // What an action did, for simulator runs (MediaCaptureUITests): no answers or text.
        let kind =
            switch outcome {
            case .none: "none"
            case .open: "open"
            case .logged: "logged"
            case .alreadyLogged: "already logged"
            case .started: "started"
            case .alreadyStarted: "already started"
            case .refused(let failure): "refused: \(failure)"
            case .needsFix: "needs fix"
            }
        Logger(subsystem: "com.bahumia.quickr", category: "notification-action").notice(
            "outcome: \(kind, privacy: .public)")
        #endif
        // §7.5: the reminder's server's topic, by id, and only while that server is active.
        guard case .open(let path, let serverId, let prefill) = outcome, let routes = DeepLink.routes(forPath: path)
        else { return }
        await openScoped(routes, serverId: serverId, storeGen: nil, prefill: prefill)
    }

    /// §7.2: whether a notification arriving in the foreground is shown.
    func shouldPresentNotification(_ notification: NotificationSnapshot) async -> Bool {
        guard let session else { return true }
        return await notificationHandler(session).shouldPresent(notification)
    }

    /// The tap-to-fix text for `topicId`'s record screen, once: only the active server's topic's.
    func takeRecordPrefill(topicId: UUID) -> [String: String]? {
        guard let prefill = recordPrefill, prefill.topicId == topicId.wireString,
            prefill.serverId == session?.binding?.serverId
        else { return nil }
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
                    origin: .notification, serverOffset: StoreServerOffset(store: store))
            },
            owner: LeaseClaim.owner(kind: "app", launchId: UUID()), wallClock: configuration.wallClock,
            isProtectedDataAvailable: { await UIApplication.shared.isProtectedDataAvailable },
            onSignal: session.coordinator.outboxSignalHandler,
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
            // The badge and the flush follow the session's binding, decided where it changes.
            gate: SessionActiveGate(session: session),
            // I-LA SEAM (timers.md §10.2): a Start asks for the run's Live Activity here once I-LA's
            // local start lands; until then none is requested, and the server's push-to-start shows it.
            startLiveActivity: { _ in false })
    }
}
