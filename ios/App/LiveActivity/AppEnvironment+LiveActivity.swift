import Foundation
import OSLog
import QuickrCore
import QuickrData
import SwiftUI

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
        guard runActions.admits(topicId: tap.topicId) else { return }
        // Suspended in the background, the databases are resumed for the write.
        let hold = session.holdStoreResumed()
        defer { hold.release() }
        let store: LocalStore
        if let bound = session.store, bound.serverId == tap.serverId {
            store = bound
        } else if let opened = try await session.partitions.openActiveStore(role: .app)?.store,
            opened.serverId == tap.serverId
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
    /// beside the session's scheduler, which is paused while the app is in the background).
    private func flushAfterActivityTap(_ store: LocalStore, session: AppSession) async {
        guard let state = try? await store.syncState.syncState(), let url = URL(string: state.baseURL) else { return }
        let configuration = session.configuration
        let sender = APIClient(
            baseURL: url, transport: configuration.transport, identity: StaticServerIdentity(nil),
            credentials: configuration.credentials, origin: .app, serverOffset: StoreServerOffset(store: store))
        let outbox = Outbox(
            store: store, sender: sender, owner: LeaseClaim.owner(kind: "app", launchId: UUID()),
            onSignal: session.coordinator.outboxSignalHandler)
        let budget = Self.activityTapFlushBudget
        _ = try? await outbox.flush(force: true, budget: budget, leaseWait: budget)
    }

    static let activityTapFlushBudget: Duration = .seconds(4)
}

/// The session, for the Live Activity closures built before `AppEnvironment.init` finishes.
@MainActor
final class SessionBox {
    weak var environment: AppEnvironment?

    private var session: AppSession? { environment?.session }

    /// The active store's local view: the bound store's, or before the session binds (a button
    /// launched the app in the background) the active one.
    func activitySnapshot() async -> RunActivitySnapshot? {
        guard let session else { return nil }
        let opened: LocalStore?
        if let bound = session.store {
            opened = bound
        } else {
            opened = (try? await session.partitions.openActiveStoreIfExists()) ?? nil
        }
        guard let store = opened else { return nil }
        return try? await RunActivitySnapshot.read(store)
    }

    /// The bound server's API, for the tokens.
    func liveActivityClient() -> APIClient? {
        guard let session, let binding = session.binding, let store = session.store else { return nil }
        let configuration = session.configuration
        return APIClient(
            baseURL: binding.baseURL, transport: configuration.transport, identity: StaticServerIdentity(nil),
            credentials: configuration.credentials, origin: .app, serverOffset: StoreServerOffset(store: store))
    }

    /// This phone's APNs token, once the system gave one.
    func apnsToken() async -> String? {
        guard let session else { return nil }
        return (try? await session.partitions.registry.repository.apnsToken()) ?? nil
    }
}
