import Foundation
import GRDB
import QuickrCore

/// Keeps the pending run alerts equal to what `RunAlertPlan` wants (timers2.md §9.1).
///
/// Each `reconcile` compares the desired requests with the pending `quickr.alert.*` ones on
/// identifier, `fireAt` and content: it adds the missing, removes the stale and replaces the
/// changed (a pause, a resume or a corrected alert time moves `fireAt` under the same
/// identifier). A run that stops, is discarded, pauses or leaves the local view has no desired
/// requests, so all of its `quickr.alert.{run_id}.*` are cancelled; a lap leaves the old
/// segment's and schedules the new one's.
///
/// The app reconciles on every change to the local view (`LocalStore.observeRunAlerts`: this
/// device's taps and sync applying a page) and when it becomes active. A Live Activity push runs
/// no app code, so it is not a trigger (OQ-11). Calls are serialised; one that arrives while
/// another runs is coalesced into the next pass, which plans from the latest input.
public actor RunAlertScheduler {
    /// What the planner reads for each open run.
    public struct Subject: Sendable, Hashable {
        public var run: LocalRun
        /// The pinned version's timer; nil when that version isn't stored (no alerts then).
        public var timer: TopicTimer?
        public var topicName: String

        public init(run: LocalRun, timer: TopicTimer?, topicName: String) {
            self.run = run
            self.timer = timer
            self.topicName = topicName
        }
    }

    /// One store's view, read in one transaction (`read`).
    public struct Input: Sendable, Hashable {
        public var serverId: String
        public var serverOffsetMs: Int
        public var subjects: [Subject]

        public init(serverId: String, serverOffsetMs: Int = 0, subjects: [Subject]) {
            self.serverId = serverId
            self.serverOffsetMs = serverOffsetMs
            self.subjects = subjects
        }

        /// The open local runs with their pinned timers and topic names, and the server offset.
        public static func read(_ db: Database, serverId: String) throws -> Input {
            let offset = try Int.fetchOne(db, sql: "SELECT server_offset_ms FROM sync_state WHERE id = 1") ?? 0
            var timers: [String: TopicTimer?] = [:]
            let subjects = try RunOverlay.localRuns(db).filter(\.isOpen).map { run -> Subject in
                let topicId = run.topicId.wireString
                let key = "\(topicId)#\(run.version)"
                if timers[key] == nil {
                    let json = try String.fetchOne(
                        db, sql: "SELECT timer_json FROM topic_version WHERE topic_id = ? AND version = ?",
                        arguments: [topicId, run.version])
                    timers[key] = try json.map { try StoreJSON.decode(TopicTimer.self, $0) }
                }
                let name = try String.fetchOne(db, sql: "SELECT name FROM topic WHERE id = ?", arguments: [topicId])
                return Subject(run: run, timer: timers[key] ?? nil, topicName: name ?? run.topic?.name ?? "")
            }
            return Input(serverId: serverId, serverOffsetMs: offset, subjects: subjects)
        }
    }

    /// Device-clock `fireAt`s this close are the same request when the server-clock instant
    /// (`server_fire_at_ms`, compared exactly with the rest of the content) is unchanged: the
    /// server offset is re-estimated on every response (`StoreServerOffset`) by a few ms. Any
    /// change to the run or the alert time moves the server instant and replaces the request.
    public static let fireAtTolerance: TimeInterval = 1

    private let center: any NotificationCenterProtocol
    private let now: @Sendable () -> Date
    private var next: Input?
    private var running = false
    /// Callers coalesced into the running pass.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(center: any NotificationCenterProtocol, now: @escaping @Sendable () -> Date = { Date() }) {
        self.center = center
        self.now = now
    }

    /// The desired requests for `input`, now.
    public func desired(_ input: Input) -> [LocalNotificationRequest] {
        let now = now()
        return input.subjects.flatMap { subject -> [LocalNotificationRequest] in
            guard let timer = subject.timer else { return [] }
            return RunAlertPlan.requests(
                run: subject.run, timer: timer, now: now, serverOffsetMs: input.serverOffsetMs,
                topicName: subject.topicName, serverId: input.serverId)
        }
    }

    /// Brings the pending run alerts in line with `input`. Returns once the pass that covers it
    /// has finished (another caller's, when this one was coalesced into it).
    public func reconcile(_ input: Input) async {
        next = input
        guard !running else {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        while let input = next {
            next = nil
            await apply(desired(input))
        }
        running = false
        let done = waiters
        waiters = []
        for waiter in done { waiter.resume() }
    }

    /// Cancels every pending run alert (no bound store, or signed out of its server).
    public func cancelAll() async {
        await reconcile(Input(serverId: "", subjects: []))
    }

    private func apply(_ desired: [LocalNotificationRequest]) async {
        // Outside any transaction (notifications.md N6).
        let pending = await center.pendingNotificationRequests().filter { $0.id.hasPrefix(RunAlerts.identifierPrefix) }
        let wanted = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = pending.filter { wanted[$0.id] == nil }.map(\.id)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        let current = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // M1-REVIEW P2-2: one that came due while the pending list was awaited (planned ahead of
        // `now`, not pending now) was delivered meanwhile; added again, it would fire a second time
        // about 1 s later. The clock is read after the fetch. Not a window ahead of it: an alert
        // planned less than a second out is a real one still to schedule.
        let due = now()
        for request in desired where !(current[request.id].map { Self.matches($0, request) } ?? false) {
            if current[request.id] == nil, let fireAt = request.fireAt, fireAt <= due { continue }
            // Same identifier: the system replaces the pending request.
            try? await center.add(request)
        }
    }

    /// Whether the pending `snapshot` is `request`: the same content (the server-clock instant
    /// included), and the device-clock `fireAt` within the tolerance.
    static func matches(_ snapshot: NotificationSnapshot, _ request: LocalNotificationRequest) -> Bool {
        guard let fireAt = request.fireAt, let date = snapshot.date,
            abs(date.timeIntervalSince(fireAt)) < fireAtTolerance
        else { return false }
        var pendingInfo = snapshot.quickr
        var wantedInfo = request.quickr
        pendingInfo?.fireAtMs = nil
        wantedInfo?.fireAtMs = nil
        return snapshot.title == request.title && snapshot.body == request.body
            && snapshot.threadIdentifier == (request.threadIdentifier ?? "")
            && snapshot.categoryIdentifier == (request.categoryIdentifier ?? "")
            && snapshot.sound == request.sound && snapshot.interruptionLevel == request.interruptionLevel
            && pendingInfo == wantedInfo
    }
}

extension LocalStore {
    /// The run alerts' input, again on every change to what it reads: the local view of runs
    /// (this device's taps, sync applying a page), the pinned versions, the topic names and the
    /// server offset.
    public func observeRunAlerts(refresh: AsyncStream<Void>? = nil)
        -> AsyncThrowingStream<RunAlertScheduler.Input, any Error>
    {
        let serverId = serverId
        return StoreObservation.values(in: writer, refresh: refresh) { db in
            try RunAlertScheduler.Input.read(db, serverId: serverId)
        }
    }

    /// The run alerts' input, once.
    public func runAlertInput() async throws -> RunAlertScheduler.Input {
        let serverId = serverId
        return try await writer.read { db in try RunAlertScheduler.Input.read(db, serverId: serverId) }
    }
}
