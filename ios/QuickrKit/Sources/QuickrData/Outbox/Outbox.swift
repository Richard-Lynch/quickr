import Foundation
import GRDB
import QuickrCore
import Synchronization

/// What the outbox asks of the coordinator, delivered **after** `flush` is released
/// (sync-protocol.md §5.6): the app runs its coordinator; an extension posts
/// `com.bahumia.quickr.sync-requested`.
public enum OutboxSignal: Sendable, Hashable {
    /// `identity_mismatch` was set.
    case identityMismatch
    /// `epoch_suspect` was set.
    case epochSuspect
    /// A pull should run: a topic is missing, or an archive or unarchive found no topic.
    case pullRequested
}

/// How a flush ended, and what it did.
public struct OutboxFlushReport: Sendable, Hashable {
    public enum Ending: Sendable, Hashable {
        /// Another process holds `flush`.
        case busy
        /// `rebuilding`, `retired`, `identity_mismatch`, `epoch_suspect` or no epoch: no claims (§6.2).
        case paused
        /// Nothing eligible is left (items may wait for their backoff or behind a failed item).
        case drained
        case budgetExhausted
        case cancelled
        /// The lease was lost at a renewal.
        case leaseLost
        /// A sender check failed: another flusher took over, so this one stopped and wrote nothing.
        case superseded
        /// No response: the rest would fail the same way (§5.1 "stop the pass").
        case unreachable
        case mismatch(OutboxMismatch)
    }

    public var ending: Ending
    /// HTTP requests made, refetches included.
    public var requests = 0
    public var acked = 0
    public var failed = 0
    public var retried = 0
    /// Retired, cancelled (S8) or restored after a precondition 409.
    public var settled = 0

    public init(ending: Ending) { self.ending = ending }
}

/// The sync pill's inputs (outbox.md §11).
public struct OutboxSummary: Sendable, Hashable {
    /// Held, pending, in-flight and uncertain items.
    public var queued = 0
    public var held = 0
    /// Of `queued`, those that may have been delivered ("Sending… (checking)").
    public var uncertain = 0
    public var failed = 0
    /// Queued items waiting behind a failed one ("Waiting for _failed item_", §7.2).
    public var blocked = 0
    /// An active item's last attempt got no response.
    public var offline = false
    /// The earliest backoff deadline or hold among pending, uncertain and held items: the
    /// foreground timer's target (capped at 60 s by the caller, §10). Nil when nothing waits.
    public var nextWake: LeaseInstant?

    public init() {}

    public var isEmpty: Bool { queued == 0 && failed == 0 }

    static func read(_ db: Database, now: LeaseInstant) throws -> OutboxSummary {
        var summary = OutboxSummary()
        var scope = OutboxScope()
        for item in try OutboxStorage.items(db) {
            defer { scope.add(item) }
            switch item.state {
            case .failed:
                summary.failed += 1
                continue
            case .held:
                summary.held += 1
            case .uncertain:
                summary.uncertain += 1
            case .pending, .inFlight:
                break
            }
            summary.queued += 1
            if scope.earliest(before: item)?.state == .failed { summary.blocked += 1 }
            if item.state != .inFlight, item.attempts > 0, item.lastError?.status == nil, item.lastError != nil {
                summary.offline = true
            }
            guard item.state != .inFlight else { continue }
            let deadline = (item.state == .held ? item.hold : item.due) ?? now
            let wake = now.hasPassed(deadline: deadline) ? now : deadline
            if summary.nextWake.map({ wake.ct < $0.ct }) ?? true { summary.nextWake = wake }
        }
        return summary
    }
}

/// The durable write queue of one store file (outbox.md). Shared by every process; each process
/// makes its own `Outbox` with its own lease `owner`.
///
/// Enqueue, undo and the sync sheet's actions are plain `IMMEDIATE` transactions. `flush` takes
/// the cross-process `flush` lease, claims one item at a time and sends it through `sender` with
/// no transaction open; every transaction after a claim is fenced by the sender check (S2), and
/// those after a send run even if the flushing task is cancelled, so an answer is never lost to
/// a cancellation that came after it. Commits post `db-changed` through the store's pool.
public struct Outbox: Sendable {
    /// The undo window of a delete (§9.2).
    public static let holdDuration: Duration = .seconds(6)
    /// The per-request timeout, capped by the remaining budget (§4).
    public static let requestTimeout: Duration = .seconds(15)
    /// `stale_revision` rebases before `failed/conflict` (§7.4).
    public static let maxRebases = 3

    public let store: LocalStore
    public let sender: any OutboxSender
    /// `"<process kind>:<launch uuid>"`, the `flush` lease owner.
    public let owner: String
    /// Called after the lease is released, once per signal a flush raised.
    public var onSignal: @Sendable (OutboxSignal) -> Void
    /// The backoff jitter source, in `[0, 1)`.
    public var random: @Sendable () -> Double
    /// How long a flush that is out of budget or cancelled still listens for the answer to the
    /// request it cancelled, before giving up on a sender that doesn't stop (§10).
    public var shutdownGrace: Duration

    public init(
        store: LocalStore, sender: any OutboxSender, owner: String,
        onSignal: @escaping @Sendable (OutboxSignal) -> Void = { _ in },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        shutdownGrace: Duration = .seconds(1)
    ) {
        self.store = store
        self.sender = sender
        self.owner = owner
        self.onSignal = onSignal
        self.random = random
        self.shutdownGrace = shutdownGrace
    }

    private var writer: any DatabaseWriter { store.writer }

    // MARK: - Enqueue (§8)

    /// Durably enqueues one item, with the coalescing rules of §8 and the C0 check. `holdFor` puts
    /// an `entry.delete` in its undo window (K5); use `deleteEntry(_:undoable:)`.
    @discardableResult
    public func enqueue(_ item: NewOutboxItem, holdFor hold: Duration? = nil) async throws -> OutboxEnqueueResult {
        try await write { db, now, wall in try OutboxQueue.enqueue(db, item, holdFor: hold, now: now, wall: wall) }
    }

    /// Logs an entry: `entry.create`, whose item id is the entry id. `body.version` and
    /// `body.captured_at` must be set; `body.source` is the origin's (§4).
    @discardableResult
    public func createEntry(id: UUID, topic: TopicRef, body: EntryCreateDTO, origin: OutboxOrigin) async throws
        -> OutboxEnqueueResult
    {
        var body = body
        body.id = nil
        body.source = origin.source  // what the request will carry (§4), so the overlay shows it
        return try await enqueue(NewOutboxItem(id: id, payload: .entryCreate(topic: topic, body: body), origin: origin))
    }

    /// `baseRevision` is the server-layer revision under the view the user edited (§7.3); nil
    /// takes the current one.
    @discardableResult
    public func updateEntry(
        id: UUID, topicId: UUID, patch: EntryUpdateDTO, baseRevision: Int? = nil, origin: OutboxOrigin
    ) async throws -> OutboxEnqueueResult {
        var patch = patch
        patch.expectedRevision = nil
        return try await enqueue(
            NewOutboxItem(
                payload: .entryUpdate(entryId: id.wireString, topicId: topicId.wireString, patch: patch),
                baseRevision: baseRevision, origin: origin))
    }

    /// Deletes an entry. `undoable` holds it for 6 s (§9.2): nothing before it changes until the
    /// hold is released, and `undoDelete` brings the entry back exactly.
    @discardableResult
    public func deleteEntry(id: UUID, topicId: UUID, undoable: Bool, origin: OutboxOrigin) async throws
        -> OutboxEnqueueResult
    {
        try await enqueue(
            NewOutboxItem(payload: .entryDelete(entryId: id.wireString, topicId: topicId.wireString), origin: origin),
            holdFor: undoable ? Self.holdDuration : nil)
    }

    /// Archives a topic. Undo is `unarchiveTopic`, which K3 cancels while the archive is unsent.
    @discardableResult
    public func archiveTopic(id: UUID, baseRevision: Int? = nil, origin: OutboxOrigin) async throws
        -> OutboxEnqueueResult
    {
        try await enqueue(
            NewOutboxItem(payload: .topicArchive(topicId: id.wireString), baseRevision: baseRevision, origin: origin))
    }

    @discardableResult
    public func unarchiveTopic(id: UUID, baseRevision: Int? = nil, origin: OutboxOrigin) async throws
        -> OutboxEnqueueResult
    {
        try await enqueue(
            NewOutboxItem(payload: .topicUnarchive(topicId: id.wireString), baseRevision: baseRevision, origin: origin))
    }

    // MARK: - Undo (§9)

    /// Undo of a log: `cancelCreate` (§9.1). The POST is never sent again.
    @discardableResult
    public func undoLog(entryId: UUID, origin: OutboxOrigin) async throws -> OutboxUndoLogResult {
        try await write { db, now, wall in
            try OutboxQueue.cancelCreate(db, entryId: entryId.wireString, origin: origin, now: now, wall: wall)
        }
    }

    /// Undo of a delete while it is held (§9.2 step 2).
    @discardableResult
    public func undoDelete(entryId: UUID) async throws -> OutboxUndoDeleteResult {
        try await write { db, _, _ in try OutboxQueue.undoDelete(db, entryId: entryId.wireString) }
    }

    /// Releases held deletes (§9.2 step 3): those whose hold passed, or all of them when the app
    /// goes to the background. `flush` releases passed holds itself.
    @discardableResult
    public func releaseHolds(all: Bool) async throws -> Int {
        try await write { db, now, wall in try OutboxQueue.releaseHolds(db, all: all, now: now, wall: wall) }
    }

    // MARK: - Sync sheet (§11)

    /// Retry: back to `pending` (or `uncertain`), due now. The caller then forces a flush.
    public func retry(itemId: String) async throws {
        try await write { db, _, wall in try OutboxQueue.retry(db, itemId: itemId, wall: wall) }
    }

    /// Fix: replaces a failed, never-delivered create's or update's payload (CAS on `rowVersion`).
    public func fix(itemId: String, payload: OutboxPayload, rowVersion: Int) async throws {
        try await write { db, _, wall in
            try OutboxQueue.fix(db, itemId: itemId, payload: payload, rowVersion: rowVersion, wall: wall)
        }
    }

    public func discard(itemId: String, origin: OutboxOrigin) async throws {
        try await write { db, now, wall in
            try OutboxQueue.discard(db, itemId: itemId, origin: origin, now: now, wall: wall)
        }
    }

    public func dismiss(itemId: String) async throws {
        try await write { db, _, _ in try OutboxQueue.dismiss(db, itemId: itemId) }
    }

    public func summary() async throws -> OutboxSummary {
        let clock = store.leaseClock
        return try await writer.read { db in try OutboxSummary.read(db, now: clock.now()) }
    }

    // MARK: - Flush (§12)

    /// One flush: acquire `flush` (polling up to `leaseWait`), release passed holds, then claim
    /// and send eligible items until the queue drains, the budget runs out, the task is cancelled
    /// or an outcome stops the pass. `force` ignores backoff deadlines, never `failed`. Each item
    /// is claimed at most once per flush. On the way out, an item still in flight with this
    /// flusher's claim becomes `uncertain` and the lease is released; then signals are delivered.
    public func flush(force: Bool, budget: Duration, leaseWait: Duration = .zero) async throws -> OutboxFlushReport {
        let deadline = ContinuousClock.now.advanced(by: budget)
        let leases = store.leases
        let takeover = OutboxFlush.takeover(wallClock: store.wallClock)
        let lease =
            leaseWait > .zero
            ? try await leases.acquire(
                .flush, owner: owner, waitingUpTo: min(leaseWait, budget), pollInterval: .milliseconds(50),
                takeover: takeover)
            : try await leases.tryAcquire(.flush, owner: owner, takeover: takeover)
        guard let lease else { return OutboxFlushReport(ending: .busy) }

        var run = FlushRun(lease: lease, deadline: deadline, force: force)
        var failure: (any Error)?
        do {
            run.report.ending = try await pass(&run)
        } catch is CancellationError {
            run.report.ending = .cancelled
        } catch {
            failure = error
        }
        let current = run.current
        try? await uncancellable { db, _, wall in
            try OutboxFlush.release(db, lease: lease, current: current, wall: wall)
        }
        for signal in run.signals { onSignal(signal) }
        if let failure { throw failure }
        return run.report
    }

    private struct FlushRun {
        let lease: LeaseClaim
        let deadline: ContinuousClock.Instant
        let force: Bool
        var report = OutboxFlushReport(ending: .drained)
        /// The item this flusher holds in flight, if any.
        var current: (itemId: String, token: String)?
        var attempted: Set<String> = []
        var signals: [OutboxSignal] = []

        init(lease: LeaseClaim, deadline: ContinuousClock.Instant, force: Bool) {
            self.lease = lease
            self.deadline = deadline
            self.force = force
        }

        mutating func signal(_ signal: OutboxSignal) {
            if !signals.contains(signal) { signals.append(signal) }
        }
    }

    private func pass(_ run: inout FlushRun) async throws -> OutboxFlushReport.Ending {
        _ = try await write { db, now, wall in try OutboxQueue.releaseHolds(db, all: false, now: now, wall: wall) }
        while true {
            if Task.isCancelled { return .cancelled }
            guard ContinuousClock.now < run.deadline else { return .budgetExhausted }
            let (lease, force, skipping) = (run.lease, run.force, run.attempted)
            let step = try await write { db, now, wall in
                try OutboxFlush.claimNext(db, lease: lease, force: force, skipping: skipping, now: now, wall: wall)
            }
            switch step {
            case .leaseLost: return .leaseLost
            case .paused: return .paused
            case .drained: return .drained
            case .claimed(let claim):
                run.current = (claim.item.id, claim.sender.claimToken)
                run.attempted.insert(claim.item.id)
                if let ending = try await process(claim, &run) { return ending }
                run.current = nil
            }
        }
    }

    /// Sends one claimed item, rebasing and resending on `stale_revision` (§7.4), and applies the
    /// outcome. Returns an ending to stop the pass, nil to continue.
    private func process(_ claim: OutboxClaim, _ run: inout FlushRun) async throws -> OutboxFlushReport.Ending? {
        var item = claim.item
        while true {
            let request = try OutboxFlush.request(for: item, expecting: claim.expecting, timeout: timeout(run))
            guard let response = await send(request, deadline: run.deadline) else {
                return Task.isCancelled ? .cancelled : .budgetExhausted
            }
            run.report.requests += 1
            let resolution = OutboxResolution.resolve(item.kind, response.outcome)
            guard resolution == .rebase else {
                return try await finish(
                    claim, resolution, error: response.outboxError, stopsPass: response.outcome.stopsPass, &run)
            }
            switch try await rebase(claim, item, &run) {
            case .resend(let rebased): item = rebased
            case .done(let ending): return ending
            }
        }
    }

    private enum RebaseResult {
        case resend(OutboxItem)
        case done(OutboxFlushReport.Ending?)
    }

    /// §7.4, verified at every step: verify, refetch (headers first), verify and rebase, decide.
    private func rebase(_ claim: OutboxClaim, _ item: OutboxItem, _ run: inout FlushRun) async throws -> RebaseResult {
        let sender = claim.sender
        let itemId = item.id
        let failure = try await uncancellable { db, now, _ in
            try OutboxFlush.verify(db, itemId: itemId, sender: sender, now: now)
        }
        if failure != nil { return .done(.superseded) }
        let request = try OutboxFlush.refetch(for: item, expecting: claim.expecting, timeout: timeout(run))
        guard let response = await send(request, deadline: run.deadline) else {
            return .done(Task.isCancelled ? .cancelled : .budgetExhausted)
        }
        run.report.requests += 1
        let resolution: OutboxResolution
        switch response.outcome {
        case .success(let fetched):
            let step = try await uncancellable { db, now, wall in
                try OutboxFlush.rebase(db, itemId: itemId, sender: sender, fetched: fetched, now: now, wall: wall)
            }
            switch step {
            case .fenced: return .done(.superseded)
            case .resend(let rebased): return .resend(rebased)
            case .conflict:
                run.report.failed += 1
                return .done(nil)
            }
        case .identityMismatch:
            // The write was refused by stale_revision, so nothing executed whatever the GET says.
            resolution = .restore(.identity)
        case .epochMismatch:
            resolution = .restore(.epoch)
        case .notFound:
            resolution = OutboxResolution.resolve(item.kind, .notFound(nil))
        case .retryable(.noResponse), .uncertain(.noResponse):
            resolution = .retry(maybeDelivered: true)
        default:
            // Any other answer to the GET: the write didn't execute; retry it later.
            resolution = .retry(maybeDelivered: false)
        }
        return .done(
            try await finish(
                claim, resolution, error: response.outboxError, stopsPass: response.outcome.stopsPass, &run))
    }

    /// The outcome transaction and the pass decision.
    private func finish(
        _ claim: OutboxClaim, _ resolution: OutboxResolution, error: OutboxErrorInfo?, stopsPass: Bool,
        _ run: inout FlushRun
    ) async throws -> OutboxFlushReport.Ending? {
        let (itemId, sender, jitter) = (claim.item.id, claim.sender, random())
        let applied = try await uncancellable { db, now, wall in
            try OutboxFlush.apply(
                db, itemId: itemId, sender: sender, resolution: resolution, error: error, random: jitter, now: now,
                wall: wall)
        }
        switch applied {
        case .fenced: return .superseded
        case .acked: run.report.acked += 1
        case .failed: run.report.failed += 1
        case .retried: run.report.retried += 1
        case .retired, .restored, .cancelled: run.report.settled += 1
        }
        switch resolution {
        case .retire(pull: true), .fail(_, pull: true): run.signal(.pullRequested)
        case .restore(let mismatch), .mismatchUncertain(let mismatch):
            run.signal(mismatch == .identity ? .identityMismatch : .epochSuspect)
            return .mismatch(mismatch)
        default: break
        }
        return stopsPass ? .unreachable : nil
    }

    private func timeout(_ run: FlushRun) -> Duration {
        min(Self.requestTimeout, max(.zero, run.deadline - ContinuousClock.now))
    }

    /// Sends `request`, racing the budget and the task's cancellation. The request runs in its own
    /// task, so no wait here depends on the sender honouring cancellation:
    /// 1. until the deadline or a cancellation, the answer is awaited;
    /// 2. then the request is cancelled, and whatever it returns within `shutdownGrace` is still
    ///    kept if it is an answer (a response that lands during shutdown isn't lost);
    /// 3. after that the flusher stops listening. Nil: the release makes the item `uncertain`
    ///    and frees the lease, and a later completion is never applied (and would fail the sender
    ///    check anyway once the claim or lease has moved on).
    private func send(_ request: OutboxRequest, deadline: ContinuousClock.Instant) async -> APIResponse<
        OutboxSuccess
    >? {
        let sender = sender
        let call = Task { await sender.send(request) }
        if let response = await Self.result(of: call, until: deadline, stopsOnCancellation: true) {
            return Self.isAnswer(response) ? response : nil
        }
        call.cancel()
        let grace = ContinuousClock.now.advanced(by: shutdownGrace)
        guard let response = await Self.result(of: call, until: grace, stopsOnCancellation: false) else { return nil }
        return Self.isAnswer(response) ? response : nil
    }

    /// `call`'s result if it finishes before `deadline` (and, with `stopsOnCancellation`, before
    /// the current task is cancelled); nil otherwise, without waiting for `call` any longer.
    private static func result<T: Sendable>(
        of call: Task<T, Never>, until deadline: ContinuousClock.Instant, stopsOnCancellation: Bool
    ) async -> T? {
        let first = FirstResult<T>()
        let waiter = Task { first.offer(await call.value) }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            first.offer(nil)
        }
        defer {
            waiter.cancel()
            timer.cancel()
        }
        guard stopsOnCancellation else { return await first.value() }
        return await withTaskCancellationHandler {
            await first.value()
        } onCancel: {
            first.offer(nil)
        }
    }

    /// Anything but the cancellation of the request itself is an answer and is applied.
    private static func isAnswer(_ response: APIResponse<OutboxSuccess>) -> Bool {
        switch response.outcome {
        case .retryable(.noResponse(.cancelled)), .uncertain(.noResponse(.cancelled)): false
        default: true
        }
    }

    // MARK: - Transactions

    /// One `IMMEDIATE` transaction, with lease time sampled inside it (after `BEGIN IMMEDIATE`).
    private func write<T: Sendable>(
        _ body: @escaping @Sendable (Database, LeaseInstant, Date) throws -> T
    ) async throws -> T {
        let (clock, wallClock) = (store.leaseClock, store.wallClock)
        return try await writer.write { db in try body(db, clock.now(), wallClock.now()) }
    }

    /// `write`, from an unstructured task, so the caller's cancellation can't stop it.
    private func uncancellable<T: Sendable>(
        _ body: @escaping @Sendable (Database, LeaseInstant, Date) throws -> T
    ) async throws -> T {
        let outbox = self
        return try await Task { try await outbox.write(body) }.value
    }
}

/// The first value offered wins; `value()` waits for it. Later offers are ignored.
private final class FirstResult<T: Sendable>: Sendable {
    private let state = Mutex<(value: T??, waiters: [CheckedContinuation<T?, Never>])>((nil, []))

    func offer(_ value: T?) {
        let waiters = state.withLock { state -> [CheckedContinuation<T?, Never>] in
            guard state.value == nil else { return [] }
            state.value = .some(value)
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    func value() async -> T? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> T?? in
                if let value = state.value { return .some(value) }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
