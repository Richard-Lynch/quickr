import Foundation
import Observation
import QuickrCore
import QuickrData

/// The sync UX's state and actions (outbox.md §10–§11): the network path, the active store's
/// outbox (for the pill and the sheet), the foreground flush timer, and Retry, Discard, Dismiss,
/// Sync now and pull to refresh. Lives in `AppEnvironment`; the root view runs `observe(_:)` per
/// store binding.
/// QuickrData's sync status, by a name that doesn't clash with the design system's (see
/// `DesignSyncStatus`).
typealias DataSyncStatus = SyncStatus

@MainActor @Observable
final class SyncController {
    /// The device has a network path (`NWPathMonitor`). Optimistic until the first update.
    private(set) var online = true
    private(set) var summary: OutboxSummary?
    /// The active store's unresolved items, by `seq`.
    private(set) var items: [OutboxItem] = []
    private(set) var topics: [String: SyncTopicInfo] = [:]
    /// The store `items` come from (`"{server_id}/{store_gen}"`), stamped on every row.
    private(set) var scope: EntryScope?
    /// The sync sheet is up. It lives at the root, not on the pill, which hides when all is
    /// synced while the sheet should stay.
    var isSheetPresented = false
    /// Lease time for the rows' "retrying in N min"; the store's clock.
    @ObservationIgnored private(set) var leaseClock: (any LeaseClock)?

    @ObservationIgnored private let network: any NetworkMonitoring
    @ObservationIgnored private let sleeper: any FlushTimerSleeper
    @ObservationIgnored private var timer: ForegroundFlushTimer?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var identityRecheck: Task<Void, Never>?
    @ObservationIgnored private weak var session: AppSession?

    init(network: any NetworkMonitoring, sleeper: any FlushTimerSleeper = ContinuousSleeper()) {
        self.network = network
        self.sleeper = sleeper
    }

    func pill(status: SyncStatus) -> SyncPillState {
        .make(summary: summary, status: status, online: online)
    }

    func sheet(lastSyncAt: Date?) -> SyncSheetModel {
        SyncSheetModel(
            items: items, topics: topics, online: online, lastSyncAt: lastSyncAt,
            now: leaseClock?.now() ?? LeaseInstant(bootId: "", ct: 0), scope: scope ?? EntryScope(""))
    }

    // MARK: - Triggers

    /// Follows the network path for the app's lifetime: when it comes back, flush (forced) and
    /// pull (outbox.md §10, sync-protocol.md §9). While the store is in identity mismatch, probes
    /// the address every 5 minutes in the foreground (§8.3). Idempotent.
    func startMonitoring(_ session: AppSession) {
        self.session = session
        guard monitoring == nil else { return }
        identityRecheck = Task { [sleeper] in
            await IdentityRecheck.run(
                sleeper: sleeper,
                shouldCheck: { @MainActor in session.syncStatus.identityMismatch && !session.isBackgrounded },
                recheck: { _ = await session.coordinator.recheckIdentity() })
        }
        let updates = network.updates()
        monitoring = Task { [weak self] in
            for await online in updates {
                guard let self else { return }
                let regained = online && !self.online
                self.online = online
                guard regained, let session = self.session else { continue }
                await session.scheduler?.requestFlush(reason: .networkAvailable)
                Task { _ = await session.coordinator.sync(reason: .network) }
            }
        }
    }

    /// The active store's outbox, from the root's `.task(id: session.binding)`: keeps the pill
    /// and the sheet current, and reschedules the foreground timer on every change. Returns when
    /// the task is cancelled (a new binding) or the store closes.
    func observe(_ session: AppSession) async {
        self.session = session
        guard let store = session.store, let outbox = session.outbox else {
            clear()
            return
        }
        leaseClock = store.leaseClock
        if scope != store.scope {
            // Another store: nothing of the old one may stay on screen to act on.
            items = []
            summary = nil
            scope = store.scope
        }
        let timer = ForegroundFlushTimer(
            sleeper: sleeper, nextWake: { try? await outbox.summary().nextWake }, now: { store.leaseClock.now() },
            fire: { [weak session] in await session?.scheduler?.requestFlush(reason: .timer) })
        self.timer?.stop()
        self.timer = timer
        defer { timer.stop() }
        do {
            for try await items in store.observeOutbox(refresh: session.refresh.stream()) {
                self.items = items
                summary = try? await outbox.summary()
                let topics = (try? await store.topics.topics()) ?? []
                self.topics = Dictionary(
                    topics.map { ($0.topic.id.uuidString.lowercased(), SyncTopicInfo(name: $0.topic.name)) },
                    uniquingKeysWith: { first, _ in first })
                if !session.isBackgrounded { timer.reschedule() }
            }
        } catch {
            // the store closed (reset, server switch): the next binding observes again
        }
    }

    /// `scenePhase` → `.active`: the timer runs again.
    func didBecomeActive() { timer?.reschedule() }

    /// `scenePhase` → `.background`: no timer (the background flush and BGAppRefreshTask send).
    func didEnterBackground() { timer?.stop() }

    private func clear() {
        timer?.stop()
        timer = nil
        items = []
        summary = nil
        topics = [:]
        scope = nil
    }

    /// The active store's outbox and scheduler, if `row` came from it; otherwise
    /// `SyncActionError.storeChanged` (the sheet showed another store's item).
    private func target(_ row: SyncItemRow) throws -> (Outbox, OutboxFlushScheduler?) {
        guard let session, let store = session.store, let outbox = session.outbox, row.scope == store.scope
        else { throw SyncActionError.storeChanged }
        return (outbox, session.scheduler)
    }

    // MARK: - Actions (outbox.md §11)

    /// Retry: due now, then a forced flush.
    func retry(_ row: SyncItemRow) async throws {
        let (outbox, scheduler) = try target(row)
        try await outbox.retry(itemId: row.id)
        await scheduler?.requestFlush(reason: .retry)
    }

    /// Discard: a create that may have been delivered is cancelled with a DELETE, so flush.
    func discard(_ row: SyncItemRow) async throws {
        let (outbox, scheduler) = try target(row)
        try await outbox.discard(itemId: row.id, origin: .app)
        await scheduler?.requestFlush(reason: .enqueue)
    }

    /// Dismiss a failed item whose entry was deleted elsewhere.
    func dismiss(_ row: SyncItemRow) async throws {
        try await target(row).0.dismiss(itemId: row.id)
    }

    /// Fix: RECORD's fix route for `row`, if it is still the active store's item.
    func fixRoute(_ row: SyncItemRow) throws -> Route {
        _ = try target(row)
        guard let fix = row.fix else { throw SyncActionError.storeChanged }
        return fix
    }

    /// The mismatch banner's "Check again": probe the address now.
    func checkIdentityAgain() async {
        _ = await session?.coordinator.recheckIdentity()
    }

    /// "Sync now": a forced flush (the PWA's).
    func syncNow() async {
        _ = await session?.scheduler?.flushNow(reason: .retry)
    }

    /// Pull to refresh: pull and send, together.
    func refresh() async {
        guard let session else { return }
        let coordinator = session.coordinator
        let scheduler = session.scheduler
        async let pull = coordinator.sync(reason: .pullToRefresh)
        async let flush = scheduler?.flushNow(reason: .retry)
        _ = await (pull, flush)
    }
}

/// Why a sync sheet action was refused.
enum SyncActionError: Error, CustomStringConvertible {
    /// The row came from another store (the server was switched or the store reset meanwhile).
    case storeChanged

    var description: String {
        switch self {
        case .storeChanged: "The server or its data changed, so this list is out of date. It has been refreshed."
        }
    }
}
