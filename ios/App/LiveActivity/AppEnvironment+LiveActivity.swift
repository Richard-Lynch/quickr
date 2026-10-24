import Foundation
import OSLog
import QuickrCore
import QuickrData
import SwiftUI
import UIKit

extension AppEnvironment {
    /// A Live Activity's buttons (timers.md §10.3). iOS runs them in this process, launching it in
    /// the background if it was killed: the session may not have started, so the tap writes
    /// through the active store, which must be the activity's server's.
    func registerLiveActivityTaps() {
        RunActivityTaps.register { [weak self] tap in
            guard let self else { throw RunActivityTaps.Failure.noHandler }
            try await self.handleActivityTap(tap)
        }
    }

    /// One tap: inside the topic's cooldown (shared with the app's controls) it does nothing, so a
    /// double tap on Pause doesn't land on the Resume that replaced it. Otherwise one `run.event`
    /// with the content state's `seg`, the activity updated at once, then a flush within the
    /// intent's budget.
    func handleActivityTap(_ tap: RunActivityTap) async throws {
        guard let session else { throw RunActivityTaps.Failure.noHandler }
        // Before first unlock the store can't be opened (timers.md §13.5 item 6).
        guard UIApplication.shared.isProtectedDataAvailable else { throw RunActivityTaps.Failure.locked }
        guard runActions.admits(topicId: tap.topicId) else { return }
        // Suspended in the background, the databases are resumed for the write.
        let hold = session.holdStoreResumed()
        defer { hold.release() }
        let store: LocalStore
        let serverId = tap.serverId.lowercased()
        if let bound = session.store, bound.serverId.lowercased() == serverId {
            store = bound
        } else if let opened = try await session.partitions.openActiveStore(role: .app)?.store,
            opened.serverId.lowercased() == serverId
        {
            store = opened
        } else {
            // Another server's activity: reconciliation ends it.
            await liveActivities.reconcile()
            return
        }
        let result = try await session.runWrites(store: store).tap(tap.tapType, runId: tap.runId, target: tap.target)
        await liveActivities.reconcile()
        if result != nil { await flushAfterActivityTap(store, session: session) }
    }

    /// Whether a run started now would be shown here: the switch is on, iOS allows activities,
    /// and the app is in the foreground (iOS refuses a request from the background, and the
    /// server's push-to-start then shows it).
    func showsLiveActivityLocally() async -> Bool {
        guard lastScenePhase == .active else { return false }
        return await liveActivities.willShowLocally()
    }

    /// The Settings switch (§10.3).
    func setLiveActivities(_ on: Bool) {
        settings.liveActivities = on
        Task { await liveActivities.setEnabled(on) }
    }

    /// Reconciles with every change to the bound store's local view of runs: a sync, an
    /// acknowledgement, a tap from another surface. Run it keyed by `session.binding`.
    func observeRunsForLiveActivities() async {
        guard let session, let store = session.store else { return }
        do {
            for try await _ in store.observeLocalRuns(refresh: session.refresh.stream()) {
                await liveActivities.reconcile()
            }
        } catch {
            // The screens' own observations report store failures.
        }
    }

    /// outbox.md §10: a forced flush within the intent's 4 s budget, by its own owner (it may run
    /// beside the session's scheduler, which is paused while the app is in the background). The
    /// run intents' too.
    func flushAfterActivityTap(_ store: LocalStore, session: AppSession) async {
        guard let state = try? await store.syncState.syncState(), let url = URL(string: state.baseURL) else {
            lastActivityTapFlush = "no server address"
            return
        }
        let configuration = session.configuration
        let sender = APIClient(
            baseURL: url, transport: configuration.transport, identity: StaticServerIdentity(nil),
            credentials: configuration.credentials, origin: .app, serverOffset: StoreServerOffset(store: store))
        let outbox = Outbox(
            store: store, sender: sender, owner: LeaseClaim.owner(kind: "app", launchId: UUID()),
            onSignal: session.coordinator.outboxSignalHandler)
        let budget = activityTapFlushBudget
        do {
            lastActivityTapFlush = "\(try await outbox.flush(force: true, budget: budget, leaseWait: budget).ending)"
        } catch {
            lastActivityTapFlush = "error: \(error)"
        }
    }

    /// I-NOTIF's seam (timers.md §10.2): whether a reminder's Start will show its run here, asked
    /// before the start is written (its `device.live_activity`). Prompt: no request is made here.
    /// The request follows the write (`notificationRunStarted`), from the run as written, whose
    /// start is stamped from `start.startedAt`.
    func liveActivityForNotificationStart(_ start: NotificationRunStart) async -> Bool {
        await showsLiveActivityLocally()
    }

    /// After the handler's `.started`: the local request for the run it started, once per
    /// (server, topic) (an activity already showing the topic is updated instead). The run's
    /// start is the tap (`NotificationRunStart.startedAt` stamps it), so the activity's clock is.
    /// Another server's start isn't shown here.
    func notificationRunStarted(runId: String, serverId: String) async {
        guard let session, serverId.lowercased() == session.binding?.serverId.lowercased(),
            let store = session.store,
            let run = try? await store.writer.read({ db in try RunOverlay.localRun(db, id: runId) })
        else { return }
        await liveActivities.reconcile(startFor: run.topicId)
    }
}

/// `UserDefaults` for the token bookkeeping's closures (it is thread-safe).
struct UncheckedDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) { self.value = value }
}

/// The session, for the Live Activity closures built before `AppEnvironment.init` finishes.
@MainActor
final class SessionBox {
    weak var environment: AppEnvironment?

    private var session: AppSession? { environment?.session }

    /// The active store's local view: the bound store's, or before the session binds (a button
    /// launched the app in the background) the active one.
    func activitySnapshot() async -> RunActivitySnapshot? {
        guard let store = await activeStore() else { return nil }
        return (try? await RunActivitySnapshot.read(store)) ?? nil
    }

    /// The active store: the bound one, or before the session binds the registry's active one.
    private func activeStore() async -> LocalStore? {
        guard let session else { return nil }
        if let bound = session.store { return bound }
        return (try? await session.partitions.openActiveStoreIfExists()) ?? nil
    }

    /// The active server's API, for the tokens: from its store's address, so it works before the
    /// session binds (an activity push-to-start brought in the background).
    func liveActivityClient() async -> APIClient? {
        guard let session, let store = await activeStore(),
            let state = try? await store.syncState.syncState(), let url = URL(string: state.baseURL)
        else { return nil }
        let configuration = session.configuration
        return APIClient(
            baseURL: url, transport: configuration.transport, identity: StaticServerIdentity(nil),
            credentials: configuration.credentials, origin: .app, serverOffset: StoreServerOffset(store: store))
    }

    /// The active server's id, lowercase.
    func activeServerId() async -> String? { await activeStore()?.serverId.lowercased() }

    /// This phone's APNs token, once the system gave one.
    func apnsToken() async -> String? {
        guard let session else { return nil }
        return (try? await session.partitions.registry.repository.apnsToken()) ?? nil
    }
}
