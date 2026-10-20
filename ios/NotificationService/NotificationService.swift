import Foundation
import QuickrData
import Synchronization
import UserNotifications

/// `QuickRNotificationService` (notifications.md §6): prepares a reminder before it is shown, with
/// `NotificationPreparation` (QuickrData): the local fallback's duplicates cancelled, its category
/// registered and set, an already-logged slot said so, the badge from the active store, older
/// reminders for the topic removed. No network and no outbox; the active store is read-only.
/// When the time runs out (`serviceExtensionTimeWillExpire`), the preparation is cancelled (it
/// makes no further changes) and the notification goes out untouched.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: Delivery?
    private var preparing: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let delivery = Delivery(content: request.content, handler: contentHandler)
        self.delivery = delivery
        let incoming = NotificationPreparation.Incoming(
            id: request.identifier, body: request.content.body,
            categoryIdentifier: request.content.categoryIdentifier,
            quickr: QuickrNotificationInfo(userInfo: request.content.userInfo))
        guard let preparation = Self.preparation else {
            delivery.deliver(nil)
            return
        }
        preparing = Task { @Sendable in
            let prepared = await preparation.prepare(incoming)
            delivery.deliver(Task.isCancelled ? nil : prepared)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        preparing?.cancel()
        delivery?.deliver(nil)
    }

    /// The App Group's files, opened once per extension process; nil without the App Group (the
    /// notification then goes out untouched).
    private static let preparation: NotificationPreparation? = {
        guard let location = try? StoreLocation.appGroup("group.com.bahumia.quickr") else { return nil }
        let stores = ReadOnlyStores(location: location)
        let registry = Mutex<Registry?>(nil)
        return NotificationPreparation(
            center: SystemNotificationCenter(),
            registry: {
                // Retried on the next push when it failed (before first unlock).
                try registry.withLock { cached in
                    if let cached { return cached }
                    let opened = try Registry.open(at: location, notifier: DarwinNotifier())
                    cached = opened
                    return opened
                }
            },
            activeStore: { try stores.activeStore() })
    }()
}

/// The request's content and the content handler, called once: with the prepared changes, or
/// untouched (nil) when the time ran out first. UserNotifications doesn't mark them Sendable; this
/// is their only user.
private final class Delivery: @unchecked Sendable {
    private let content: UNNotificationContent
    private let handler: (UNNotificationContent) -> Void
    private let done = Mutex(false)

    init(content: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    func deliver(_ prepared: NotificationPreparation.Prepared?) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        guard let prepared, let best = content.mutableCopy() as? UNMutableNotificationContent else {
            handler(content)
            return
        }
        best.body = prepared.body
        best.categoryIdentifier = prepared.categoryIdentifier
        if let badge = prepared.badge { best.badge = NSNumber(value: badge) }
        handler(best)
    }
}
