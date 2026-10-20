import BackgroundTasks
import Foundation
import QuickrData
import Synchronization

/// `BGAppRefreshTask` `com.bahumia.quickr.refresh` (Info.plist `BGTaskSchedulerPermittedIdentifiers`,
/// `UIBackgroundModes: fetch`): the system wakes the app now and then to pull and send
/// (sync-protocol.md §9, outbox.md §10). Registered in `QuickRApp.init` (before launch ends);
/// scheduled whenever the app goes to the background and after each run.
///
/// To run it in the simulator, pause in the debugger after backgrounding the app and run
/// `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.bahumia.quickr.refresh"]`,
/// then continue. UI tests use the debug controls' "Background refresh", which runs the same
/// handler with a stand-in task.
enum BackgroundRefresh {
    static let identifier = "com.bahumia.quickr.refresh"
    /// The earliest the system should run the next one; it decides when.
    static let interval: TimeInterval = 15 * 60

    @MainActor static func register(_ environment: AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let refresh = SystemRefreshTask(task)
            Task { @MainActor in await environment.backgroundRefresh(refresh) }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)  // simulator without the capability, or too many requests
    }
}

/// What the refresh handler needs from the system task (a seam for tests and the debug path).
protocol BackgroundRefreshTask: AnyObject, Sendable {
    /// Called by the system when the time is up.
    func onExpiration(_ handler: @escaping @Sendable () -> Void)
    func complete(success: Bool)
}

/// A `BGTask`, completed at most once.
final class SystemRefreshTask: BackgroundRefreshTask, @unchecked Sendable {
    private let task: BGTask
    private let completed = Mutex(false)

    init(_ task: BGTask) { self.task = task }

    func onExpiration(_ handler: @escaping @Sendable () -> Void) { task.expirationHandler = handler }

    func complete(success: Bool) {
        let first = completed.withLock { done in
            defer { done = true }
            return !done
        }
        if first { task.setTaskCompleted(success: success) }
    }
}
