#if DEBUG
import Foundation
import QuickrData
import Synchronization
import os

/// `-QuickrDProbe d8|d9` (DEBUG only): checkpoint D's category probe from the app's side
/// (`DeviceProbe`; docs/ios/demo/DEVICE-DAY.md D8, D9). A normal launch never runs it, and drops
/// any request an abandoned probe left (`Files.cancelPending`).
///
/// - `d9`: times the app's registrations, then writes the request the NSE takes on the next test
///   push, so the two sides never overlap.
/// - `d8`: writes the request at once, then waits (up to 3 minutes) for the NSE, which a test push
///   starts, and drives the rounds. Keep the app in front while it runs.
///
/// Until the NSE's side is done too, the app's own category registrations are held back
/// (`gatedCenter`), so nothing replaces the probe's set mid-run; the probe restores the real set
/// when it ends, and the app registers normally again after that.
/// Results go to the App Group's `Library/quickr/dprobe/results.jsonl`.
enum DeviceProbeLaunch {
    static let argument = "-QuickrDProbe"
    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "dprobe")
    /// Whether the app's own registrations are held back: from launch until the probe is over.
    fileprivate static let holding = Mutex(requested() != nil)

    /// The probe this launch asks for, if any.
    static func requested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> DeviceProbe.Kind? {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return DeviceProbe.Kind(rawValue: arguments[index + 1])
    }

    /// The app's category center for a probe launch: the system's, holding back registrations
    /// while the probe runs.
    static func gatedCenter() -> any NotificationCenterProtocol { GatedCenter(inner: SystemNotificationCenter()) }

    static func startIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let location = try? StoreLocation.appGroup("group.com.bahumia.quickr") else {
            if requested(arguments) != nil { log.error("dprobe: no App Group container") }
            return
        }
        let files = DeviceProbe.Files(location: location)
        guard let kind = requested(arguments) else {
            files.cancelPending()
            return
        }
        let request = DeviceProbe.Request(kind: kind)
        let center = SystemNotificationCenter()
        let runner = DeviceProbeRunner(files: files, process: .app, center: center) {
            await DeviceProbe.restore(location: location, center: center)
        }
        log.notice("dprobe \(kind.rawValue, privacy: .public) run \(request.run, privacy: .public) starting")
        Task.detached {
            defer {
                Task.detached {
                    holding.withLock { $0 = false }
                    // The app's own registrations held back meanwhile are in its registry: register
                    // the whole table now, unless a newer probe has the set.
                    await files.unlessAnotherRun(request.run) {
                        _ = await DeviceProbe.restore(location: location, center: center)
                    }
                }
            }
            do {
                if kind == .d8 { try files.write(request) }
                await runner.run(request)
                if kind == .d9 { try files.write(request) }
                log.notice("dprobe \(kind.rawValue, privacy: .public): the app's side is done")
            } catch {
                log.error("dprobe: \(String(describing: error), privacy: .public)")
                return
            }
            // Hold the app's registrations until the NSE's side is done too, or can't start any more.
            let limit = Date().addingTimeInterval(DeviceProbe.requestLifetime + 30)
            while Date() < limit,
                !files.records().contains(where: { $0.run == request.run && $0.process == .nse && $0.event == "done" })
            {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// The system's center, dropping the app's `setNotificationCategories` while a probe runs.
private struct GatedCenter: NotificationCenterProtocol {
    let inner: any NotificationCenterProtocol

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        guard !DeviceProbeLaunch.holding.withLock({ $0 }) else { return }
        inner.setNotificationCategories(categories)
    }

    func notificationCategories() async -> [NotificationCategorySpec] { await inner.notificationCategories() }
    func deliveredNotifications() async -> [NotificationSnapshot] { await inner.deliveredNotifications() }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        inner.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func pendingNotificationRequests() async -> [NotificationSnapshot] { await inner.pendingNotificationRequests() }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        inner.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func add(_ request: LocalNotificationRequest) async throws { try await inner.add(request) }
    func setBadgeCount(_ count: Int) async throws { try await inner.setBadgeCount(count) }
    func authorizationStatus() async -> NotificationAuthorization { await inner.authorizationStatus() }
    func requestAuthorization() async throws -> Bool { try await inner.requestAuthorization() }
}
#endif
