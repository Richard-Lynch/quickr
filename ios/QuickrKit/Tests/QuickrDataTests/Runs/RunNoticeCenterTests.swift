import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// Toast or list (`RunNoticeCenter`, timers.md §11.4): a notice recorded while the app is on
/// screen is toasted and dropped; one recorded before the app became active, or while it was in
/// the background, is listed for the sync sheet and never toasted; a binding without a store
/// lists nothing.
@MainActor @Suite(.timeLimit(.minutes(2))) struct RunNoticeCenterTests {
    final class Toasts: Sendable {
        private let shown = Mutex<[String]>([])
        var all: [String] { shown.withLock { $0 } }
        func show(_ text: String) { shown.withLock { $0.append(text) } }
    }

    final class Now: Sendable {
        private let value = Mutex(Make.t0)
        var date: Date { value.withLock { $0 } }
        func set(_ date: Date) { value.withLock { $0 = date } }
    }

    private func record(_ h: OutboxHarness, id: String, at: Date) throws {
        try h.write { db in
            try db.execute(
                sql: """
                    INSERT INTO run_notice (id, run_id, topic_id, topic_name, tap, reason, stopped_at, created_at)
                    VALUES (?, 'r1', 't1', 'Morning', 'next', 'already_closed', NULL, ?)
                    """,
                arguments: [id, at.timeIntervalSince1970])
        }
    }

    /// Runs the center over `h`'s store until `until` holds.
    private func follow(
        _ center: RunNoticeCenter, _ h: OutboxHarness, until: @escaping @MainActor () -> Bool
    ) async throws {
        let task = Task { await center.observe(h.store) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !until() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aNoticeRecordedWhileOnScreenIsToastedAndDropped() async throws {
        let h = try OutboxHarness()
        let toasts = Toasts()
        let now = Now()
        let center = RunNoticeCenter(toast: { toasts.show($0) }, now: { now.date })
        center.didBecomeActive()
        try record(h, id: "e1", at: Make.t0.addingTimeInterval(5))
        try await follow(center, h) { !toasts.all.isEmpty }
        let shown = toasts.all
        #expect(shown == ["Morning was already stopped."])
        let listed = center.notices.count
        #expect(listed == 0)
        // Dropped from the store (before the toast), so a later launch doesn't list it either.
        let stored = try await h.store.runNotices.all().count
        #expect(stored == 0)
    }

    @Test func aNoticeFromBeforeTheAppBecameActiveIsListedNotToasted() async throws {
        let h = try OutboxHarness()
        let toasts = Toasts()
        let now = Now()
        now.set(Make.t0.addingTimeInterval(60))
        let center = RunNoticeCenter(toast: { toasts.show($0) }, now: { now.date })
        try record(h, id: "e1", at: Make.t0)
        center.didBecomeActive()
        try await follow(center, h) { center.notices.count == 1 }
        let shown = toasts.all
        #expect(shown.isEmpty)
        let stored = try await h.store.runNotices.all().count
        #expect(stored == 1)
    }

    @Test func aNoticeRecordedInTheBackgroundIsListed() async throws {
        let h = try OutboxHarness()
        let toasts = Toasts()
        let center = RunNoticeCenter(toast: { toasts.show($0) }, now: { Make.t0 })
        center.didBecomeActive()
        center.didEnterBackground()
        try record(h, id: "e1", at: Make.t0.addingTimeInterval(5))
        try await follow(center, h) { center.notices.count == 1 }
        let shown = toasts.all
        #expect(shown.isEmpty)
    }

    @Test func noStoreListsNothing() async throws {
        let h = try OutboxHarness()
        let center = RunNoticeCenter(toast: { _ in }, now: { Make.t0 })
        try record(h, id: "e1", at: Make.t0)
        try await follow(center, h) { center.notices.count == 1 }
        await center.observe(nil)
        let listed = center.notices.count
        #expect(listed == 0)
        let scope: EntryScope? = center.scope
        #expect(scope == nil)
    }
}
