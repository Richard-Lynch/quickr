#if DEBUG
import Foundation
import Observation
import QuickrCore
import QuickrData
import SwiftUI
import UIKit
import UserNotifications

// SPIKE (M1): a notification action logs from a killed app (notifications.md §7.1, outbox.md §10).
// DEBUG only, and inert unless the app is launched with `-spikeServer`: it doesn't ship and
// doesn't change the app's normal launch. HANDLER (M3) replaces it; findings in
// docs/ios/demo/m1/spike-findings.md.

/// Launch arguments: `-spikeServer <base URL>` connects the app to a server (§2.1 bootstrap);
/// `-spikeRegister <base64 JSON array of APNs payloads>` registers their categories from the app
/// (as CAT will after a sync), before any notification arrives.
struct SpikeConfiguration: Sendable {
    var serverURL: URL
    /// The JSON array of payloads.
    var payloads: Data?

    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SpikeConfiguration? {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let server = value("-spikeServer").flatMap(URL.init(string:)) else { return nil }
        return SpikeConfiguration(
            serverURL: server, payloads: value("-spikeRegister").flatMap { Data(base64Encoded: $0) })
    }
}

/// What the spike shows on screen for the UI test ("spike: ready …").
@MainActor @Observable
final class SpikeStatus {
    static let shared = SpikeStatus()
    var text = ""
}

struct SpikeStatusView: View {
    @State private var status = SpikeStatus.shared

    var body: some View {
        if !status.text.isEmpty {
            Text(status.text)
                .font(.caption.monospaced())
                .padding(8)
                .background(.thinMaterial, in: .rect(cornerRadius: 8))
                .accessibilityIdentifier("spike.status")
        }
    }
}

/// The app delegate the spike needs: the notification center's delegate must be set before
/// `didFinishLaunching` returns, or an action that launches the app in the background is lost.
final class SpikeAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SpikeLog.append("app.launch", ["state": application.applicationState.spikeName])
        if let configuration = SpikeConfiguration.fromArguments() {
            Task { await SpikeSetup.run(configuration) }
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await SpikeHandler.handle(response)
    }
}

/// Connect, then register the given categories through the registry table (§5.2).
enum SpikeSetup {
    static func run(_ configuration: SpikeConfiguration) async {
        await show("spike: connecting")
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
                .alert, .sound, .badge,
            ])
            guard let location = SpikeLog.location else { throw SpikeError("no App Group container") }
            let partitions = try StorePartitions.open(at: location)
            var settings = SyncCoordinator.Configuration()
            settings.autoRetry = false
            let coordinator = SyncCoordinator(
                partitions: partitions, feed: { url in SpikeHandler.client(url) }, flush: NoSyncSideEffects(),
                owner: "app:spike", configuration: settings)
            let connected = await coordinator.connect(baseURL: configuration.serverURL)
            guard case .connected(let serverId, _, .synced) = connected else {
                throw SpikeError("connect: \(connected)")
            }
            let payloads =
                configuration.payloads.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let rows = payloads.compactMap { SpikeCategories.row(userInfo: $0) }
            let ids = try await SpikeCategories.register(rows, registry: partitions.registry)
            SpikeLog.append(
                "app.ready",
                ["server": serverId, "categories": ids.joined(separator: ","), "authorized": String(granted)])
            await show("spike: ready \(ids.count) categories")
        } catch {
            SpikeLog.append("app.setup-failed", ["error": String(describing: error)])
            await show("spike: failed \(error)")
        }
    }

    @MainActor private static func show(_ text: String) { SpikeStatus.shared.text = text }
}

/// §7.1, the parts the spike proves: validate the action against `userInfo`, find the server's
/// store through the registry, one `IMMEDIATE` enqueue, remove the delivered reminders, then a
/// forced flush with the notification action's 5 s budget (outbox.md §10).
enum SpikeHandler {
    static func client(_ url: URL) -> APIClient {
        APIClient(
            baseURL: url, transport: URLSessionTransport(), identity: StaticServerIdentity(nil), origin: .notification)
    }

    static func handle(_ response: UNNotificationResponse) async {
        let started = ContinuousClock.now
        let task = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "quickr.action") }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
        let state = await MainActor.run { UIApplication.shared.applicationState.spikeName }
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        SpikeLog.append("handler.start", ["action": action, "state": state])
        guard action != UNNotificationDefaultActionIdentifier, action != UNNotificationDismissActionIdentifier else {
            return
        }
        do {
            let (info, answer) = try validate(action: action, userInfo: userInfo)
            guard let location = SpikeLog.location else { throw SpikeError("no App Group container") }
            let partitions = try StorePartitions.open(at: location)
            guard try await partitions.registry.repository.server(id: info.serverId) != nil else {
                throw SpikeError("This reminder came from a server you've removed from quickR")
            }
            let store = try await partitions.openStore(serverId: info.serverId, role: .app).store
            guard let topicId = info.topicId.flatMap(UUID.init(uuidString:)),
                let topic = try await store.topics.topic(id: topicId)?.topic,
                let state = try await store.syncState.syncState(), let baseURL = URL(string: state.baseURL)
            else { throw SpikeError("The topic isn't on this iPhone yet") }
            let outbox = Outbox(store: store, sender: client(baseURL), owner: "app:spike-handler")
            let entryId = UUID()
            let enqueued = try await outbox.createEntry(
                id: entryId, topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name),
                body: EntryCreateDTO(
                    id: nil, answers: [answer.key: .string(answer.value)], source: nil, capturedAt: Date(),
                    version: info.version),
                origin: .notification)
            SpikeLog.append(
                "handler.enqueued", ["entry": entryId.wireString, "result": "\(enqueued)", "ms": ms(since: started)])
            await removeDelivered(serverId: info.serverId, topicId: topic.id.wireString)
            let report = try await outbox.flush(force: true, budget: .seconds(5), leaseWait: .seconds(5))
            SpikeLog.append(
                "handler.flushed",
                ["ending": "\(report.ending)", "acked": String(report.acked), "ms": ms(since: started)])
        } catch {
            SpikeLog.append("handler.failed", ["error": String(describing: error), "ms": ms(since: started)])
            await fail(
                String(describing: error), topicId: (SpikeCategories.info(userInfo: userInfo)?.topicId) ?? "unknown")
        }
    }

    /// §7.1 step 1: the identifier must name this notification's server, topic, version and key,
    /// and an option its descriptor offers.
    static func validate(action: String, userInfo: [AnyHashable: Any]) throws -> (
        QuickrNotificationInfo, (key: String, value: String)
    ) {
        let parts = action.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, parts[0] == "q1", parts[5] == "o", let info = SpikeCategories.info(userInfo: userInfo),
            parts[1] == info.serverId, parts[2] == info.topicId, Int(parts[3]) == info.version,
            case .choice(let choice) = info.quickLog, parts[4] == choice.key,
            choice.options.contains(where: { $0.value == parts[6] })
        else { throw SpikeError("Couldn't log — open quickR to log") }
        return (info, (choice.key, parts[6]))
    }

    private static func removeDelivered(serverId: String, topicId: String) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().compactMap { notification -> String? in
            let info = SpikeCategories.info(userInfo: notification.request.content.userInfo)
            return info?.serverId == serverId && info?.topicId == topicId ? notification.request.identifier : nil
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private static func fail(_ message: String, topicId: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't log"
        content.body = message
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "quickr.err.\(topicId)", content: content, trigger: nil))
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15))
    }
}

struct SpikeError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) { self.description = description }
}

extension UIApplication.State {
    var spikeName: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
#endif
