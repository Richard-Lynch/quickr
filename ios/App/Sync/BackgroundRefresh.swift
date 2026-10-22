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
/// then continue (without a debugger the simulator's scheduler launches nothing: `submit` fails as
/// unavailable). `SyncControllerTests` calls the registered launch handler off the main thread,
/// as the system does.
enum BackgroundRefresh {
    static let identifier = "com.bahumia.quickr.refresh"
    /// The earliest the system should run the next one; it decides when.
    static let interval: TimeInterval = 15 * 60

    /// The launch handler is `@Sendable`, so not isolated to the main actor: the system calls it
    /// on a queue of its own, where a main-actor closure fails Swift 6's isolation check and traps
    /// (TestFlight 0.1.0 (20261021.194105), a crash on every background refresh). It only hops.
    /// - Parameter scheduler: tests pass a subclass that keeps the handler.
    @MainActor static func register(_ environment: AppEnvironment, scheduler: BGTaskScheduler = .shared) {
        scheduler.register(forTaskWithIdentifier: identifier, using: nil) { @Sendable task in
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

/// A `BGTask`, completed at most once. Its expiration handler is installed at once, in the
/// launch handler on the scheduler's queue: the time can run out before the refresh reaches a
/// busy main actor (a background launch still starting), and a task that expires with no handler
/// gets the app killed. Expired before `onExpiration`, it completes unsuccessfully right there
/// (nothing has started), and the handler given later runs as soon as it is given.
final class SystemRefreshTask: BackgroundRefreshTask, @unchecked Sendable {
    private struct State {
        var completed = false
        var expired = false
        var handler: (@Sendable () -> Void)?
    }

    private let task: BGTask
    private let state = Mutex(State())

    init(_ task: BGTask) {
        self.task = task
        // Weak: the task holds its handler; by the time this is gone, the task has completed.
        task.expirationHandler = { [weak self] in self?.expire() }
    }

    func onExpiration(_ handler: @escaping @Sendable () -> Void) {
        let expired = state.withLock { state in
            state.handler = handler
            return state.expired
        }
        if expired { handler() }
    }

    func complete(success: Bool) {
        let first = state.withLock { state in
            defer { state.completed = true }
            return !state.completed
        }
        if first { task.setTaskCompleted(success: success) }
    }

    private func expire() {
        let handler = state.withLock { state in
            state.expired = true
            return state.handler
        }
        if let handler { handler() } else { complete(success: false) }
    }
}
