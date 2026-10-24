import Foundation
import GRDB
import QuickrCore

/// A tap on a run (every event but `start`, timers.md §3.2).
public enum RunTapType: String, Sendable, Hashable, CaseIterable {
    case next, lap, skip, pause, resume, stop, finish, discard
}

/// What the user saw when they tapped: the open segment, the step a Skip names, and whether the
/// run was paused (and by which pause). A tap whose target has moved since (a double tap read
/// after the first was queued) is dropped, as the fold would void it (`stale`, `already_paused`,
/// `not_paused`, §4.2). Stop, discard and finish don't use it: their repeats are void
/// (`already_closed`) or idempotent.
public struct RunTapExpect: Sendable, Hashable {
    public var seg: Int?
    public var step: String?
    public var paused: Bool
    public var pauseId: String?

    public init(seg: Int?, step: String?, paused: Bool, pauseId: String?) {
        self.seg = seg
        self.step = step
        self.paused = paused
        self.pauseId = pauseId
    }

    /// What a screen showing `run` shows: the open segment, the step a Skip would name, and the
    /// pause a Resume would end.
    public init(_ run: LocalRun) {
        let open = run.state.open
        self.init(
            seg: open?.index, step: open?.kind == .step ? open?.step : run.state.nextStep,
            paused: run.state.pausedSince != nil, pauseId: run.openPauseId)
    }
}

/// Where a tap's `seg`, `step` and `pause_id` come from.
public enum RunTapTarget: Sendable, Hashable {
    /// The run's state in the local view, at the tap.
    case current
    /// The local view, unless the target moved since the user saw it (`RunTapExpect`): then
    /// nothing is enqueued. The app's run screen and tile.
    case expect(RunTapExpect)
    /// What a surface with its own copy of the state showed (a Live Activity's or a widget's
    /// content state, timers.md §10.3): sent as is, and a stale one is void on the server and in
    /// the fold. A nil field falls back to the local view.
    case shown(seg: Int?, step: String?, pauseId: String?)
}

/// What a start did.
public struct RunStartResult: Sendable, Hashable {
    /// The run the tap went to: the new one, or the topic's open run. For a given id that was
    /// already known it is that id, which may now be an entry's (the run stopped) or an alias.
    public var runId: String
    /// The queued start; nil when nothing was enqueued: the topic already had an open run here
    /// (the tap routes to it, timers.md §4.5), or the given id was already known (a reminder
    /// already started, §10.2).
    public var item: OutboxItem?

    public var started: Bool { item != nil }
}

/// What Auto did (timers.md §11.1): idle → Start; a named step remains → Next; otherwise → Stop.
public enum RunAutoResult: Sendable, Hashable {
    case started(RunStartResult)
    /// The tap on the open run, and what it enqueued (nil: nothing).
    case tapped(RunTapType, runId: String, OutboxEnqueueResult?)
}

/// The write façade for runs, used by every surface (the app, widgets, Controls, the Action button,
/// Siri, the notification Start; timers.md §8.1, §8.3): each call is one `run.event` outbox item,
/// committed in one `IMMEDIATE` transaction, so taps from every process are serialised by the
/// store and each reads the local view as the one before it left it. It needs no sender: the
/// caller flushes (or not) on its own.
///
/// - **Time (§5.1).** The tap's device time is read when the call is made, before waiting for the
///   transaction, so a tap is never stamped late behind a flush or another tap. Inside, `at` =
///   that time + `sync_state.server_offset_ms`, clamped to just after the latest `at` the run has
///   here (`max(at, latest + 1)`, its queued and failed items included), so a device's own taps
///   stay in order.
/// - **One start per topic (§4.5).** A start for a topic whose local view has an open run enqueues
///   nothing and routes to that run; a start with a given id (a reminder's) that this store
///   already knows (an item, a run or alias, a tombstone, or an entry with that id) enqueues
///   nothing either.
/// - **Targets.** `seg`, `step` and `pause_id` come from the local view, which includes every
///   earlier queued tap (`RunTapTarget`).
/// - **`device`** (§3.2, §10.3) is stamped on every event.
///
/// Errors: `StoreError.retired` if the store was reset; GRDB's.
public struct RunWrites: Sendable {
    public let store: LocalStore
    public let origin: OutboxOrigin
    /// The `device` of every event: this device's APNs token, and whether it shows the run's
    /// Live Activity locally. Nil sends none (no token yet).
    public var device: @Sendable () async -> RunEventInDTO.Device?
    /// The device clock, epoch milliseconds.
    public var now: @Sendable () -> Int

    public init(
        store: LocalStore, origin: OutboxOrigin,
        device: @escaping @Sendable () async -> RunEventInDTO.Device? = { nil },
        now: (@Sendable () -> Int)? = nil
    ) {
        self.store = store
        self.origin = origin
        self.device = device
        self.now = now ?? { [wall = store.wallClock] in RunInstant.milliseconds(wall.now()) }
    }

    // MARK: - Start

    /// Starts a run of `topic` pinned to `version`, unless the topic already has an open run here.
    /// `id` is the run id (a reminder's Start derives it from the slot, §10.2); a new one by
    /// default.
    @discardableResult
    public func start(topic: TopicRef, version: Int, id: UUID? = nil, meta: [String: String]? = nil) async throws
        -> RunStartResult
    {
        let tapAt = now()
        let device = await device()
        let origin = origin
        return try await write { db, now, wall in
            try Self.start(
                db, topic: topic, version: version, id: id, meta: meta, tapAt: tapAt, device: device, origin: origin,
                now: now, wall: wall)
        }
    }

    // MARK: - Taps

    /// One tap on the run `runId` routes to (its id or an alias). Nil when nothing was enqueued:
    /// the run isn't in the local view (except for a finish, below), its state has no target for
    /// the tap (no open segment, no step to skip, no pause to resume, a finish of a run that hasn't
    /// stopped), or with `.expect` the target moved. A finish of a run that left the view (it
    /// stopped, so its entry exists) is still enqueued: the server applies or voids it (§3.6). A
    /// discard of a run the server never saw drops the run's items instead (K6, `.cancelled`).
    @discardableResult
    public func tap(
        _ type: RunTapType, runId: String, target: RunTapTarget = .current, answers: [String: AnswerValue]? = nil,
        notes: String? = nil, meta: [String: String]? = nil
    ) async throws -> OutboxEnqueueResult? {
        let tapAt = now()
        let device = await device()
        let origin = origin
        let body = Body(answers: answers, notes: notes, meta: meta)
        return try await write { db, now, wall in
            guard let run = try RunOverlay.localRun(db, id: runId) else {
                guard type == .finish else { return nil }
                return try Self.finishClosed(
                    db, runId: runId.lowercased(), body: body, tapAt: tapAt, device: device, origin: origin, now: now,
                    wall: wall)
            }
            return try Self.tap(
                db, type, run: run, target: target, body: body, tapAt: tapAt, device: device, origin: origin,
                now: now, wall: wall)
        }
    }

    @discardableResult
    public func next(runId: String, target: RunTapTarget = .current) async throws -> OutboxEnqueueResult? {
        try await tap(.next, runId: runId, target: target)
    }

    @discardableResult
    public func lap(runId: String, target: RunTapTarget = .current) async throws -> OutboxEnqueueResult? {
        try await tap(.lap, runId: runId, target: target)
    }

    @discardableResult
    public func skip(runId: String, target: RunTapTarget = .current) async throws -> OutboxEnqueueResult? {
        try await tap(.skip, runId: runId, target: target)
    }

    @discardableResult
    public func pause(runId: String, target: RunTapTarget = .current) async throws -> OutboxEnqueueResult? {
        try await tap(.pause, runId: runId, target: target)
    }

    @discardableResult
    public func resume(runId: String, target: RunTapTarget = .current) async throws -> OutboxEnqueueResult? {
        try await tap(.resume, runId: runId, target: target)
    }

    /// Ends the clock at the tap. Every surface stops without answers; the form sends them as
    /// `finish` (§3.6).
    @discardableResult
    public func stop(runId: String, answers: [String: AnswerValue]? = nil, notes: String? = nil) async throws
        -> OutboxEnqueueResult?
    {
        try await tap(.stop, runId: runId, answers: answers, notes: notes)
    }

    /// The run's answers (and notes), after its stop (§3.6).
    @discardableResult
    public func finish(runId: String, answers: [String: AnswerValue], notes: String? = nil) async throws
        -> OutboxEnqueueResult?
    {
        try await tap(.finish, runId: runId, answers: answers, notes: notes)
    }

    @discardableResult
    public func discard(runId: String) async throws -> OutboxEnqueueResult? {
        try await tap(.discard, runId: runId)
    }

    /// Auto (§11.1), in one transaction: no open run → Start; a named step remains after the open
    /// segment → Next; otherwise → Stop. A finishing run isn't open, so Auto starts a new run then
    /// (the finishing one keeps waiting for its answers).
    @discardableResult
    public func auto(topic: TopicRef, version: Int) async throws -> RunAutoResult {
        let tapAt = now()
        let device = await device()
        let origin = origin
        return try await write { db, now, wall in
            guard let run = try RunOverlay.openRun(db, topicId: topic.id) else {
                return .started(
                    try Self.start(
                        db, topic: topic, version: version, id: nil, meta: nil, tapAt: tapAt, device: device,
                        origin: origin, now: now, wall: wall))
            }
            let type: RunTapType = run.state.nextStep != nil ? .next : .stop
            let result = try Self.tap(
                db, type, run: run, target: .current, body: Body(), tapAt: tapAt, device: device, origin: origin,
                now: now, wall: wall)
            return .tapped(type, runId: run.id, result)
        }
    }

    // MARK: - Transactions

    struct Body: Sendable {
        var answers: [String: AnswerValue]?
        var notes: String?
        var meta: [String: String]?
    }

    private func write<T: Sendable>(
        _ body: @escaping @Sendable (Database, LeaseInstant, Date) throws -> T
    ) async throws -> T {
        let (clock, wallClock) = (store.leaseClock, store.wallClock)
        return try await store.writer.write { db in try body(db, clock.now(), wallClock.now()) }
    }

    static func start(
        _ db: Database, topic: TopicRef, version: Int, id: UUID?, meta: [String: String]?, tapAt: Int,
        device: RunEventInDTO.Device?, origin: OutboxOrigin, now: LeaseInstant, wall: Date
    ) throws -> RunStartResult {
        if try StoreFence.isRetired(db) { throw StoreError.retired }
        let runId = (id ?? UUID()).wireString
        if id != nil, try isKnown(db, runId: runId) { return RunStartResult(runId: runId, item: nil) }
        if let open = try RunOverlay.openRun(db, topicId: topic.id) { return RunStartResult(runId: open.id, item: nil) }
        let event = RunEventInDTO(
            id: runId, type: RunEventType.start.rawValue, at: RunInstant.format(try stamp(db, tapAt, ats: [])),
            topicId: topic.id, version: version, meta: meta, device: device)
        let item = NewOutboxItem(
            id: try .wire(runId, "run id"),
            payload: .runEvent(RunEventPayload(topic: topic, runId: runId, event: event)),
            origin: origin)
        guard case .appended(let queued) = try OutboxQueue.enqueue(db, item, holdFor: nil, now: now, wall: wall) else {
            throw OutboxError.notAllowed("a start is never coalesced")
        }
        return RunStartResult(runId: runId, item: queued)
    }

    /// The id is already used: an item with it (any state), a run or alias, a run tombstone, or an
    /// entry (or entry tombstone) with it. Runs and entries share one id space (§3.3).
    static func isKnown(_ db: Database, runId: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM outbox_item WHERE id = ?)
                    OR EXISTS (SELECT 1 FROM run WHERE id = ?)
                    OR EXISTS (SELECT 1 FROM run_alias WHERE id = ?)
                    OR EXISTS (SELECT 1 FROM entry WHERE id = ?)
                    OR EXISTS (SELECT 1 FROM tombstone WHERE kind IN ('run', 'entry') AND id = ?)
                """,
            arguments: [runId, runId, runId, runId, runId]) ?? false
    }

    static func tap(
        _ db: Database, _ type: RunTapType, run: LocalRun, target: RunTapTarget, body: Body, tapAt: Int,
        device: RunEventInDTO.Device?, origin: OutboxOrigin, now: LeaseInstant, wall: Date
    ) throws -> OutboxEnqueueResult? {
        if try StoreFence.isRetired(db) { throw StoreError.retired }
        guard var fields = Self.target(run, type) else { return nil }
        switch target {
        case .current:
            break
        case .expect(let expect):
            if moved(run, type, fields, expect) { return nil }
        case .shown(let seg, let step, let pauseId):
            fields.seg = fields.seg == nil ? nil : seg ?? fields.seg
            fields.step = fields.step == nil ? nil : step ?? fields.step
            fields.pauseId = fields.pauseId == nil ? nil : pauseId ?? fields.pauseId
        }
        let topic = try run.topic ?? topicRef(db, run.topicId.wireString)
        guard let topic else { return nil }
        let carries = type == .stop || type == .finish
        let event = RunEventInDTO(
            id: UUID().wireString, type: type.rawValue,
            at: RunInstant.format(try stamp(db, tapAt, ats: try ats(db, run))), seg: fields.seg, step: fields.step,
            pauseId: fields.pauseId, answers: carries ? body.answers?.mapValues { WireAnswer($0) } : nil,
            notes: carries ? body.notes : nil, meta: body.meta, device: device)
        return try enqueue(db, event, topic: topic, runId: run.id, origin: origin, now: now, wall: wall)
    }

    /// A finish of a run that isn't in the view: it stopped, so its entry is here (§3.6). Nil when
    /// neither the entry nor its topic is.
    private static func finishClosed(
        _ db: Database, runId: String, body: Body, tapAt: Int, device: RunEventInDTO.Device?, origin: OutboxOrigin,
        now: LeaseInstant, wall: Date
    ) throws -> OutboxEnqueueResult? {
        if try StoreFence.isRetired(db) { throw StoreError.retired }
        guard
            let topicId = try String.fetchOne(db, sql: "SELECT topic_id FROM entry WHERE id = ?", arguments: [runId]),
            let topic = try topicRef(db, topicId)
        else { return nil }
        // A finish isn't folded: its `at` needs no clamp.
        let event = RunEventInDTO(
            id: UUID().wireString, type: RunEventType.finish.rawValue,
            at: RunInstant.format(try stamp(db, tapAt, ats: [])), answers: body.answers?.mapValues { WireAnswer($0) },
            notes: body.notes, meta: body.meta, device: device)
        return try enqueue(db, event, topic: topic, runId: runId, origin: origin, now: now, wall: wall)
    }

    private static func enqueue(
        _ db: Database, _ event: RunEventInDTO, topic: TopicRef, runId: String, origin: OutboxOrigin,
        now: LeaseInstant, wall: Date
    ) throws -> OutboxEnqueueResult {
        let item = NewOutboxItem(
            id: try .wire(event.id, "event id"),
            payload: .runEvent(RunEventPayload(topic: topic, runId: runId, event: event)), origin: origin)
        return try OutboxQueue.enqueue(db, item, holdFor: nil, now: now, wall: wall)
    }

    /// `at` = the tap's device time + the store's offset, clamped after `ats` (§5.1).
    static func stamp(_ db: Database, _ tapAt: Int, ats: [Int]) throws -> Int {
        let offset = try Int.fetchOne(db, sql: "SELECT server_offset_ms FROM sync_state WHERE id = 1") ?? 0
        return RunClock.stamp(deviceNow: tapAt, offset: offset, runAts: ats)
    }

    /// Every `at` of the run here: its view's events, and its failed items too (they may be
    /// retried, and must stay in tap order).
    private static func ats(_ db: Database, _ run: LocalRun) throws -> [Int] {
        let ids = [run.id] + run.aliases
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let failed = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM outbox_item
                WHERE kind = 'run.event' AND state = 'failed' AND entity_id IN (\(marks))
                """,
            arguments: StatementArguments(ids)
        ).compactMap { row in try OutboxItem(row: row).runEventPayload().flatMap { RunInstant.parse($0.event.at) } }
        return run.ats + failed
    }

    private static func topicRef(_ db: Database, _ topicId: String) throws -> TopicRef? {
        guard
            let row = try Row.fetchOne(db, sql: "SELECT id, slug, name FROM topic WHERE id = ?", arguments: [topicId]),
            let id = UUID(uuidString: row["id"])
        else { return nil }
        return TopicRef(id: id, slug: row["slug"], name: row["name"])
    }

    /// The fields a tap needs from the run's state (§3.2), or nil when the state has no target for
    /// it.
    struct Fields: Equatable {
        var seg: Int?
        var step: String?
        var pauseId: String?
    }

    static func target(_ run: LocalRun, _ type: RunTapType) -> Fields? {
        let open = run.state.open
        switch type {
        case .next, .lap:
            return open.map { Fields(seg: $0.index) }
        case .skip:
            guard let open, let step = open.kind == .step ? open.step : run.state.nextStep else { return nil }
            return Fields(seg: open.index, step: step)
        case .pause:
            return open == nil || run.state.pausedSince != nil ? nil : Fields()
        case .resume:
            return run.openPauseId.map { Fields(pauseId: $0) }
        case .stop:
            return run.isOpen ? Fields() : nil
        case .discard:
            return run.isOpen || run.status == .finishing ? Fields() : nil
        case .finish:
            return run.status == .finishing || run.status == .stopped ? Fields() : nil
        }
    }

    /// Whether the target moved since the user saw `expect`.
    static func moved(_ run: LocalRun, _ type: RunTapType, _ fields: Fields, _ expect: RunTapExpect) -> Bool {
        switch type {
        case .next, .lap: fields.seg != expect.seg
        case .skip: fields.seg != expect.seg || fields.step != expect.step
        case .pause: expect.paused || run.state.pausedSince != nil
        case .resume: !expect.paused || fields.pauseId != expect.pauseId?.lowercased()
        case .stop, .finish, .discard: false
        }
    }
}
