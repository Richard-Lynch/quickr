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
        /// This build is below the server's minimum (client-versions.md §4.1): nothing was
        /// claimed, or the item sent was restored, and `flush` is released. Enqueue still works.
        case clientOutdated
    }

    public var ending: Ending
    /// HTTP requests made, refetches included.
    public var requests = 0
    public var acked = 0
    public var failed = 0
    public var retried = 0
    /// Retired, cancelled (S8) or restored after a precondition 409.
    public var settled = 0
    /// Restored after a 426 `client_outdated`, for the updated build (client-versions.md §4.1).
    public var held = 0
    /// Acked run events the server voided for a reason the user is told about (timers.md §8.1,
    /// §11.4), in ack order.
    public var runVoids: [RunVoid] = []
    /// When `flush` started, and when it was done: the lease released (or never taken), before
    /// signals are delivered. What the budget bounds (§10), measured by the flush itself, so a
    /// caller resumed late doesn't stretch it.
    public var startedAt: ContinuousClock.Instant?
    public var endedAt: ContinuousClock.Instant?

    public init(ending: Ending) { self.ending = ending }

    /// `endedAt - startedAt`, the flush's own duration.
    public var elapsed: Duration? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt - startedAt
    }
}

/// A run event of this device that the server voided with a reason worth a notice (timers.md
/// §11.4): `after_stop`, `run_edited`, `entry_deleted` or `already_closed`. Double taps (`stale`,
/// `merged`, `already_paused`, `not_paused`) are silent and never reported.
public struct RunVoid: Sendable, Hashable {
    public static let noticed: Set<VoidReason> = [.afterStop, .runEdited, .entryDeleted, .alreadyClosed]

    public var eventId: String
    public var runId: String
    public var topic: TopicRef
    public var type: RunEventType
    public var reason: VoidReason
    /// The origin of the tap (which process made it).
    public var origin: OutboxOrigin
    /// The run's end (epoch ms), when the server says it stopped: `after_stop`'s "at {time}".
    public var stoppedAt: Int?

    init?(_ item: OutboxItem, _ result: RunEventResult) {
        guard let reason = result.effect.reason, Self.noticed.contains(reason),
            let payload = try? item.runEventPayload(), let type = payload.type
        else { return nil }
        self.init(
            eventId: item.id, runId: payload.runId, topic: payload.topic, type: type, reason: reason,
            origin: item.origin, stoppedAt: result.run.endedAt)
    }

    public init(
        eventId: String, runId: String, topic: TopicRef, type: RunEventType, reason: VoidReason, origin: OutboxOrigin,
        stoppedAt: Int? = nil
    ) {
        self.eventId = eventId
        self.runId = runId
        self.topic = topic
        self.type = type
        self.reason = reason
        self.origin = origin
        self.stoppedAt = stoppedAt
    }
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
        var scope = OutboxScope(aliases: try OutboxScope.aliases(db))
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
    /// Kept out of a budget for the release transaction (at most 10 % of the budget).
    public static let cleanupReserve: Duration = .milliseconds(250)
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
    /// How long a flush whose request deadline passed still listens for the answer to the
    /// request it cancelled (at most 20 % of the budget, and inside it). A cancelled flush doesn't
    /// wait.
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
    /// Fix (§11). `overriding`: the fields the user corrected in a refused edit; later queued
    /// edits of the entity drop them, so the correction is the latest word (see `OutboxQueue.fix`).
    public func fix(
        itemId: String, payload: OutboxPayload, rowVersion: Int, overriding: EntryOverride? = nil
    ) async throws {
        try await write { db, _, wall in
            try OutboxQueue.fix(
                db, itemId: itemId, payload: payload, rowVersion: rowVersion, overriding: overriding, wall: wall)
        }
    }

    /// Fix of a refused run event (timers.md §8.1): replaces a failed `finish`'s (or a `stop`
    /// with answers') answers and notes, nothing else, and makes it pending again, in one
    /// transaction (CAS on `rowVersion`, as `fix`). `OutboxError.notAllowed` for any other item;
    /// `OutboxError.itemChanged` when it moved since it was read.
    public func fixRunEvent(
        itemId: String, rowVersion: Int, answers: [String: AnswerValue], notes: String?
    ) async throws {
        try await write { db, _, wall in
            let item = try OutboxStorage.item(db, id: itemId)
            guard let item, var payload = try item.runEventPayload() else {
                throw OutboxError.notAllowed("Fix isn't available for this item")
            }
            payload.event.answers = answers.mapValues { WireAnswer($0) }
            payload.event.notes = notes
            try OutboxQueue.fix(db, itemId: itemId, payload: .runEvent(payload), rowVersion: rowVersion, wall: wall)
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
    ///
    /// `budget` bounds the network work and every new piece of work (§10): lease polling, claims,
    /// requests and post-send verify or rebase steps stop early enough to leave the shutdown
    /// grace and the release inside it, and a cancellation (an expiration handler) releases at
    /// once. Two transactions always run because they make the item state correct: the outcome of
    /// an answer already received, and the release. Under write contention from another process
    /// each can wait up to SQLite's busy timeout (5 s), so choose a budget with headroom below
    /// the process's real limit (extensions use 4–5 s of a ~30 s window).
    ///
    /// `shouldProceed` is asked once the lease is held, before anything is claimed: false releases
    /// it and ends `.paused` (the notification handler flushes a store only while it is the active
    /// one, notifications.md §7.1 step 10).
    public func flush(
        force: Bool, budget: Duration, leaseWait: Duration = .zero,
        shouldProceed: (@Sendable () async -> Bool)? = nil
    ) async throws -> OutboxFlushReport {
        let start = ContinuousClock.now
        let grace = min(shutdownGrace, budget * 0.2)
        let requestDeadline = start.advanced(by: max(.zero, budget - grace - min(Self.cleanupReserve, budget * 0.1)))
        // One absolute end for every wait on a request of this flush: grace never restarts.
        let shutdownDeadline = requestDeadline.advanced(by: grace)
        let pollUntil = min(start.advanced(by: leaseWait), requestDeadline)
        guard let lease = try await acquireFlushLease(until: pollUntil, requestDeadline: requestDeadline) else {
            var report = OutboxFlushReport(ending: .busy)
            report.startedAt = start
            report.endedAt = ContinuousClock.now
            return report
        }

        var run = FlushRun(
            lease: lease, deadline: requestDeadline, shutdownDeadline: shutdownDeadline, force: force)
        run.report.startedAt = start
        var failure: (any Error)?
        do {
            if let shouldProceed, await !shouldProceed() {
                run.report.ending = .paused
            } else {
                run.report.ending = try await pass(&run)
            }
        } catch is CancellationError {
            run.report.ending = .cancelled
        } catch {
            failure = error
        }
        let current = run.current
        try? await uncancellable { db, _, wall in
            try OutboxFlush.release(db, lease: lease, current: current, wall: wall)
        }
        run.report.endedAt = ContinuousClock.now
        for signal in run.signals { onSignal(signal) }
        if let failure { throw failure }
        return run.report
    }

    /// Polls `flush` until `until`. Every attempt, the first and the one after the last sleep
    /// included, is made only while the request deadline hasn't passed: no lease (and so no
    /// takeover recovery) is taken by a flush that has no time left to use it.
    private func acquireFlushLease(until: ContinuousClock.Instant, requestDeadline: ContinuousClock.Instant)
        async throws -> LeaseClaim?
    {
        let leases = store.leases
        let takeover = OutboxFlush.takeover(wallClock: store.wallClock)
        while ContinuousClock.now < requestDeadline {
            if let lease = try await leases.tryAcquire(.flush, owner: owner, takeover: takeover) { return lease }
            let now = ContinuousClock.now
            guard now < until else { return nil }
            try await Task.sleep(for: min(.milliseconds(50), until - now))
        }
        return nil
    }

    private struct FlushRun {
        let lease: LeaseClaim
        /// When requests stop: the budget minus the shutdown grace and the cleanup reserve. No
        /// request (a resend or a refetch included) starts after it.
        let deadline: ContinuousClock.Instant
        /// `deadline` plus the grace: the last moment any request of this flush is listened to.
        let shutdownDeadline: ContinuousClock.Instant
        let force: Bool
        var report = OutboxFlushReport(ending: .drained)
        /// The item this flusher holds in flight, if any.
        var current: (itemId: String, token: String)?
        var attempted: Set<String> = []
        var signals: [OutboxSignal] = []

        init(
            lease: LeaseClaim, deadline: ContinuousClock.Instant, shutdownDeadline: ContinuousClock.Instant, force: Bool
        ) {
            self.lease = lease
            self.deadline = deadline
            self.shutdownDeadline = shutdownDeadline
            self.force = force
        }

        mutating func signal(_ signal: OutboxSignal) {
            if !signals.contains(signal) { signals.append(signal) }
        }
    }

    private func pass(_ run: inout FlushRun) async throws -> OutboxFlushReport.Ending {
        if ContinuousClock.now < run.deadline {
            _ = try await write { db, now, wall in
                try OutboxQueue.releaseHolds(db, all: false, now: now, wall: wall)
            }
        }
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
            case .clientOutdated: return .clientOutdated
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
            guard let response = await send(request, run) else {
                return Task.isCancelled ? .cancelled : .budgetExhausted
            }
            run.report.requests += 1
            let resolution = OutboxResolution.resolve(
                item.kind, response.outcome, runEvent: (try? item.runEventPayload())?.type)
            if resolution == .startKnown { return try await checkStart(claim, item, refused: response, &run) }
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
        // Post-send steps start only before the shutdown deadline; past it the release takes over.
        guard ContinuousClock.now < run.shutdownDeadline else { return .done(.budgetExhausted) }
        let failure = try await uncancellable { db, now, _ in
            try OutboxFlush.verify(db, itemId: itemId, sender: sender, now: now)
        }
        if failure != nil { return .done(.superseded) }
        let request = try OutboxFlush.refetch(for: item, expecting: claim.expecting, timeout: timeout(run))
        guard let response = await send(request, run) else {
            return .done(Task.isCancelled ? .cancelled : .budgetExhausted)
        }
        run.report.requests += 1
        let resolution: OutboxResolution
        switch response.outcome {
        case .success(let fetched):
            guard ContinuousClock.now < run.shutdownDeadline else { return .done(.budgetExhausted) }
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
        case .clientOutdated(let minimum):
            resolution = .hold(minimum: minimum)
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

    /// A start the server refused as a known id (`startKnown`, timers.md §10.2), verified like a
    /// rebase: read the run with that id (an alias resolves). A run of the start's topic means
    /// it was started elsewhere: the item is acked with that run, as a merged start would be (the
    /// run, and its alias, go into the server layer), and a pull brings the rest (its entry). With
    /// `id_conflict` the id may be an entry's instead: one of the start's topic means this
    /// reminder was already logged and the run never existed (`loggedElsewhere`: the start and the
    /// run's other items fail `logged_elsewhere`), and a pull is asked for. Anything else (no such
    /// run or entry, or another topic's) fails the start `rejected` with the refusal kept; a
    /// terminal refusal of the read fails it with the read's error. In the run case the run's other queued
    /// taps aren't touched: they go to the server's run. The pull is asked for only when the ack
    /// applied.
    private func checkStart(
        _ claim: OutboxClaim, _ item: OutboxItem, refused: APIResponse<OutboxSuccess>, _ run: inout FlushRun
    ) async throws -> OutboxFlushReport.Ending? {
        let sender = claim.sender
        let itemId = item.id
        guard ContinuousClock.now < run.shutdownDeadline else { return .budgetExhausted }
        let fenced = try await uncancellable { db, now, _ in
            try OutboxFlush.verify(db, itemId: itemId, sender: sender, now: now)
        }
        if fenced != nil { return .superseded }
        let rejected: OutboxResolution = .fail(.rejected, pull: false)
        guard let runId = UUID(uuidString: item.entityId), let topicId = UUID(uuidString: item.topicId) else {
            return try await finish(claim, rejected, error: refused.outboxError, stopsPass: false, &run)
        }
        var reads: [OutboxOperation] = [.getRun(runId: runId)]
        if case .terminal(_, let problem) = refused.outcome, problem?.code == .idConflict {
            reads.append(.getEntry(entryId: runId))
        }
        for operation in reads {
            let request = OutboxRequest(operation: operation, expecting: claim.expecting, timeout: timeout(run))
            guard let response = await send(request, run) else {
                return Task.isCancelled ? .cancelled : .budgetExhausted
            }
            run.report.requests += 1
            let resolution: OutboxResolution
            switch response.outcome {
            case .success(.run(let server)) where server.topicId == topicId:
                let effect = Self.startKnownEffect(server, startId: itemId)
                resolution = .ack(.runEvent(RunEventResult(eventId: itemId, effect: effect, run: server, entry: nil)))
            case .success(.entry(let entry)) where entry.topicId == topicId:
                resolution = .loggedElsewhere
            case .success, .notFound:
                continue  // not this topic's, or not there: the next read, or the refusal stands
            case .identityMismatch:
                resolution = .restore(.identity)
            case .epochMismatch:
                resolution = .restore(.epoch)
            case .clientOutdated(let minimum):
                resolution = .hold(minimum: minimum)
            case .terminal, .entryDeleted, .staleRevision:
                // The read itself is refused for good: the start fails with the read's error.
                return try await finish(
                    claim, rejected, error: response.outboxError ?? refused.outboxError, stopsPass: false, &run)
            default:
                // The start didn't execute (409); check again on the next attempt.
                resolution = .retry(maybeDelivered: false)
            }
            let acks: Bool = if case .ack = resolution { true } else { false }
            return try await finish(
                claim, resolution, error: response.outboxError ?? refused.outboxError,
                stopsPass: response.outcome.stopsPass, pullOnAck: acks, &run)
        }
        return try await finish(claim, rejected, error: refused.outboxError, stopsPass: false, &run)
    }

    /// The effect a start acked by `checkStart` gets: the server's for its id (applied for the run's
    /// own start, `merged` for an alias), or `merged` when the run doesn't list it.
    static func startKnownEffect(_ server: Run, startId: String) -> RunEffect {
        server.state.effects[startId.lowercased()] ?? .void(.merged)
    }

    /// The outcome transaction and the pass decision.
    /// `pullOnAck`: ask for a pull when (and only when) the ack applied.
    private func finish(
        _ claim: OutboxClaim, _ resolution: OutboxResolution, error: OutboxErrorInfo?, stopsPass: Bool,
        pullOnAck: Bool = false, _ run: inout FlushRun
    ) async throws -> OutboxFlushReport.Ending? {
        let (itemId, sender, jitter) = (claim.item.id, claim.sender, random())
        let item = claim.item
        let applied = try await uncancellable { db, now, wall in
            let applied = try OutboxFlush.apply(
                db, itemId: itemId, sender: sender, resolution: resolution, error: error, random: jitter, now: now,
                wall: wall)
            // The notice is kept with the ack (timers.md §11.4), whichever process flushed it.
            if applied == .acked, case .ack(.runEvent(let result)) = resolution, let void = RunVoid(item, result) {
                try RunNoticeStorage.record(db, void, wall: wall)
            }
            return applied
        }
        switch applied {
        case .fenced: return .superseded
        case .acked:
            run.report.acked += 1
            if pullOnAck { run.signal(.pullRequested) }
            if case .ack(.runEvent(let result)) = resolution, let void = RunVoid(claim.item, result) {
                run.report.runVoids.append(void)
            }
        case .failed: run.report.failed += 1
        case .retried: run.report.retried += 1
        case .restored where resolution.isHold: run.report.held += 1
        case .retired, .restored, .cancelled: run.report.settled += 1
        }
        switch resolution {
        case .retire(pull: true), .fail(_, pull: true), .loggedElsewhere: run.signal(.pullRequested)
        case .restore(let mismatch), .mismatchUncertain(let mismatch):
            run.signal(mismatch == .identity ? .identityMismatch : .epochSuspect)
            return .mismatch(mismatch)
        case .hold:
            return .clientOutdated
        default: break
        }
        return stopsPass ? .unreachable : nil
    }

    private func timeout(_ run: FlushRun) -> Duration {
        min(Self.requestTimeout, max(.zero, run.deadline - ContinuousClock.now))
    }

    /// Sends `request`, racing the flush's deadlines and the task's cancellation. Nothing starts
    /// once the request deadline has passed or the task is cancelled: the item stays claimed for
    /// the release. The request runs in its own task, so no wait here depends on the sender
    /// honouring cancellation:
    /// 1. until the request deadline or a cancellation, the answer is awaited;
    /// 2. at the request deadline the request is cancelled, and whatever it returns before the
    ///    flush's one shutdown deadline (reserved inside the budget) is still kept if it is an
    ///    answer;
    /// 3. on a cancellation (the OS is about to suspend the process) nothing more is awaited.
    /// Nil: the release makes the item `uncertain` and frees the lease. A later completion is
    /// never applied (and would fail the sender check once the claim or lease moves on); if the
    /// server committed, the next flush reconciles through the idempotent resend or pull-ack.
    private func send(_ request: OutboxRequest, _ run: FlushRun) async -> APIResponse<OutboxSuccess>? {
        guard ContinuousClock.now < run.deadline, !Task.isCancelled else { return nil }
        let sender = sender
        let call = Task { await sender.send(request) }
        if let response = await Self.result(of: call, until: run.deadline, stopsOnCancellation: true) {
            return Self.isAnswer(response) ? response : nil
        }
        call.cancel()
        guard !Task.isCancelled else { return nil }
        guard let response = await Self.result(of: call, until: run.shutdownDeadline, stopsOnCancellation: true)
        else { return nil }
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

extension LocalStore {
    /// A reminder action's log (notifications.md §7.1 step 5, §7.4): `entry.create` with the
    /// reminder's shared id, unless that id is already queued, on the server or tombstoned; then
    /// nothing is written (the first answer wins). The check and the enqueue are one `IMMEDIATE`
    /// transaction, so racing actions log once. A retired file throws `StoreError.retired` before
    /// anything is looked at. Needs no sender: the caller flushes (or not) on its own.
    public func createEntryIfAbsent(id: UUID, topic: TopicRef, body: EntryCreateDTO, origin: OutboxOrigin)
        async throws -> OutboxCreateOnceResult
    {
        var body = body
        body.id = nil
        body.source = origin.source  // what the request will carry (outbox.md §4)
        let item = NewOutboxItem(id: id, payload: .entryCreate(topic: topic, body: body), origin: origin)
        let entryId = id.wireString
        let (clock, wallClock) = (leaseClock, self.wallClock)
        return try await writer.write { db in
            if try StoreFence.isRetired(db) { throw StoreError.retired }
            if try !OutboxStorage.items(db, entityKind: .entry, entityId: entryId).isEmpty {
                return .duplicate(.queued)
            }
            if try ServerLayer.isTombstoned(db, kind: .entry, id: entryId) { return .duplicate(.deleted) }
            if try ServerLayer.revision(db, entityKind: .entry, id: entryId) != nil { return .duplicate(.onServer) }
            let enqueued = try OutboxQueue.enqueue(db, item, holdFor: nil, now: clock.now(), wall: wallClock.now())
            guard case .appended(let appended) = enqueued else {
                throw OutboxError.notAllowed("a create is never coalesced")
            }
            return .created(appended)
        }
    }
}
