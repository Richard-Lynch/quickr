import QuickrData
import UserNotifications

/// M0 placeholder: delivers the notification unchanged. Dedupe, badge and category
/// registration arrive in M3 (docs/ios/specs/notifications.md). In DEBUG builds the SPIKE
/// registers the payload's category through the registry table first (§6), to measure whether
/// a category the NSE registers applies to the notification it is preparing.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        #if DEBUG
        let delivery = SpikeDelivery(content: request.content, handler: contentHandler)
        Task {
            delivery.deliver(await Self.spikePrepare(delivery.content))
        }
        #else
        contentHandler(request.content)
        #endif
    }

    #if DEBUG
    private static func spikePrepare(_ content: UNNotificationContent) async -> SpikeDelivery.Content {
        let started = Date()
        SpikeLog.append("nse.start", ["category": content.categoryIdentifier])
        guard let row = SpikeCategories.row(userInfo: content.userInfo), let location = SpikeLog.location else {
            SpikeLog.append("nse.untouched")
            return SpikeDelivery.Content(content)
        }
        do {
            let registry = try Registry.open(at: location, notifier: DarwinNotifier())
            _ = try await SpikeCategories.reconcile(registry: registry)
            let ids = try await SpikeCategories.register([row], registry: registry)
            let best = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
            best.categoryIdentifier = row.id
            SpikeLog.append(
                "nse.registered",
                [
                    "category": row.id, "registered": String(ids.count),
                    "ms": String(Int(-started.timeIntervalSinceNow * 1000)),
                ])
            return SpikeDelivery.Content(best)
        } catch {
            SpikeLog.append("nse.failed", ["error": String(describing: error)])
            return SpikeDelivery.Content(content)
        }
    }
    #endif
}

#if DEBUG
/// The request's content and the content handler, carried into the task (UserNotifications
/// doesn't mark them Sendable; the task is their only user).
private struct SpikeDelivery: @unchecked Sendable {
    struct Content: @unchecked Sendable {
        let value: UNNotificationContent

        init(_ value: UNNotificationContent) { self.value = value }
    }

    let content: UNNotificationContent
    let handler: (UNNotificationContent) -> Void

    func deliver(_ prepared: Content) { handler(prepared.value) }
}
#endif
