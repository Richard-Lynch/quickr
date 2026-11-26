import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// timers2.md §9.1, R17: `RunAlertScheduler` against `FakeNotificationCenter`.
@Suite(.timeLimit(.minutes(1))) struct RunAlertSchedulerTests {
    typealias K = RunAlertKit

    let center = FakeNotificationCenter()
    let clock = FakeClock(K.date(K.at(12)))

    var scheduler: RunAlertScheduler { RunAlertScheduler(center: center, now: { [clock] in clock.now() }) }

    func input(_ runs: [LocalRun], timer: TopicTimer = K.timer, offsetMs: Int = 0) -> RunAlertScheduler.Input {
        RunAlertScheduler.Input(
            serverId: K.serverId, serverOffsetMs: offsetMs,
            subjects: runs.map { RunAlertScheduler.Subject(run: $0, timer: timer, topicName: "Intervals") })
    }

    func now(_ seconds: Double) { clock.set(K.date(K.at(seconds))) }

    var pending: [NotificationSnapshot] { center.withState { $0.pending }.sorted { $0.id < $1.id } }
    var added: [LocalNotificationRequest] { center.withState { $0.added } }
    var removed: [String] { center.withState { $0.removedPending } }

    func pendingMs() -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: pending.map { ($0.id, Int(($0.date!.timeIntervalSince1970 * 1000).rounded())) })
    }

    static let half = "quickr.alert.\(RunAlertKit.runId).1.half"
    static let go = "quickr.alert.\(RunAlertKit.runId).1.go"

    @Test("schedules the plan once; the fake centre sees time-sensitive interval requests")
    func schedules() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        #expect(pendingMs() == [Self.half: K.at(40), Self.go: K.at(70)])
        #expect(added.count == 2)
        #expect(added.allSatisfy { $0.interruptionLevel == RunAlerts.interruptionLevel })
        #expect(added.allSatisfy { $0.interruptionLevel == .timeSensitive })
        #expect(pending.allSatisfy { $0.interruptionLevel == .timeSensitive && $0.sound })
        #expect(added.allSatisfy { $0.fireAt != nil && $0.fireDate == nil })

        // Nothing changed: nothing is added or removed.
        now(13)
        await scheduler.reconcile(input([try K.resting()]))
        #expect(added.count == 2)
        #expect(removed.isEmpty)
    }

    @Test("pause cancels, resume re-plans shifted under the same identifiers")
    func pauseThenResume() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        now(15)
        await scheduler.reconcile(input([try K.resting([K.pause("p1", 15)])]))
        #expect(pending.isEmpty, "while paused the plan is empty")
        #expect(Set(removed) == [Self.half, Self.go])
        now(25)
        await scheduler.reconcile(input([try K.resting([K.pause("p1", 15), K.resume("r1", 25, pause: "p1")])]))
        #expect(pendingMs() == [Self.half: K.at(50), Self.go: K.at(80)])
    }

    @Test("a resume seen without the pause (both synced at once) replaces the pending request: same id, new fireAt")
    func fireAtMovedIsReplaced() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        now(26)
        await scheduler.reconcile(input([try K.resting([K.pause("p1", 15), K.resume("r1", 25, pause: "p1")])]))
        #expect(pendingMs() == [Self.half: K.at(50), Self.go: K.at(80)])
        #expect(added.count == 4, "both replaced")
        #expect(Array(added.suffix(2)).map(\.id) == [Self.half, Self.go])
        #expect(removed.isEmpty, "the identifiers stay; the system replaces by identifier")
    }

    @Test("a corrected alert time after a version publish is replaced")
    func correctedTimeIsReplaced() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        var corrected = K.timer
        corrected.laps[1].alerts[0].atMs = 20_000
        await scheduler.reconcile(input([try K.resting()], timer: corrected))
        #expect(pendingMs() == [Self.half: K.at(30), Self.go: K.at(70)])
        #expect(added.count == 3, "only the changed one")
        #expect(added.last?.id == Self.half)
    }

    @Test("a sub-second correction of an alert time is replaced too (the server-clock instant is exact)")
    func subSecondCorrectionIsReplaced() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        var corrected = K.timer
        corrected.laps[1].alerts[0].atMs = 30_500
        await scheduler.reconcile(input([try K.resting()], timer: corrected))
        #expect(pendingMs()[Self.half] == K.at(40.5))
        #expect(added.count == 3)
    }

    @Test("changed content (a renamed alert or topic) is replaced; the same request is not")
    func contentChangeIsReplaced() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        var renamed = K.timer
        renamed.laps[1].alerts[1].label = "Go go"
        await scheduler.reconcile(input([try K.resting()], timer: renamed))
        #expect(added.count == 3)
        #expect(pending.first { $0.id == Self.go }?.body == "Go go · Rest 1")

        var topic = input([try K.resting()], timer: renamed)
        topic.subjects[0].topicName = "Sprints"
        await scheduler.reconcile(topic)
        #expect(added.count == 5)
        #expect(pending.allSatisfy { $0.title == "Sprints" })
    }

    @Test("a pending request at another interruption level (an older build's) is replaced")
    func levelChangeIsReplaced() async throws {
        let scheduler = scheduler
        let plan = await scheduler.desired(input([try K.resting()]))
        for var request in plan {
            request.interruptionLevel = .active
            try await center.add(request)
        }
        await scheduler.reconcile(input([try K.resting()]))
        #expect(added.count == 4)
        #expect(pending.allSatisfy { $0.interruptionLevel == RunAlerts.interruptionLevel })
    }

    @Test("a pending request whose quickr info differs (an older build's, without run_id) is replaced")
    func infoChangeIsReplaced() async throws {
        let scheduler = scheduler
        let plan = await scheduler.desired(input([try K.resting()]))
        for var request in plan {
            request.quickr?.runId = nil
            try await center.add(request)
        }
        await scheduler.reconcile(input([try K.resting()]))
        #expect(added.count == 4)
        #expect(pending.allSatisfy { $0.quickr?.runId == K.runId })
    }

    @Test("a server offset re-estimated by a few ms doesn't churn; a second's change replaces")
    func offsetTolerance() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()], offsetMs: 0))
        await scheduler.reconcile(input([try K.resting()], offsetMs: 7))
        #expect(added.count == 2)
        await scheduler.reconcile(input([try K.resting()], offsetMs: 2_000))
        #expect(added.count == 4)
        #expect(pendingMs() == [Self.half: K.at(40) - 2_000, Self.go: K.at(70) - 2_000])
    }

    @Test("a lap tap cancels the old segment's requests and schedules the new one's")
    func lapMoves() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        now(20)
        let run2 = try K.resting([K.lap("l2", 20, seg: 1)])
        #expect(run2.state.open?.label == "Run 2")
        await scheduler.reconcile(input([run2]))
        #expect(pending.isEmpty)
        #expect(Set(removed) == [Self.half, Self.go])
        now(30)
        await scheduler.reconcile(input([try K.resting([K.lap("l2", 20, seg: 1), K.lap("l3", 30, seg: 2)])]))
        #expect(
            pendingMs() == [
                "quickr.alert.\(K.runId).3.half": K.at(60), "quickr.alert.\(K.runId).3.go": K.at(90),
            ])
    }

    @Test("stop cancels all of the run's alerts")
    func stopCancels() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        now(15)
        await scheduler.reconcile(input([try K.resting([K.stop(15)])]))
        #expect(pending.isEmpty)
        #expect(Set(removed) == [Self.half, Self.go])
    }

    @Test("discard cancels all of the run's alerts")
    func discardCancels() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(input([try K.resting()]))
        await scheduler.reconcile(input([try K.resting([K.discard(15)])]))
        #expect(pending.isEmpty)
    }

    @Test("a run that leaves the local view is cancelled; other runs and other requests are kept")
    func leavesView() async throws {
        let scheduler = scheduler
        let other = "0a000000-0000-4000-8000-0000000000bb"
        let reminder = LocalNotificationRequest(id: "due-x-2026", title: "Due", body: "", fireDate: Date())
        try await center.add(reminder)
        let otherRun = try K.run([K.lap("m1", 10, seg: 0)], id: other)
        await scheduler.reconcile(input([try K.resting(), otherRun]))
        #expect(pending.count == 5)
        await scheduler.reconcile(input([otherRun]))
        #expect(
            Set(pending.map(\.id)) == [
                "due-x-2026", "quickr.alert.\(other).1.half", "quickr.alert.\(other).1.go",
            ])
        await scheduler.cancelAll()
        #expect(pending.map(\.id) == ["due-x-2026"], "only run alerts are the scheduler's")
    }

    @Test("never more than 8 pending per run")
    func capPerRun() async throws {
        let alerts = (1...12).map { K.alert("a\($0)", "A\($0)", "\($0)s", $0 * 1_000) }
        let timer = TopicTimer(steps: [], laps: [TopicTimer.LapType(key: "only", label: "Lap", alerts: alerts)])
        let scheduler = scheduler
        now(0.5)
        let a = try K.run([], timer: timer)
        let b = try K.run([], id: "0a000000-0000-4000-8000-0000000000bb", timer: timer)
        await scheduler.reconcile(input([a, b], timer: timer))
        #expect(pending.filter { $0.id.hasPrefix(RunAlerts.identifierPrefix(runId: a.id)) }.count == 8)
        #expect(pending.filter { $0.id.hasPrefix(RunAlerts.identifierPrefix(runId: b.id)) }.count == 8)
        // As the earliest fire, the next ones come in, still 8.
        now(3.5)
        await scheduler.reconcile(input([a, b], timer: timer))
        let aIds = pending.filter { $0.id.hasPrefix(RunAlerts.identifierPrefix(runId: a.id)) }
            .map { $0.quickr!.alertLabel! }
        #expect(aIds.count == 8)
        #expect(Set(aIds) == Set((4...11).map { "A\($0)" }))
    }

    @Test("a run whose version isn't stored (no timer) has no alerts")
    func noTimer() async throws {
        let scheduler = scheduler
        await scheduler.reconcile(
            RunAlertScheduler.Input(
                serverId: K.serverId, subjects: [.init(run: try K.resting(), timer: nil, topicName: "Intervals")]))
        #expect(pending.isEmpty)
    }

    @Test("overlapping calls are serialised: callers during a pass coalesce into one more pass, from the latest input")
    func coalesces() async throws {
        let gated = HeldPendingCenter(center)
        let scheduler = RunAlertScheduler(center: gated, now: { [clock] in clock.now() })
        let resting = input([try K.resting()])
        let lapped = input([try K.resting([K.lap("l2", 20, seg: 1), K.lap("l3", 30, seg: 2)])])
        let stopped = input([try K.resting([K.stop(15)])])
        now(31)
        let first = Task { await scheduler.reconcile(resting) }
        await gated.waitForQuery(1)
        // While the first pass is held in its pending query, two more arrive: only the latest counts.
        let second = Task { await scheduler.reconcile(stopped) }
        let third = Task { await scheduler.reconcile(lapped) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gated.queries == 1, "no second pass while the first runs")
        await gated.open()
        _ = await (first.value, second.value, third.value)
        #expect(await gated.queries == 2, "the two callers shared one more pass")
        #expect(
            pendingMs() == [
                "quickr.alert.\(K.runId).3.half": K.at(60), "quickr.alert.\(K.runId).3.go": K.at(90),
            ])
    }

    // MARK: - The store's input

    @Test("the store's input: open runs with their pinned timer, topic name and server offset; a lap re-emits")
    func storeInput() async throws {
        let harness = try OutboxHarness()
        let topicId = harness.topic.id
        let version = TopicVersion(
            version: 1, questions: [], timer: K.timer, createdAt: Make.t0)
        try harness.write { db in
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topicId)
            try db.execute(sql: "UPDATE sync_state SET server_offset_ms = 250 WHERE id = 1")
        }
        let runId = try await harness.start()
        harness.wall.advance(by: 10)
        _ = try await harness.runs().lap(runId: runId)

        let input = try await harness.store.runAlertInput()
        #expect(input.serverId == harness.store.serverId)
        #expect(input.serverOffsetMs == 250)
        let subject = try #require(input.subjects.first)
        #expect(input.subjects.count == 1)
        #expect(subject.timer == K.timer)
        #expect(subject.topicName == harness.topic.name)
        #expect(subject.run.state.open?.label == "Rest 1")

        let center = FakeNotificationCenter()
        let wall = harness.wall
        let scheduler = RunAlertScheduler(center: center, now: { wall.now() })
        await scheduler.reconcile(input)
        let ids = center.withState { $0.pending.map(\.id) }.sorted()
        #expect(ids == ["quickr.alert.\(runId.lowercased()).1.go", "quickr.alert.\(runId.lowercased()).1.half"])
        // The lap started at the device's t0 + 10 s + offset (server clock); fireAt is back on the
        // device clock: 30 s after the lap by this device's clock.
        let half = try #require(center.withState { $0.pending.first { $0.id.hasSuffix(".half") } })
        let lapAt = try #require(subject.run.state.open?.startedAt)
        #expect(half.date == Date(timeIntervalSince1970: TimeInterval(lapAt - 250 + 30_000) / 1000))

        // A stop: the observation emits an input with no open run, which cancels them.
        var iterator = harness.store.observeRunAlerts().makeAsyncIterator()
        _ = try await iterator.next()
        harness.wall.advance(by: 1)
        _ = try await harness.runs().tap(.stop, runId: runId)
        var latest = try #require(try await iterator.next())
        while !latest.subjects.isEmpty { latest = try #require(try await iterator.next()) }
        await scheduler.reconcile(latest)
        #expect(center.withState { $0.pending }.isEmpty)
    }
}

/// The fake centre, holding `pendingNotificationRequests` until `open()`: a pass in flight.
private actor HeldPendingCenter: NotificationCenterProtocol {
    let inner: FakeNotificationCenter
    private(set) var queries = 0
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ inner: FakeNotificationCenter) { self.inner = inner }

    func open() {
        isOpen = true
        for waiter in held { waiter.resume() }
        held = []
    }

    func waitForQuery(_ count: Int) async {
        if queries >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func pendingNotificationRequests() async -> [NotificationSnapshot] {
        queries += 1
        for (count, watcher) in watchers where queries >= count { watcher.resume() }
        watchers.removeAll { queries >= $0.0 }
        if !isOpen { await withCheckedContinuation { held.append($0) } }
        return await inner.pendingNotificationRequests()
    }

    nonisolated func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        inner.setNotificationCategories(categories)
    }
    func notificationCategories() async -> [NotificationCategorySpec] { await inner.notificationCategories() }
    func deliveredNotifications() async -> [NotificationSnapshot] { await inner.deliveredNotifications() }
    nonisolated func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        inner.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    nonisolated func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        inner.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func add(_ request: LocalNotificationRequest) async throws { try await inner.add(request) }
    func setBadgeCount(_ count: Int) async throws { try await inner.setBadgeCount(count) }
    func authorizationStatus() async -> NotificationAuthorization { await inner.authorizationStatus() }
    func requestAuthorization() async throws -> Bool { try await inner.requestAuthorization() }
}
