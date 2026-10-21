#if DEBUG
import Foundation
import OSLog
import QuickrCore
@_spi(Testing) import QuickrData

/// `-QuickrDemoNotify <slug> [seconds]` (with `-QuickrDemoStore`): a due reminder for the demo
/// topic `<slug>`, as the server would push it (`DueReminder`, checked against apns.render's
/// vectors), delivered as a local notification after `seconds` (default 5). Its category is
/// registered first, so the simulator shows the real actions (the NSE never runs for `simctl
/// push`, spike F1) and they log through the real handler. Add `-QuickrDemoShared` when an action
/// may launch the app afresh (without these arguments), so it finds the demo store. For the
/// milestone screenshots and MediaCaptureUITests. Asks for notification permission; debug only.
enum DemoNotify {
    static let argument = "-QuickrDemoNotify"

    /// The slug and delay the launch asked for, or nil.
    static var requested: (slug: String, seconds: Double)? {
        let args = ProcessInfo.processInfo.arguments
        guard DemoStore.isRequested, let i = args.firstIndex(of: argument), i + 1 < args.count else { return nil }
        let seconds = i + 2 < args.count ? Double(args[i + 2]) : nil
        return (args[i + 1], max(1, seconds ?? 5))
    }

    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "demo-notify")

    /// Registers `<slug>`'s category and schedules its reminder, once the demo session is up.
    /// Bounded: gives up (logging why) after 20 s without a session.
    @MainActor static func schedule(_ environment: AppEnvironment) async {
        guard let (slug, seconds) = requested else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while environment.session?.store == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let session = environment.session, let store = session.store else {
            return log.error("no demo session within 20 s: nothing scheduled")
        }
        do {
            guard let topic = try await session.topics.topic(slug: slug)?.topic else {
                return log.error("no demo topic \(slug, privacy: .public)")
            }
            let center = SystemNotificationCenter()
            // The category the session registers for the topic (NotificationCategories.rows), put
            // into the system's set now rather than whenever the session's refresh gets to it.
            let row = try await NotificationCategories.rows(in: store).first { $0.topicId == topic.id.wireString }
            if let row {
                try await NotificationCategories(
                    registry: session.partitions.registry, center: center, wallClock: session.configuration.wallClock
                ).register([row])
            }
            let granted = try await center.requestAuthorization()
            let request = DueReminder.request(
                serverId: store.serverId, topic: topic, category: row?.category, now: Date(),
                fireDate: Date().addingTimeInterval(seconds))
            try await center.add(request)
            log.notice(
                """
                scheduled \(request.id, privacy: .public) in \(seconds) s, category \
                \(request.categoryIdentifier ?? "none", privacy: .public), permission \(granted)
                """)
        } catch {
            log.error("demo reminder failed: \(error, privacy: .public)")
        }
    }
}
#endif
