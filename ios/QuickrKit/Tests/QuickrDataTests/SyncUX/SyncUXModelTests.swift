import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// SYNC-UX's pure models: the pill (`SyncPillState`), the sheet's rows (`SyncSheetModel`) and the
/// foreground timer's schedule (`FlushTimerPolicy`, `ForegroundFlushTimer`).
@Suite struct SyncPillStateTests {
    private func summary(
        queued: Int = 0, held: Int = 0, uncertain: Int = 0, failed: Int = 0
    ) -> OutboxSummary {
        var s = OutboxSummary()
        s.queued = queued
        s.held = held
        s.uncertain = uncertain
        s.failed = failed
        return s
    }

    @Test func hiddenWhenAllIsWell() {
        #expect(SyncPillState.make(summary: summary(), status: SyncStatus(), online: true) == .hidden)
        #expect(SyncPillState.make(summary: nil, status: SyncStatus(), online: true) == .hidden)
        #expect(!SyncPillState.hidden.isVisible)
    }

    @Test func precedenceAndLabels() {
        var mismatch = SyncStatus()
        mismatch.identityMismatch = true
        #expect(SyncPillState.make(summary: summary(failed: 2), status: mismatch, online: false) == .differentServer)

        let failed = SyncPillState.make(summary: summary(queued: 3, failed: 2), status: SyncStatus(), online: false)
        #expect(failed == .failed(count: 2))
        #expect(failed.label == "2 failed to sync" && failed.shortLabel == "2 failed")

        let offline = SyncPillState.make(summary: summary(queued: 3, held: 1), status: SyncStatus(), online: false)
        #expect(offline == .offline(waiting: 2))
        #expect(offline.label == "Offline · 2 waiting to sync" && offline.shortLabel == "Offline")
        #expect(SyncPillState.make(summary: summary(), status: SyncStatus(), online: false).label == "Offline")

        let waiting = SyncPillState.make(summary: summary(queued: 2, uncertain: 1), status: SyncStatus(), online: true)
        #expect(waiting == .waiting(count: 2, checking: true))
        #expect(waiting.label == "2 waiting to sync" && waiting.shortLabel == "2")
        #expect(waiting.accessibilityLabel == "2 waiting to sync, checking")
    }

    @Test func aHeldDeleteAloneShowsNothing() {
        // In its undo window: not waiting to sync yet.
        #expect(SyncPillState.make(summary: summary(queued: 1, held: 1), status: SyncStatus(), online: true) == .hidden)
    }

    @Test func loadingHistoryAndRepeatedPullFailures() {
        var pulling = SyncStatus()
        pulling.activity = .pulling(bootstrapping: true, cursor: 25, head: 100)
        let loading = SyncPillState.make(summary: summary(), status: pulling, online: true)
        #expect(loading == .loadingHistory(progress: 0.25))
        #expect(loading.accessibilityLabel == "Loading history, 25 percent")
        pulling.activity = .pulling(bootstrapping: true, cursor: 0, head: 0)
        #expect(SyncPillState.make(summary: summary(), status: pulling, online: true) == .loadingHistory(progress: nil))
        pulling.activity = .pulling(bootstrapping: false, cursor: 5, head: 9)
        #expect(SyncPillState.make(summary: summary(), status: pulling, online: true) == .hidden)

        // The server can't be reached although the device has a path: offline, at once.
        var unreachable = SyncStatus()
        unreachable.lastFailure = .unreachable("timeout")
        unreachable.consecutiveFailures = 1
        #expect(
            SyncPillState.make(summary: summary(queued: 2), status: unreachable, online: true) == .offline(waiting: 2))

        var failing = SyncStatus()
        failing.lastFailure = .protocolError("next below cursor")
        failing.consecutiveFailures = SyncPillState.failuresBeforeError - 1
        #expect(SyncPillState.make(summary: summary(), status: failing, online: true) == .hidden)
        failing.consecutiveFailures = SyncPillState.failuresBeforeError
        #expect(SyncPillState.make(summary: summary(), status: failing, online: true) == .syncError)
        // Offline explains it better.
        #expect(SyncPillState.make(summary: summary(), status: failing, online: false) == .offline(waiting: 0))
    }
}

@Suite struct SyncSheetModelTests {
    static let topicId = "6f1c0000-0000-4000-8000-000000000001"
    static let entryId = "9a000000-0000-4000-8000-000000000001"
    static let now = LeaseInstant(bootId: "boot", ct: 1_000_000_000_000)
    static let t0 = Date(timeIntervalSince1970: 1_772_625_600)

    static func item(
        _ payload: OutboxPayload, id: String = UUID().uuidString.lowercased(), state: OutboxState = .pending,
        attempts: Int = 0, maybeDelivered: Bool = false, due: LeaseInstant? = nil,
        reason: OutboxFailureReason? = nil, error: String? = nil, seq: Int64
    ) throws -> OutboxItem {
        let errorJSON = error.map { #"{"message":"\#($0)","status":422}"# }
        return OutboxItem(
            seq: seq, id: id, kind: payload.kind, entityId: Self.entity(payload, id: id), topicId: topicId,
            payloadJSON: try payload.encoded(), state: state, maybeDelivered: maybeDelivered, attempts: attempts,
            due: due, failureReason: reason, lastErrorJSON: errorJSON, origin: .app, createdAt: t0, updatedAt: t0)
    }

    static func entity(_ payload: OutboxPayload, id: String) -> String {
        switch payload {
        case .entryCreate: id
        case .entryUpdate(let entryId, _, _), .entryDelete(let entryId, _): entryId
        case .topicArchive(let topicId), .topicUnarchive(let topicId): topicId
        }
    }

    static var create: OutboxPayload {
        .entryCreate(
            topic: TopicRef(id: UUID(uuidString: topicId)!, slug: "mood", name: "Mood"),
            body: EntryCreateDTO(
                id: nil, answers: ["mood": .int(3)], source: "ios", capturedAt: t0.addingTimeInterval(-60), version: 1))
    }

    static let topics = [topicId: SyncTopicInfo(name: "Mood")]

    private func model(_ items: [OutboxItem], online: Bool = true) -> SyncSheetModel {
        SyncSheetModel(items: items, topics: Self.topics, online: online, lastSyncAt: Self.t0, now: Self.now)
    }

    @Test func emptyIsSynced() {
        let m = model([])
        #expect(m.headline == "Everything is synced." && !m.canSyncNow && m.rows.isEmpty)
    }

    @Test func titlesStatusesAndActionsPerState() throws {
        let failedCreate = try Self.item(
            Self.create, state: .failed, attempts: 1, reason: .rejected, error: "Mood is required", seq: 1)
        let waiting = try Self.item(Self.create, seq: 2)
        let retrying = try Self.item(
            .entryUpdate(entryId: Self.entryId, topicId: Self.topicId, patch: EntryUpdateDTO(notes: "n")), attempts: 2,
            due: Self.now.adding(.seconds(300)), error: "Server error (503)", seq: 3)
        let checking = try Self.item(
            .entryDelete(entryId: "9a000000-0000-4000-8000-000000000002", topicId: Self.topicId), state: .uncertain,
            attempts: 1, maybeDelivered: true, due: Self.now.adding(.seconds(5)), seq: 4)
        let held = try Self.item(
            .entryDelete(entryId: "9a000000-0000-4000-8000-000000000003", topicId: Self.topicId), state: .held, seq: 5)
        let gone = try Self.item(
            .entryUpdate(
                entryId: "9a000000-0000-4000-8000-000000000004", topicId: Self.topicId, patch: EntryUpdateDTO()),
            state: .failed, attempts: 1, reason: .deletedElsewhere, seq: 6)
        let m = model([failedCreate, waiting, retrying, checking, held, gone])
        let rows = Dictionary(uniqueKeysWithValues: m.rows.map { ($0.id, $0) })

        let f = try #require(rows[failedCreate.id])
        #expect(f.title == "Entry · Mood" && f.status == "Failed — Mood is required" && f.tone == .failed)
        #expect(f.when == Self.t0.addingTimeInterval(-60))  // the capture time
        #expect(f.canRetry && f.retryTitle == "Retry as is" && f.canDiscard && !f.canDismiss)
        #expect(f.fix == .record(TopicLinkRef(id: UUID(uuidString: Self.topicId)!), fix: failedCreate.id))

        let w = try #require(rows[waiting.id])
        #expect(w.status == "Waiting to sync" && w.retryTitle == "Retry now" && w.fix == nil)

        let r = try #require(rows[retrying.id])
        #expect(r.title == "Edit · Mood" && r.status == "Server error (503) · retrying in 5 min" && r.when == Self.t0)

        let c = try #require(rows[checking.id])
        #expect(c.title == "Delete · Mood" && c.tone == .checking)
        #expect(c.status == "Sending… (checking) · retrying shortly")

        let h = try #require(rows[held.id])
        #expect(h.tone == .held && h.status == "Deleting — you can still undo" && !h.canRetry && h.canDiscard)

        let g = try #require(rows[gone.id])
        #expect(g.status == "Deleted on another device" && g.canDismiss && !g.canDiscard && !g.canRetry)

        #expect(m.headline == "3 items waiting · 2 failed" && m.canSyncNow)  // the held delete isn't counted
    }

    @Test func aHeldDeleteAloneIsNotWaiting() throws {
        let held = try Self.item(
            .entryDelete(entryId: Self.entryId, topicId: Self.topicId), state: .held, seq: 1)
        let m = model([held])
        #expect(m.headline == "Everything is synced." && !m.canSyncNow && m.rows.count == 1)
    }

    @Test func offlineRetriesWhenBackOnline() throws {
        let retrying = try Self.item(Self.create, attempts: 1, due: Self.now.adding(.seconds(300)), error: "x", seq: 1)
        #expect(model([retrying], online: false).rows.first?.status == "x · retrying when back online")
    }

    @Test func anItemBehindAFailedOneSaysWhatItWaitsFor() throws {
        let failed = try Self.item(
            .topicArchive(topicId: Self.topicId), state: .failed, attempts: 1, reason: .rejected, error: "no", seq: 1)
        let blocked = try Self.item(Self.create, seq: 2)
        let row = try #require(model([failed, blocked]).rows.last)
        #expect(row.tone == .blocked && row.status == "Waiting for Archive · Mood")
        // An archive is never fixed in RECORD.
        #expect(model([failed]).rows.first?.fix == nil)
    }

    @Test func fixOnlyForCreatesTheServerNeverSaw() throws {
        let delivered = try Self.item(
            Self.create, state: .failed, attempts: 1, maybeDelivered: true, reason: .rejected, error: "x", seq: 1)
        #expect(model([delivered]).rows.first?.fix == nil)
        let conflict = try Self.item(Self.create, state: .failed, attempts: 1, reason: .conflict, error: "x", seq: 1)
        #expect(model([conflict]).rows.first?.fix == nil)
        let future = try Self.item(Self.create, state: .failed, reason: .futureTime, error: "x", seq: 1)
        #expect(model([future]).rows.first?.fix != nil)
    }

    @Test func anInFlightItemCanOnlyBeWatched() throws {
        let sending = try Self.item(Self.create, state: .inFlight, attempts: 1, seq: 1)
        let row = try #require(model([sending]).rows.first)
        #expect(row.status == "Sending…" && !row.canRetry && !row.canDiscard)
    }
}

@Suite struct FlushTimerTests {
    static let now = LeaseInstant(bootId: "boot", ct: 5_000_000_000)

    @Test func policyWaitsForTheWakeCappedAndFloored() {
        #expect(FlushTimerPolicy.delay(until: nil, now: Self.now) == nil)
        #expect(FlushTimerPolicy.delay(until: Self.now.adding(.seconds(8)), now: Self.now) == .seconds(8))
        #expect(FlushTimerPolicy.delay(until: Self.now.adding(.seconds(600)), now: Self.now) == .seconds(60))
        #expect(FlushTimerPolicy.delay(until: Self.now.adding(.milliseconds(10)), now: Self.now) == .seconds(1))
        #expect(FlushTimerPolicy.delay(until: Self.now, now: Self.now) == .seconds(1))  // due now
        // Another boot's deadline has passed.
        #expect(
            FlushTimerPolicy.delay(until: LeaseInstant(bootId: "old", ct: 99_000_000_000), now: Self.now) == .seconds(1)
        )
    }

    @MainActor @Test func timerFiresAtTheWakeAndReschedules() async throws {
        let sleeper = ManualSleeper()
        let wake = WakeBox(Self.now.adding(.seconds(8)))
        let fired = FireCounter()
        let timer = ForegroundFlushTimer(
            sleeper: sleeper, nextWake: { wake.value }, now: { Self.now }, fire: { fired.increment() })
        timer.reschedule()
        try await eventually("first sleep") { sleeper.pending == 1 }
        #expect(sleeper.requested == [.seconds(8)])
        #expect(fired.count == 0)

        wake.value = Self.now.adding(.seconds(120))
        sleeper.wake()
        try await eventually("fires, then sleeps again") { fired.count == 1 && sleeper.pending == 1 }
        #expect(sleeper.requested == [.seconds(8), .seconds(60)])

        // Nothing waits any more: a reschedule replaces the sleep with none.
        wake.value = nil
        timer.reschedule()
        try await eventually("no timer") { @MainActor in sleeper.pending == 0 && timer.scheduledDelay == nil }
        sleeper.wake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired.count == 1)
    }

    /// Stopped (backgrounded, rebound) while its flush request is in progress: it doesn't come back.
    @MainActor @Test func aTimerStoppedDuringItsFireDoesNotRestart() async throws {
        let sleeper = ManualSleeper()
        let firing = OpenGate()
        let fired = FireCounter()
        let timer = ForegroundFlushTimer(
            sleeper: sleeper, nextWake: { Self.now.adding(.seconds(3)) }, now: { Self.now },
            fire: {
                fired.increment()
                await firing.wait()
            })
        timer.reschedule()
        try await eventually("sleeping") { sleeper.pending == 1 }
        sleeper.wake()
        try await eventually("firing") { fired.count == 1 }
        timer.stop()
        firing.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sleeper.requested.count == 1 && sleeper.pending == 0)
        #expect(timer.scheduledDelay == nil)
    }

    @MainActor @Test func stopCancelsThePendingSleep() async throws {
        let sleeper = ManualSleeper()
        let fired = FireCounter()
        let timer = ForegroundFlushTimer(
            sleeper: sleeper, nextWake: { Self.now.adding(.seconds(3)) }, now: { Self.now }, fire: { fired.increment() }
        )
        timer.reschedule()
        try await eventually("sleeping") { sleeper.pending == 1 }
        timer.stop()
        try await eventually("cancelled") { sleeper.pending == 0 }
        #expect(fired.count == 0 && timer.scheduledDelay == nil)
    }
}

final class WakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LeaseInstant?
    init(_ value: LeaseInstant?) { stored = value }
    var value: LeaseInstant? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.withLock { stored += 1 } }
    var count: Int { lock.withLock { stored } }
}

@Suite struct IdentityRecheckTests {
    @Test func probesEveryIntervalOnlyWhileMismatched() async throws {
        let sleeper = ManualSleeper()
        let mismatched = FlagBox(true)
        let rechecks = FireCounter()
        let task = Task {
            await IdentityRecheck.run(
                sleeper: sleeper, shouldCheck: { mismatched.value }, recheck: { rechecks.increment() })
        }
        try await eventually("first wait") { sleeper.pending == 1 }
        #expect(sleeper.requested == [.seconds(300)])
        sleeper.wake()
        try await eventually("rechecked") { rechecks.count == 1 && sleeper.pending == 1 }
        mismatched.value = false
        sleeper.wake()
        try await eventually("waiting again") { sleeper.requested.count == 3 }
        #expect(rechecks.count == 1)  // not mismatched: no probe
        task.cancel()
        _ = await task.value
    }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A one-shot gate: `wait()` suspends until `open()`.
final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}
