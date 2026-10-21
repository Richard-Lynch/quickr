#if DEBUG
import Foundation
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// Checkpoint D's category probe (DeviceProbe; DEVICE-DAY D8, D9): its categories, files and both
/// sides of a run, against fake notification centers. The real thing runs on the device.
@Suite(.timeLimit(.minutes(5))) struct DeviceProbeTests {
    /// A temporary App Group root: the probe's files and a real registry with one real category.
    struct World {
        let location: StoreLocation
        let files: DeviceProbe.Files
        let realCategory = NotificationCategoriesTests.row()

        init() async throws {
            location = StoreLocation(
                root: FileManager.default.temporaryDirectory.appending(path: "dprobe-\(UUID().uuidString)"))
            files = DeviceProbe.Files(location: location)
            let real = try Registry.open(at: location, notifier: nil)
            try await NotificationCategories(registry: real, center: FakeNotificationCenter()).register([realCategory])
        }

        func runner(_ process: DeviceProbe.Process, _ center: any NotificationCenterProtocol) -> DeviceProbeRunner {
            var runner = DeviceProbeRunner(files: files, process: process, center: center) { [location] in
                await DeviceProbe.restore(location: location, center: center)
            }
            // Generous limits on the success paths: they bound a failing test, and a loaded machine
            // never trips them. Tests of a limit set their own, short one.
            runner.readbackLimit = .seconds(10)
            runner.peerLimit = .seconds(30)
            runner.startLimit = .seconds(60)
            return runner
        }

        func records(_ event: String) -> [DeviceProbe.Record] { files.records().filter { $0.event == event } }

        func realIsBack(_ center: FakeNotificationCenter) -> Bool {
            center.withState { $0.categories.map(\.id) } == [realCategory.category.id]
        }
    }

    /// Whether `condition` came true within `seconds` (a bound on a failing test, never a pass
    /// condition on timing).
    static func eventually(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    static func from(now offset: Double) -> UInt64 {
        UInt64(Int64(DeviceProbe.uptime()) + Int64(offset * 1e9))
    }

    // MARK: - Categories

    @Test func d8RoundsShareAAndSplitBAndC() {
        let nse = DeviceProbe.d8Rows(round: 7, process: .nse).map(\.category.id)
        let app = DeviceProbe.d8Rows(round: 7, process: .app).map(\.category.id)
        #expect(nse[0] == app[0])
        #expect(nse[1] != app[1])
        #expect(DeviceProbe.d8Expected(round: 7) == Set(nse + app))
        #expect(DeviceProbe.d8Expected(round: 7).count == 3)
        #expect(DeviceProbe.d8Expected(round: 7).isDisjoint(with: DeviceProbe.d8Expected(round: 8)))
    }

    @Test func d9RowsAreDistinctPerSizeAndProcessWithFourActions() {
        let app = DeviceProbe.rows(size: 100, process: .app)
        let nse = DeviceProbe.rows(size: 100, process: .nse)
        #expect(Set(app.map(\.category.id)).count == 100)
        #expect(Set(app.map(\.category.id)).isDisjoint(with: nse.map(\.category.id)))
        #expect(app.allSatisfy { $0.category.id.hasPrefix("quickr.t.") && $0.category.actions.count == 4 })
        #expect(app.allSatisfy { $0.serverId == DeviceProbe.serverId })
    }

    @Test func missingListsTheExpectedIdsNotRegistered() {
        let registered = [
            NotificationCategorySpec(id: "a", actions: []), NotificationCategorySpec(id: "x", actions: []),
        ]
        #expect(DeviceProbe.missing(["a", "c", "b"], in: registered) == ["b", "c"])
        #expect(DeviceProbe.missing(["a"], in: registered).isEmpty)
    }

    @Test func overlapIsAnyCommonInstant() {
        #expect(DeviceProbe.overlapped(1...5, 5...9))
        #expect(DeviceProbe.overlapped(3...4, 1...9))
        #expect(!DeviceProbe.overlapped(1...4, 5...9))
    }

    // MARK: - Files

    @Test func aRequestIsTakenOnce() async throws {
        let w = try await World()
        #expect(w.files.take() == nil)
        let request = DeviceProbe.Request(kind: .d9, run: "r1", sizes: [10])
        try w.files.write(request)
        #expect(w.files.take() == request)
        #expect(w.files.take() == nil, "a second push doesn't run it again")
    }

    @Test func anExpiredRequestIsNotTaken() async throws {
        let w = try await World()
        try w.files.write(DeviceProbe.Request(kind: .d8, run: "old"))
        #expect(w.files.take(now: Date().addingTimeInterval(DeviceProbe.requestLifetime + 1)) == nil)
        #expect(w.files.take() == nil, "and it's gone: a later test push doesn't start it")
    }

    @Test func aRequestOfASupersededRunIsNotTaken() async throws {
        let w = try await World()
        try w.files.write(DeviceProbe.Request(kind: .d8, run: "old"))
        try w.files.claim("new")
        #expect(w.files.take() == nil)
    }

    @Test func recordsAppendedFromManyWritersAllReadBack() async throws {
        let w = try await World()
        let written = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let ok = w.files.append(
                        DeviceProbe.Record(
                            run: "r", process: i % 2 == 0 ? .app : .nse, probe: .d8, event: "round", round: i,
                            missing: ["quickr.t.x.y"], note: String(repeating: "n", count: 300)))
                    if ok { written.withLock { $0 += 1 } }
                }
            }
        }
        #expect(written.withLock { $0 } == 200)
        let records = w.files.records()
        #expect(records.count == 200)
        #expect(Set(records.compactMap(\.round)) == Set(0..<200))
    }

    @Test func anAppendThatCantWriteSaysSo() async throws {
        let w = try await World()
        try FileManager.default.createDirectory(at: w.files.results, withIntermediateDirectories: true)  // a directory
        #expect(!w.files.append(DeviceProbe.Record(run: "r", process: .app, probe: .d9, event: "size")))
    }

    @Test func recordsUseSnakeCaseTimings() throws {
        let record = DeviceProbe.Record(
            run: "r", process: .nse, probe: .d9, event: "size", size: 100, setMs: 0.5, registerMs: 1.5)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(json.contains("\"register_ms\":1.5") && json.contains("\"set_ms\":0.5"))
        #expect(try JSONDecoder().decode(DeviceProbe.Record.self, from: Data(json.utf8)) == record)
    }

    // MARK: - D9

    @Test func d9TimesEachSizeThenRestoresTheRealCategories() async throws {
        let w = try await World()
        let center = FakeNotificationCenter()
        await w.runner(.app, center).run(DeviceProbe.Request(kind: .d9, run: "r9", sizes: [10, 100]))

        let sizes = w.records("size")
        #expect(sizes.map(\.size) == [10, 100])
        #expect(
            sizes.allSatisfy {
                $0.ok == true && $0.setMs != nil && $0.registerMs != nil && $0.readbackMs != nil && $0.process == .app
                    && $0.overrun == nil
            })
        #expect(sizes.allSatisfy { $0.setMs! <= $0.registerMs! }, "the call alone is part of the whole register")
        #expect(sizes.map(\.seen) == [10, 100])
        #expect(w.records("done").first?.ok == true)
        #expect(w.realIsBack(center), "the real set is back")
        // The probe never touched the real registry's table.
        let real = try Registry.open(at: w.location, notifier: nil)
        let table = try await real.writer.read { try String.fetchAll($0, sql: "SELECT id FROM notification_category") }
        #expect(table == [w.realCategory.category.id])
    }

    @Test func d9RecordsAReadbackThatNeverShows() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d9, run: "r", sizes: [10])
        try w.files.write(request)
        var runner = w.runner(.nse, LossyCenter(dropsEvery: 1))
        runner.readbackLimit = .milliseconds(200)  // it never shows: the limit ends the wait
        await runner.run(request)
        let size = try #require(w.records("size").first)
        #expect(size.ok == false)
        #expect(size.readbackMs == nil)
        #expect(size.seen == 0, "how many showed, for D1: none")
    }

    @Test func d9AReadbackAfterTheDeadlineIsNotASuccess() async throws {
        let w = try await World()
        // Time is the test's: it moves only when the readback asks the center, by 1 s, past the
        // deadline half a second away, however loaded the machine is.
        let clock = TestClock()
        let center = ReadHookCenter { clock.advance(by: 1_000_000_000) }
        let request = DeviceProbe.Request(kind: .d9, run: "r", sizes: [10, 20])
        try w.files.write(request)
        var runner = w.runner(.nse, center)
        runner.now = clock.now
        runner.readbackLimit = .seconds(10)  // well past the 1 s step: only the deadline is crossed
        await runner.run(request, until: clock.now() + 500_000_000)
        let size = try #require(w.records("size").first)
        #expect(size.size == 10)
        #expect(size.readbackMs != nil && size.ok == false, "seen within its limit, but after the deadline")
        #expect(size.overrun == true)
        #expect(w.records("timeout").first?.size == 20)
        #expect(w.records("done").first?.ok == true, "restored after the deadline")
    }

    @Test func d9StartsByNamingItsSizes() async throws {
        let w = try await World()
        await w.runner(.app, FakeNotificationCenter()).run(DeviceProbe.Request(kind: .d9, run: "r", sizes: [10, 20]))
        #expect(w.records("start").first?.sizes == [10, 20])
        #expect(DeviceProbe.Request(kind: .d9).sizes == [100, 150, 1000, 5000], "150 brackets a 100-category cap")
    }

    @Test func aReadbackAfterItsLimitIsNotSeenInTime() async throws {
        let w = try await World()
        var runner = w.runner(.app, SlowCenter(readDelay: .milliseconds(300)))
        runner.readbackLimit = .milliseconds(100)
        await runner.run(DeviceProbe.Request(kind: .d9, run: "r", sizes: [10]))
        let size = try #require(w.records("size").first)
        #expect(size.ok == false)
        #expect(size.readbackMs == nil)
    }

    @Test func aSupersededD9StopsAndLeavesTheRestoreToTheNewerRun() async throws {
        let w = try await World()
        let center = FakeNotificationCenter()
        let request = DeviceProbe.Request(kind: .d9, run: "old", sizes: [10])
        try w.files.write(request)
        try w.files.claim("new")
        await w.runner(.nse, center).run(request, until: Self.from(now: 60))
        #expect(w.records("size").isEmpty)
        #expect(w.records("stopped").first?.run == "old")
        #expect(w.records("done").first?.note?.contains("superseded") == true)
        #expect(center.withState { $0.categoryRegistrations }.isEmpty, "it doesn't touch the newer run's set")
    }

    @Test func anOrdinaryLaunchCancelsAPendingProbe() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d8, run: "r")
        try w.files.write(request)
        w.files.cancelPending()
        #expect(w.files.take() == nil, "a later test push doesn't start it")
        #expect(!w.files.isCurrent("r"), "and a runner still going stops")
    }

    @Test func aStepWaitingForTheLockGivesUpAtTheDeadline() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d9, run: "r", sizes: [10])
        try w.files.write(request)
        // Another holder keeps the lock until the test lets it go, after the runner has given up.
        let held = Mutex(false)
        let release = Mutex(false)
        let holder = Task {
            try await w.files.exclusively {
                held.withLock { $0 = true }
                while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
            }
        }
        // On every exit (a failed expectation, a cancellation) the holder lets go and ends.
        defer {
            release.withLock { $0 = true }
            holder.cancel()
        }
        let holding = try await Self.eventually(seconds: 20) { held.withLock { $0 } }
        try #require(holding, "the holder took the lock")
        // The runner's clock moves 1 ms each time it is read, so the deadline 50 ms away passes
        // after a fixed number of reads: the few before the lock, then the lock's polls.
        let clock = TestClock(step: 1_000_000)
        var runner = w.runner(.nse, FakeNotificationCenter())
        runner.now = clock.now
        let deadline = clock.now() + 50_000_000
        let run = Task { await runner.run(request, until: deadline) }
        // It gives up while the lock is still held: the timeout comes before the release.
        let gaveUp = try await Self.eventually(seconds: 20) { !w.records("timeout").isEmpty }
        release.withLock { $0 = true }
        await run.value
        try await holder.value
        #expect(gaveUp, "it gave up at the deadline, while the lock was still held")
        #expect(w.records("size").isEmpty)
        #expect(w.records("timeout").first?.note?.contains("lock") == true)
        #expect(w.records("done").first?.ok == true, "it still restores")
    }

    @Test func d9StopsAtTheDeadline() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d9, run: "r", sizes: [10, 20])
        try w.files.write(request)
        await w.runner(.nse, FakeNotificationCenter()).run(request, until: DeviceProbe.uptime())
        #expect(w.records("size").isEmpty)
        #expect(w.records("timeout").first?.size == 10)
        #expect(w.records("done").count == 1)
    }

    @Test func cancellingARunStillRestoresTheRealCategories() async throws {
        let w = try await World()
        let center = FakeNotificationCenter()
        let request = DeviceProbe.Request(kind: .d8, run: "r")
        try w.files.write(request)
        let task = Task { await w.runner(.nse, center).run(request) }
        // The NSE side waits for an app that never comes; the system's time runs out.
        let ready = try await Self.eventually(seconds: 20) { !w.records("ready").isEmpty }
        try #require(ready, "the NSE side started")
        task.cancel()
        await task.value
        #expect(w.records("done").first?.ok == true)
        #expect(w.realIsBack(center))
    }

    // MARK: - D8

    @Test func d8BothSidesMeetEveryRoundWithThatRoundsSetAlone() async throws {
        let w = try await World()
        let center = FakeNotificationCenter()
        let request = DeviceProbe.Request(kind: .d8, run: "r8", rounds: 20)
        try w.files.write(request)
        let taken = try #require(w.files.take())
        async let nse: Void = w.runner(.nse, center).run(taken, until: Self.from(now: 60))
        async let app: Void = w.runner(.app, center).run(request)
        _ = await (nse, app)

        let rounds = w.records("round")
        #expect(rounds.map(\.round) == Array(1...20).map { $0 })
        #expect(rounds.allSatisfy { $0.ok == true && $0.missing == [] && $0.reconciled == false })
        #expect(w.records("start").first?.rounds == 20)
        #expect(w.records("ready").first?.process == .nse)
        #expect(w.records("done").count == 2)
        #expect(w.records("done").allSatisfy { $0.ok == true })
        #expect(w.realIsBack(center))
        // Every set the system got held at most one round's three probe categories.
        let real = w.realCategory.category.id
        let probeSets = center.withState { $0.categoryRegistrations }.map { $0.filter { $0.id != real }.count }
        #expect(probeSets.allSatisfy { $0 <= 3 })
    }

    @Test func d8RecordsWhetherTheAttemptsOverlapped() async throws {
        let w = try await World()
        // Each registration holds the registry's lock 30 ms, so when both sides wake at the
        // rendezvous the other's attempt starts meanwhile. A loaded machine can wake one late,
        // so not every round is required to overlap; every round says whether it did.
        let center = SlowCenter(setDelay: .milliseconds(30))
        let request = DeviceProbe.Request(kind: .d8, run: "r", rounds: 6)
        try w.files.write(request)
        async let nse: Void = w.runner(.nse, center).run(request, until: Self.from(now: 60))
        async let app: Void = w.runner(.app, center).run(request)
        _ = await (nse, app)
        let rounds = w.records("round")
        #expect(rounds.count == 6)
        // Every round says whether the attempts overlapped; whether they did depends on scheduling
        // (a loaded machine can wake one side late), so no count is required here. The interval
        // logic itself is overlapIsAnyCommonInstant's.
        #expect(rounds.allSatisfy { $0.overlap != nil })
    }

    @Test func d8ReportsALostRegistrationAndWhetherOneReconcileFixesIt() async throws {
        let w = try await World()
        let center = LossyCenter(dropsEvery: 3)
        let request = DeviceProbe.Request(kind: .d8, run: "r", rounds: 12)
        try w.files.write(request)
        async let nse: Void = w.runner(.nse, center).run(request, until: Self.from(now: 60))
        async let app: Void = w.runner(.app, center).run(request)
        _ = await (nse, app)

        let rounds = w.records("round")
        #expect(rounds.count == 12)
        #expect(rounds.contains { !($0.missing ?? []).isEmpty && $0.reconciled == true })
        #expect(rounds.contains { !($0.missing ?? []).isEmpty && $0.ok == true }, "the reconcile repaired a round")
        #expect(rounds.allSatisfy { ($0.missing ?? []).isEmpty == ($0.reconciled == false) })
    }

    @Test func d8WithoutTheNSETimesOut() async throws {
        let w = try await World()
        var runner = w.runner(.app, FakeNotificationCenter())
        runner.startLimit = .milliseconds(300)
        let request = DeviceProbe.Request(kind: .d8, run: "r", rounds: 5)
        try w.files.write(request)
        await runner.run(request)
        #expect(w.records("round").isEmpty)
        #expect(w.records("timeout").first?.note?.contains("test push") == true)
    }

    @Test func anOlderRunsNSEDoesNotAnswerANewRun() async throws {
        let w = try await World()
        // The old run's NSE was ready and acknowledged round 1; the new run's app must not take
        // either as its own.
        try FileManager.default.createDirectory(at: w.files.root, withIntermediateDirectories: true)
        w.files.write([1, 1, 2], to: w.files.nseRound("old"))
        w.files.append(DeviceProbe.Record(run: "old", process: .nse, probe: .d8, event: "ready"))
        var runner = w.runner(.app, FakeNotificationCenter())
        runner.startLimit = .milliseconds(300)
        let request = DeviceProbe.Request(kind: .d8, run: "new", rounds: 3)
        try w.files.write(request)
        await runner.run(request)
        #expect(w.records("round").isEmpty)
        #expect(w.records("timeout").contains { $0.run == "new" })
    }

    @Test func aRunnerOfASupersededRunStops() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d8, run: "old", rounds: 5)
        try w.files.write(request)
        try w.files.claim("new")
        await w.runner(.nse, FakeNotificationCenter()).run(request, until: Self.from(now: 60))
        #expect(w.records("stopped").first?.run == "old")
    }

    @Test func aD8RegistrationOvertakenByACancellationIsUndone() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d8, run: "r", rounds: 1)
        try w.files.write(request)
        w.files.write([1, Int64(DeviceProbe.uptime())], to: w.files.appRound("r"))
        // An ordinary launch cancels the probe while the NSE's registration is under way.
        let center = HookCenter { w.files.cancelPending() }
        await w.runner(.nse, center).run(request, until: Self.from(now: 60))
        #expect(w.records("stopped").first?.run == "r")
        #expect(center.ids == [w.realCategory.category.id], "the real set is back, not the probe's")
    }

    @Test func d8NSEStopsAtItsDeadline() async throws {
        let w = try await World()
        let request = DeviceProbe.Request(kind: .d8, run: "r", rounds: 5)
        try w.files.write(request)
        await w.runner(.nse, FakeNotificationCenter()).run(request, until: Self.from(now: 0.2))
        #expect(w.records("ready").count == 1)
        #expect(w.records("timeout").first?.round == 0)
    }
}

/// A center whose every `dropsEvery`-th registration is lost, as a racing system could lose one.
private final class LossyCenter: NotificationCenterProtocol {
    private let inner = FakeNotificationCenter()
    private let dropsEvery: Int
    private let calls = Mutex(0)

    init(dropsEvery: Int) { self.dropsEvery = dropsEvery }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        let n = calls.withLock {
            $0 += 1
            return $0
        }
        guard n % dropsEvery != 0 else { return }
        inner.setNotificationCategories(categories)
    }

    func notificationCategories() async -> [NotificationCategorySpec] { await inner.notificationCategories() }
    func deliveredNotifications() async -> [NotificationSnapshot] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func pendingNotificationRequests() async -> [NotificationSnapshot] { [] }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func add(_ request: LocalNotificationRequest) async throws {}
    func setBadgeCount(_ count: Int) async throws {}
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
}

/// A center that takes its time: `setDelay` inside each registration, `readDelay` before a read.
private final class SlowCenter: NotificationCenterProtocol {
    private let inner = FakeNotificationCenter()
    private let setDelay: Duration
    private let readDelay: Duration

    init(setDelay: Duration = .zero, readDelay: Duration = .zero) {
        self.setDelay = setDelay
        self.readDelay = readDelay
    }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        usleep(UInt32(DeviceProbe.nanoseconds(setDelay) / 1000))
        inner.setNotificationCategories(categories)
    }

    func notificationCategories() async -> [NotificationCategorySpec] {
        try? await Task.sleep(for: readDelay)
        return await inner.notificationCategories()
    }

    func deliveredNotifications() async -> [NotificationSnapshot] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func pendingNotificationRequests() async -> [NotificationSnapshot] { [] }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func add(_ request: LocalNotificationRequest) async throws {}
    func setBadgeCount(_ count: Int) async throws {}
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
}
/// A center that runs `hook` once, during its first registration (after setting it).
private final class HookCenter: NotificationCenterProtocol {
    private let inner = FakeNotificationCenter()
    private let hook: Mutex<(@Sendable () -> Void)?>

    init(_ hook: @escaping @Sendable () -> Void) { self.hook = Mutex(hook) }

    var ids: [String] { inner.withState { $0.categories.map(\.id) } }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        inner.setNotificationCategories(categories)
        hook.withLock { hook in
            defer { hook = nil }
            return hook
        }?()
    }

    func notificationCategories() async -> [NotificationCategorySpec] { await inner.notificationCategories() }
    func deliveredNotifications() async -> [NotificationSnapshot] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func pendingNotificationRequests() async -> [NotificationSnapshot] { [] }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func add(_ request: LocalNotificationRequest) async throws {}
    func setBadgeCount(_ count: Int) async throws {}
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
}
/// A clock the test drives (uptime ns): `advance(by:)` moves it; with a `step`, every read also
/// moves it that far, so time passes with the runner's progress rather than with the machine.
private final class TestClock: Sendable {
    private let value = Mutex<UInt64>(1_000_000_000_000)
    private let step: UInt64

    init(step: UInt64 = 0) { self.step = step }

    var now: @Sendable () -> UInt64 {
        { [self] in
            value.withLock {
                defer { $0 += step }
                return $0
            }
        }
    }

    func advance(by nanoseconds: UInt64) { value.withLock { $0 += nanoseconds } }
}

/// A center that runs `onRead` before each `notificationCategories()`.
private final class ReadHookCenter: NotificationCenterProtocol {
    private let inner = FakeNotificationCenter()
    private let onRead: @Sendable () -> Void

    init(_ onRead: @escaping @Sendable () -> Void) { self.onRead = onRead }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        inner.setNotificationCategories(categories)
    }

    func notificationCategories() async -> [NotificationCategorySpec] {
        onRead()
        return await inner.notificationCategories()
    }

    func deliveredNotifications() async -> [NotificationSnapshot] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func pendingNotificationRequests() async -> [NotificationSnapshot] { [] }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func add(_ request: LocalNotificationRequest) async throws {}
    func setBadgeCount(_ count: Int) async throws {}
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
}
#endif
