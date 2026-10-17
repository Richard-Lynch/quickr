import Foundation
import GRDB
import QuickrCore

/// The single sync coordinator of the active store (sync-protocol.md §5.4). App process only.
///
/// It pulls the feed (bootstrap from `after=0`, then steady state), rebuilds the server layer
/// through staging when the epoch changes or a restore is detected (§7), and drives local reset
/// and its crash recovery (§12). Every page, staging step and swap is one fenced transaction
/// under its `sync` lease token and the generations it captured (§5.5). It takes `sync`, then
/// `flush` only for a swap or a reset (§5.2), asks the outbox to flush through `FlushRequester`
/// after it has released every lease, and never flushes itself.
///
/// The loop decides from the persisted state **before** any request, so a coordinator that takes
/// over a half-finished rebuild resumes staging and never starts with a live pull.
public actor SyncCoordinator {
    public struct Configuration: Sendable {
        /// The page size sent as `limit` (§1.1).
        public var pageLimit = APIClient.feedPageLimit
        /// How long a swap waits for `flush` (a live sender's 30 s lease, plus slack).
        public var swapFlushWait: Duration = .seconds(35)
        /// Reset step 3: wait up to 35 s for `sync`, then `flush`.
        public var resetLeaseWait: Duration = .seconds(35)
        /// Retry a failed run with `SyncBackoff` (§9). Tests turn it off.
        public var autoRetry = true
        /// A guard against a feed that never drains: pages per run.
        public var maxStepsPerRun = 10_000
        /// Jitter for `SyncBackoff`, in −0.2…0.2.
        public var jitter: @Sendable () -> Double = { Double.random(in: -0.2...0.2) }
        public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        public init() {}
    }

    /// Reset step 1's warning (§12.1): what the user confirms.
    public struct ResetWarning: Sendable, Hashable {
        public var serverId: String
        public var storeGen: Int
        /// `N`, every unresolved item.
        public var count: Int
        /// `k`, the failed ones among them.
        public var failedCount: Int
        /// `M`, `max(outbox_item.seq)`, 0 when empty.
        public var maxSeq: Int64

        /// `N = 0` needs a single confirmation; otherwise a destructive second one.
        public var needsDestructiveConfirmation: Bool { count > 0 }
    }

    public enum ResetOutcome: Sendable, Hashable {
        /// The server moved to a fresh file at `storeGen`; `bootstrap` is its first sync.
        case completed(storeGen: Int, bootstrap: SyncResult)
        /// Writes were committed after the warning: nothing was retired. Show this warning again.
        case writesArrived(ResetWarning)
        /// `sync` or `flush` didn't come within 35 s: aborted, nothing retired.
        case timedOut
        /// The store or the intent changed under the reset (another reset, a server switch).
        case superseded
        case noActiveStore
    }

    public enum ConnectResult: Sendable, Hashable {
        /// The server is active; `sync` is the result of its first pull.
        case connected(serverId: String, isNew: Bool, sync: SyncResult)
        case failed(SyncFailure)
        /// The response wasn't quickR's (a proxy's 200 without the identity headers).
        case notQuickr
    }

    private let partitions: StorePartitions
    private let makeFeed: FeedFactory
    private let flush: any FlushRequester
    private let events: any SyncEventSink
    private let owner: String
    private let configuration: Configuration
    private let broadcaster = StatusBroadcaster(SyncStatus())

    private var store: LocalStore?
    private var running: Task<SyncResult, Never>?
    private var rerunRequested = false
    private var resetting = false
    private var forceRebuild = false
    private var retryTask: Task<Void, Never>?
    /// The outcome of a reset resumed at launch (§12.2 row 1), for the UI to pick up.
    public private(set) var resumedReset: ResetOutcome?

    /// - Parameter owner: the lease owner, `LeaseClaim.owner(kind: "app", launchId:)`.
    public init(
        partitions: StorePartitions, feed: @escaping FeedFactory, flush: any FlushRequester,
        events: any SyncEventSink = NoSyncSideEffects(), owner: String, configuration: Configuration = Configuration()
    ) {
        self.partitions = partitions
        self.makeFeed = feed
        self.flush = flush
        self.events = events
        self.owner = owner
        self.configuration = configuration
    }

    // MARK: - Public API

    /// The current status, and every change to it (the latest is replayed to a new subscriber).
    public nonisolated func statusUpdates() -> AsyncStream<SyncStatus> { broadcaster.stream() }

    public nonisolated var status: SyncStatus { broadcaster.value }

    /// Pulls until the feed drains, staging and swapping a rebuild if one is needed. A call while
    /// a run is in progress joins it (and makes it run once more).
    public func sync(reason: SyncReason) async -> SyncResult {
        await run(reason: reason, prefetched: nil)
    }

    /// Launch: resume an interrupted reset (§12.2), delete old retired files, then pull if the
    /// active store hasn't finished its bootstrap (or is mid-rebuild).
    public func bootstrapIfNeeded() async -> SyncResult {
        do {
            guard let store = try await activeStore() else { return .noActiveStore }
            _ = try? await partitions.deleteRetiredFiles()
            guard let state = try await store.syncState.syncState() else { return .failed(.storage("no sync_state")) }
            refresh(state)
            if state.bootstrapComplete, state.rebuilding == nil { return .synced }
        } catch {
            return .failed(.storage(String(describing: error)))
        }
        return await sync(reason: .bootstrap)
    }

    /// Onboarding or Settings (§2.1): fetch `after=0` from `baseURL`, read its `server_id`, then
    /// activate the known store for it (discarding the page) or create one at `store_gen = 1` and
    /// apply the page as its first. Then pull to the head. Switching servers' warnings and APNs
    /// (§8.4) are the caller's.
    public func connect(baseURL: URL) async -> ConnectResult {
        if let running { _ = await running.value }
        let wall = partitions.wallClock
        let sentAt = wall.now()
        let response: APIResponse<ChangePage>
        do {
            response = try await makeFeed(baseURL).listChanges(
                after: 0, limit: configuration.pageLimit, options: RequestOptions(expecting: nil))
        } catch {
            return .failed(.unreachable(String(describing: error)))
        }
        let timing = FeedTiming(sentAt: sentAt, receivedAt: wall.now())
        let page: ChangePage
        switch response.outcome {
        case .success(let value): page = value
        case .identityMismatch: return .notQuickr
        default: return .failed(Self.failure(response) ?? .unreachable("no page"))
        }
        do {
            let isNew = try await partitions.registry.repository.server(id: page.serverId) == nil
            invalidateStore()
            if isNew {
                store = try await partitions.createStore(serverId: page.serverId, baseURL: baseURL.absoluteString)
            }
            try await partitions.registry.setActive(page.serverId)
            let result = await run(reason: .bootstrap, prefetched: isNew ? (page, timing) : nil)
            return .connected(serverId: page.serverId, isNew: isNew, sync: result)
        } catch {
            return .failed(.storage(String(describing: error)))
        }
    }

    /// A non-coordinator (a flusher, an online-only call, a GET) saw a mismatch, or the user asked
    /// for a resync. With `context`, sets `epoch_suspect` in a transaction fenced on that context
    /// (§5.6 step 1) so claims stop. Then runs the coordinator **asynchronously** (step 3); its
    /// next live page confirms the epoch or starts the rebuild. `force` rebuilds from the server
    /// even if the epoch still matches. Returns at once.
    public func requestRebuild(context: RequestContext? = nil, force: Bool = false) async {
        if force { forceRebuild = true }
        if let context, let store = try? await activeStore(), context.serverId == store.serverId,
            context.storeGen == store.storeGen
        {
            let clock = store.leaseClock
            _ = try? await store.writer.write { db in
                try SyncTransactions.setEpochSuspect(db, conditions: context.conditions, now: clock.now())
            }
        }
        Task { _ = await self.sync(reason: .requested) }
    }

    /// §8.3 "Keep waiting": probe the feed; if it names the store's server again, clear identity
    /// mismatch and sync. SYNC-UX calls it every 5 minutes while the banner shows.
    public func recheckIdentity() async -> SyncResult {
        do {
            guard let store = try await activeStore() else { return .noActiveStore }
            guard let state = try await store.syncState.syncState(), state.identityMismatch else {
                return await sync(reason: .requested)
            }
            guard let url = URL(string: state.baseURL) else { return .failed(.storage("bad base_url")) }
            let response = try await makeFeed(url).listChanges(
                after: state.cursor, limit: 1, options: RequestOptions(expecting: nil))
            guard case .success(let page) = response.outcome, Self.same(page.serverId, store.serverId) else {
                return .identityMismatch
            }
            guard let claim = try await store.leases.tryAcquire(.sync, owner: owner) else { return .busy }
            let clock = store.leaseClock
            let fenced = try await store.writer.write { db in
                try SyncTransactions.clearIdentityMismatch(db, layerGen: state.layerGen, claim: claim, now: clock.now())
            }
            _ = try? await store.leases.release(claim)
            if fenced != nil { return .superseded }
        } catch {
            return .failed(.storage(String(describing: error)))
        }
        return await sync(reason: .requested)
    }

    /// Reset step 1 (§12.1): what the warning shows. Nil when no server is active.
    public func resetWarning() async throws -> ResetWarning? {
        guard let store = try await activeStore() else { return nil }
        return try await warning(for: store)
    }

    /// Settings ▸ "Reset local data" (§12.1 steps 2–8) on the active store, after the user
    /// confirmed `confirmed`. Replaces the store with a fresh file at the next generation and
    /// bootstraps it; other stores, the registry's other rows and credentials are untouched.
    public func performReset(confirmed: ResetWarning) async throws -> ResetOutcome {
        guard !resetting else { return .superseded }
        guard let store = try await activeStore() else { return .noActiveStore }
        guard store.serverId == confirmed.serverId, store.storeGen == confirmed.storeGen else { return .superseded }
        resetting = true
        broadcaster.update { $0.activity = .resetting }
        let outcome: ResetOutcome
        do {
            let intent: RegisteredServer
            do {
                intent = try await partitions.persistResetIntent(
                    store: store, confirmedCount: confirmed.count, confirmedMaxSeq: confirmed.maxSeq)
            } catch StoreError.registryChanged {
                endReset()
                return .superseded
            }
            outcome = try await continueReset(old: store, intent: intent)
        } catch {
            endReset()
            throw error
        }
        endReset()
        guard case .completed(let storeGen, _) = outcome else { return outcome }
        return .completed(storeGen: storeGen, bootstrap: await sync(reason: .bootstrap))
    }

    /// Listens for `sync-requested` (an extension saw a mismatch, §5.6) and `registry-changed`
    /// (reopen at the new generation, §8.1). Cancel the task to stop.
    public nonisolated func listen(to notifier: any ChangeNotifier) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in notifier.signals(.syncRequested) { _ = await self.sync(reason: .requested) }
                }
                group.addTask {
                    for await _ in notifier.signals(.registryChanged) { await self.invalidateStore() }
                }
            }
        }
    }

    /// Forget the open store; the next call reopens the active one through the registry.
    public func invalidateStore() { store = nil }

    // MARK: - The run

    private typealias Prefetched = (page: ChangePage, timing: FeedTiming)

    private func run(reason: SyncReason, prefetched: Prefetched?) async -> SyncResult {
        if resetting { return .resetInProgress }
        if let running {
            rerunRequested = true
            return await running.value
        }
        let task = Task { await self.runLoop(prefetched: prefetched) }
        running = task
        return await task.value
    }

    private func runLoop(prefetched: Prefetched?) async -> SyncResult {
        var result: SyncResult
        var prefetched = prefetched
        repeat {
            rerunRequested = false
            result = await runOnce(prefetched: prefetched)
            prefetched = nil
        } while rerunRequested && result == .synced
        running = nil
        broadcaster.update { $0.activity = resetting ? .resetting : .idle }
        recordOutcome(result)
        return result
    }

    private func runOnce(prefetched: Prefetched?) async -> SyncResult {
        do {
            for _ in 0..<2 {
                guard let store = try await activeStore() else { return .noActiveStore }
                switch try await coordinate(store, prefetched: prefetched) {
                case .result(let result): return result
                case .reopen: invalidateStore()
                }
            }
            return .superseded
        } catch {
            return .failed(.storage(String(describing: error)))
        }
    }

    private enum CoordinateOutcome {
        case result(SyncResult)
        /// The file is retired: reopen through the registry (§12).
        case reopen
    }

    /// Run bookkeeping that is reported once the `sync` lease is released.
    private struct RunEffects {
        var pagesApplied = 0
        var swapped = false
        var deletedTopics: [UUID] = []
        var bootstrapped = false
    }

    /// `coordinate(store)` (§5.4).
    private func coordinate(_ store: LocalStore, prefetched: Prefetched?) async throws -> CoordinateOutcome {
        guard let claim = try await store.leases.tryAcquire(.sync, owner: owner) else { return .result(.busy) }
        var effects = RunEffects()
        let outcome: CoordinateOutcome
        do {
            outcome = try await loop(store, claim: claim, prefetched: prefetched, effects: &effects)
        } catch {
            _ = try? await store.leases.release(claim)
            throw error
        }
        _ = try? await store.leases.release(claim)
        await report(effects, store: store, outcome: outcome)
        return outcome
    }

    private func loop(_ store: LocalStore, claim: LeaseClaim, prefetched: Prefetched?, effects: inout RunEffects)
        async throws -> CoordinateOutcome
    {
        var prefetched = prefetched
        for _ in 0..<configuration.maxStepsPerRun {
            if resetting { return .result(.resetInProgress) }
            // A short read; no request in flight. The persisted state decides the step.
            guard let state = try await store.syncState.syncState() else { throw StoreError.notBootstrapped }
            refresh(state)
            if state.retired { return .reopen }
            if state.identityMismatch { return .result(.identityMismatch) }
            let step: Step
            if let target = state.rebuilding {
                step = try await stageStep(store, state: state, target: target, claim: claim, effects: &effects)
            } else {
                step = try await liveStep(
                    store, state: state, claim: claim, prefetched: prefetched.take(), effects: &effects)
            }
            switch step {
            case .more: continue
            case .drained: return .result(.synced)
            case .stop(let result): return .result(result)
            case .epochMismatch(let epoch):
                switch try await startRebuild(store, target: epoch, state: state, claim: claim) {
                case .started, .alreadyStaging: continue
                case .fenced: return .result(.superseded)
                }
            }
        }
        return .result(.failed(.protocolError("the feed did not drain in \(configuration.maxStepsPerRun) pages")))
    }

    private enum Step {
        case more
        case drained
        case epochMismatch(String)
        case stop(SyncResult)
    }

    /// `liveStep(st)` (§5.4): one live page.
    private func liveStep(
        _ store: LocalStore, state: SyncState, claim: LeaseClaim, prefetched: Prefetched?, effects: inout RunEffects
    ) async throws -> Step {
        let context = LiveContext(layerGen: state.layerGen, epoch: state.epoch, cursor: state.cursor, claim: claim)
        broadcaster.update {
            $0.activity = .pulling(
                bootstrapping: !state.bootstrapComplete, cursor: state.cursor, head: max(state.headSeen, state.cursor))
        }
        let page: ChangePage
        let timing: FeedTiming?
        if let prefetched, state.cursor == 0, state.epoch == nil, Self.same(prefetched.page.serverId, state.serverId) {
            (page, timing) = prefetched
        } else {
            let expecting = state.epoch.map { ServerIdentity(serverId: state.serverId, epoch: $0) }
            guard let (response, fetchTiming) = try await fetch(state, after: state.cursor, expecting: expecting) else {
                return .stop(.failed(.storage("bad base_url \(state.baseURL)")))
            }
            switch response.outcome {
            case .success(let value): page = value
            case .identityMismatch:
                return try await enterIdentityMismatch(store, state: state, claim: claim)
            case .epochMismatch:
                return try await epochMismatch(
                    store, response: response, conditions: [.notRetired, .layerGen(state.layerGen)])
            default:
                return .stop(.failed(Self.failure(response) ?? .unreachable("no page")))
            }
            timing = fetchTiming
        }

        // §2.2, in order: identity, epoch, restore (cursor ≤ head), then the transaction's checks.
        guard Self.same(page.serverId, state.serverId) else {
            return try await enterIdentityMismatch(store, state: state, claim: claim)
        }
        if let epoch = state.epoch, !Self.same(page.epoch, epoch) || state.cursor > page.head {
            return .epochMismatch(page.epoch)
        }
        if forceRebuild {
            forceRebuild = false
            return .epochMismatch(page.epoch)
        }
        if page.hasMore, page.next <= state.cursor {
            return .stop(.failed(.protocolError("has_more without progress past \(state.cursor)")))
        }
        let clock = store.leaseClock
        let wallNow = partitions.wallClock.now()
        let result = try await store.writer.write { db in
            try SyncTransactions.applyLivePage(
                db, page: page, context: context, now: clock.now(), wallNow: wallNow, timing: timing)
        }
        switch result {
        case .applied(let deletedTopics):
            effects.pagesApplied += 1
            effects.deletedTopics += deletedTopics
            if !page.hasMore, !state.bootstrapComplete { effects.bootstrapped = true }
            return page.hasMore ? .more : .drained
        case .fenced:
            return .stop(.superseded)
        case .protocolError(let message):
            return .stop(.failed(.protocolError(message)))
        }
    }

    /// `stageStep(st)` (§7 step 2), with its own staging context; swaps when the feed drains.
    private func stageStep(
        _ store: LocalStore, state: SyncState, target: String, claim: LeaseClaim, effects: inout RunEffects
    ) async throws -> Step {
        let stageCursor = try await store.writer.read { db in try SyncTransactions.stageCursor(db) }
        let context = StageContext(layerGen: state.layerGen, targetEpoch: target, cursor: stageCursor, claim: claim)
        broadcaster.update { $0.activity = .rebuilding(cursor: stageCursor, head: max(stageCursor, $0.headSeen)) }
        guard
            let (response, timing) = try await fetch(
                state, after: stageCursor, expecting: ServerIdentity(serverId: state.serverId, epoch: target))
        else { return .stop(.failed(.storage("bad base_url \(state.baseURL)"))) }
        let page: ChangePage
        switch response.outcome {
        case .success(let value): page = value
        case .identityMismatch:
            return try await enterIdentityMismatch(store, state: state, claim: claim)
        case .epochMismatch:
            // Only a *different* epoch restarts staging (§5.4, S15).
            guard let epoch = response.observed.epoch else {
                return .stop(.failed(.protocolError("epoch mismatch without an epoch header")))
            }
            return .epochMismatch(epoch)
        default:
            return .stop(.failed(Self.failure(response) ?? .unreachable("no page")))
        }
        guard Self.same(page.serverId, state.serverId) else {
            return try await enterIdentityMismatch(store, state: state, claim: claim)
        }
        guard Self.same(page.epoch, target) else { return .epochMismatch(page.epoch) }
        if page.hasMore, page.next <= stageCursor {
            return .stop(.failed(.protocolError("has_more without progress past \(stageCursor)")))
        }
        let clock = store.leaseClock
        let wallNow = partitions.wallClock.now()
        let result = try await store.writer.write { db in
            try SyncTransactions.applyStagedPage(
                db, page: page, context: context, now: clock.now(), wallNow: wallNow, timing: timing)
        }
        switch result {
        case .applied:
            broadcaster.update { $0.activity = .rebuilding(cursor: page.next, head: page.head) }
            guard !page.hasMore else { return .more }
            var swapContext = context
            swapContext.cursor = page.next
            return try await swap(store, context: swapContext, head: page.head, effects: &effects)
        case .fenced:
            return .stop(.superseded)
        case .protocolError(let message):
            return .stop(.failed(.protocolError(message)))
        }
    }

    /// §7 step 3: `sync` → `flush`, one transaction fenced on both, release `flush`. The loop
    /// then re-reads `sync_state`, so the next live context has the new epoch and `layer_gen`.
    private func swap(_ store: LocalStore, context: StageContext, head: Int, effects: inout RunEffects) async throws
        -> Step
    {
        guard try await store.leases.renew(context.claim) else { return .stop(.superseded) }
        guard
            let flushClaim = try await store.leases.acquire(
                .flush, owner: owner, holding: [context.claim], waitingUpTo: configuration.swapFlushWait)
        else { return .stop(.failed(.leaseBusy)) }
        let clock = store.leaseClock
        let wallNow = partitions.wallClock.now()
        let result: SwapResult
        do {
            result = try await store.writer.write { db in
                try SyncTransactions.swap(
                    db, context: context, flush: flushClaim, head: head, now: clock.now(), wallNow: wallNow)
            }
        } catch {
            _ = try? await store.leases.release(flushClaim)
            throw error
        }
        _ = try? await store.leases.release(flushClaim)
        switch result {
        case .swapped(let layerGen, let deletedTopics):
            effects.swapped = true
            effects.deletedTopics += deletedTopics
            events.handle(.layerSwapped(serverId: store.serverId, layerGen: layerGen))
            return .more
        case .fenced:
            return .stop(.superseded)
        }
    }

    private func startRebuild(_ store: LocalStore, target: String, state: SyncState, claim: LeaseClaim) async throws
        -> StartRebuildResult
    {
        let clock = store.leaseClock
        let result = try await store.writer.write { db in
            try SyncTransactions.startRebuild(
                db, target: target, layerGen: state.layerGen, claim: claim, now: clock.now())
        }
        if result == .started { broadcaster.update { $0.activity = .rebuilding(cursor: 0, head: 0) } }
        return result
    }

    private func enterIdentityMismatch(_ store: LocalStore, state: SyncState, claim: LeaseClaim) async throws -> Step {
        let clock = store.leaseClock
        let fenced = try await store.writer.write { db in
            try SyncTransactions.setIdentityMismatch(db, layerGen: state.layerGen, claim: claim, now: clock.now())
        }
        broadcaster.update { if fenced == nil { $0.identityMismatch = true } }
        return .stop(fenced == nil ? .identityMismatch : .superseded)
    }

    /// An epoch header that differs from the context's: rebuild towards it. Without one (a partial
    /// header set), only mark the store suspect and retry later.
    private func epochMismatch(
        _ store: LocalStore, response: APIResponse<ChangePage>, conditions: [StoreFence.Condition]
    )
        async throws -> Step
    {
        if let epoch = response.observed.epoch { return .epochMismatch(epoch) }
        let clock = store.leaseClock
        _ = try await store.writer.write { db in
            try SyncTransactions.setEpochSuspect(db, conditions: conditions, now: clock.now())
        }
        return .stop(.failed(.protocolError("epoch mismatch without an epoch header")))
    }

    private func fetch(_ state: SyncState, after cursor: Int, expecting: ServerIdentity?) async throws -> (
        APIResponse<ChangePage>, FeedTiming
    )? {
        guard let url = URL(string: state.baseURL) else { return nil }
        let wall = partitions.wallClock
        let sentAt = wall.now()
        let response = try await makeFeed(url).listChanges(
            after: cursor, limit: configuration.pageLimit, options: RequestOptions(expecting: expecting))
        return (response, FeedTiming(sentAt: sentAt, receivedAt: wall.now()))
    }

    /// After the `sync` lease is released: tell the app, ask for a flush, record the sync time
    /// and delete old retired files (§12.1 step 9).
    private func report(_ effects: RunEffects, store: LocalStore, outcome: CoordinateOutcome) async {
        if !effects.deletedTopics.isEmpty {
            events.handle(.topicsDeleted(serverId: store.serverId, topicIds: effects.deletedTopics))
        }
        if effects.pagesApplied > 0 || effects.swapped { events.handle(.layerChanged(serverId: store.serverId)) }
        if effects.bootstrapped { events.handle(.bootstrapped(serverId: store.serverId)) }
        guard case .result(.synced) = outcome else { return }
        flush.requestFlush(reason: effects.swapped ? .afterSwap : .afterPull)
        try? await partitions.registry.setLastSync(serverId: store.serverId, at: partitions.wallClock.now())
        _ = try? await partitions.deleteRetiredFiles()
    }

    // MARK: - Reset (§12)

    private func endReset() {
        resetting = false
        broadcaster.update { $0.activity = .idle }
    }

    private func warning(for store: LocalStore) async throws -> ResetWarning {
        let (count, failed, maxSeq) = try await store.writer.read { db in
            let summary = try OutboxStorage.summary(db)
            let failed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_item WHERE state = 'failed'") ?? 0
            return (summary.count, failed, summary.maxSeq)
        }
        return ResetWarning(
            serverId: store.serverId, storeGen: store.storeGen, count: count, failedCount: failed, maxSeq: maxSeq)
    }

    /// Steps 3–7 on `old` for `intent` (also the §12.2 row 1 resume). The intent is passed
    /// through to STORE as is; its persisted confirmed count and max seq drive the re-check.
    private func continueReset(old: LocalStore, intent: RegisteredServer) async throws -> ResetOutcome {
        guard
            let pair = try await old.leases.acquireSyncThenFlush(
                owner: owner, waitingUpTo: configuration.resetLeaseWait)
        else {
            try await partitions.abortReset(intent)
            return .timedOut
        }
        let retired: RetireOutcome
        do {
            retired = try await old.retire(
                confirmedCount: intent.pendingConfirmedCount ?? 0, confirmedMaxSeq: intent.pendingConfirmedMaxSeq ?? 0,
                sync: pair.sync, flush: pair.flush)
        } catch {
            _ = try? await old.leases.release(pair.flush)
            _ = try? await old.leases.release(pair.sync)
            throw error
        }
        _ = try? await old.leases.release(pair.flush)
        _ = try? await old.leases.release(pair.sync)
        switch retired {
        case .writesArrived:
            try await partitions.abortReset(intent)
            return .writesArrived(try await warning(for: old))
        case .fenced:
            try await partitions.abortReset(intent)
            return .superseded
        case .intentAborted:
            return .superseded
        case .retired:
            let fresh: LocalStore
            do {
                fresh = try await partitions.completeReset(intent)
            } catch StoreError.registryChanged {
                invalidateStore()
                return .superseded
            }
            store = fresh
            events.handle(.storeReset(serverId: fresh.serverId, storeGen: fresh.storeGen))
            return .completed(storeGen: fresh.storeGen, bootstrap: .synced)
        }
    }

    // MARK: - Store

    /// The active store, opened through the registry with its §12.2 recovery; the app resumes a
    /// reset interrupted between steps 2 and 4 here, before any pull.
    private func activeStore() async throws -> LocalStore? {
        if let store { return store }
        guard let opened = try await partitions.openActiveStore(role: .app) else { return nil }
        switch opened {
        case .opened(let store):
            self.store = store
        case .resetPending(let old, let intent):
            resetting = true
            broadcaster.update { $0.activity = .resetting }
            let outcome: ResetOutcome
            do {
                outcome = try await continueReset(old: old, intent: intent)
            } catch {
                endReset()
                throw error
            }
            endReset()
            resumedReset = outcome
            if store == nil {
                // Aborted: the intent is cleared and the old file is current again.
                store = try await partitions.openActiveStore(role: .extension)?.store
            }
        }
        if let store { broadcaster.update { $0.serverId = store.serverId } }
        return store
    }

    // MARK: - Status

    private func refresh(_ state: SyncState) {
        broadcaster.update { status in
            status.serverId = state.serverId
            status.lastSyncAt = state.lastPullAt
            status.cursor = state.cursor
            status.headSeen = state.headSeen
            status.bootstrapComplete = state.bootstrapComplete
            status.rebuilding = state.rebuilding != nil
            status.epochSuspect = state.epochSuspect
            status.identityMismatch = state.identityMismatch
            status.skewMilliseconds = state.skewMilliseconds
        }
    }

    private func recordOutcome(_ result: SyncResult) {
        retryTask?.cancel()
        retryTask = nil
        switch result {
        case .synced:
            broadcaster.update {
                $0.lastFailure = nil
                $0.consecutiveFailures = 0
                $0.retryDelay = nil
            }
            if let store {
                Task { [weak self] in
                    if let state = try? await store.syncState.syncState() { await self?.refresh(state) }
                }
            }
        case .failed(let failure):
            var delay: Duration = .zero
            broadcaster.update {
                $0.lastFailure = failure
                $0.consecutiveFailures += 1
                delay = SyncBackoff.delay(failures: $0.consecutiveFailures, jitter: configuration.jitter())
                $0.retryDelay = delay
            }
            guard configuration.autoRetry else { return }
            let sleep = configuration.sleep
            retryTask = Task { [weak self] in
                guard (try? await sleep(delay)) != nil, !Task.isCancelled else { return }
                _ = await self?.sync(reason: .retry)
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    /// The failure a non-success feed response means (§9 backoff for all of them).
    static func failure(_ response: APIResponse<ChangePage>) -> SyncFailure? {
        switch response.outcome {
        case .success: nil
        case .uncertain(.undecodableSuccess(_, let reason)): .protocolError(reason)
        case .retryable, .uncertain: .unreachable(response.message ?? "Could not reach the server")
        case .terminal(let status, _): .rejected(status: status, message: response.message)
        case .notFound, .entryDeleted, .staleRevision:
            .rejected(status: response.status ?? 0, message: response.message)
        case .identityMismatch, .epochMismatch: .protocolError(response.message ?? "mismatch")
        }
    }
}

extension Optional {
    /// Returns the value and leaves nil behind.
    fileprivate mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
