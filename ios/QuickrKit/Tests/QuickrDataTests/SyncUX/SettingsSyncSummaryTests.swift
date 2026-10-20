import Foundation
import QuickrData
import Testing

/// Settings ▸ "Offline & sync" follows the sync pill's rules.
@Suite struct SettingsSyncSummaryTests {
    static func outbox(queued: Int = 0, held: Int = 0, failed: Int = 0) -> OutboxSummary {
        var summary = OutboxSummary()
        summary.queued = queued
        summary.held = held
        summary.failed = failed
        return summary
    }

    static let synced: SyncStatus = {
        var status = SyncStatus(serverId: "s")
        status.lastSyncAt = Date(timeIntervalSince1970: 1_760_000_000)
        return status
    }()

    @Test func allSyncedAndOnline() {
        let summary = SettingsSyncSummary(summary: Self.outbox(), status: Self.synced, online: true)
        #expect(summary.connection == .online)
        #expect(summary.headline == "All changes synced")
        #expect(summary.lastSyncAt == Self.synced.lastSyncAt)
        #expect(summary.problem == nil && !summary.hasItems)
    }

    @Test func offlineWithItemsWaiting() {
        let summary = SettingsSyncSummary(summary: Self.outbox(queued: 3), status: Self.synced, online: false)
        #expect(summary.connection == .offline)
        #expect(summary.headline == "Offline · 3 waiting to sync")
        #expect(summary.hasItems)
    }

    /// The server can't be reached even though the device has a network path.
    @Test func anUnreachableServerReadsAsOffline() {
        var status = Self.synced
        status.lastFailure = .unreachable("timed out")
        status.consecutiveFailures = 1
        let summary = SettingsSyncSummary(summary: Self.outbox(), status: status, online: true)
        #expect(summary.connection == .offline)
        #expect(summary.headline == "Offline")
        #expect(summary.problem == nil)
    }

    @Test func waitingAndFailedItems() {
        let waiting = SettingsSyncSummary(summary: Self.outbox(queued: 2), status: Self.synced, online: true)
        #expect(waiting.connection == .online && waiting.headline == "2 waiting to sync" && waiting.hasItems)
        let failed = SettingsSyncSummary(summary: Self.outbox(queued: 1, failed: 1), status: Self.synced, online: true)
        #expect(failed.headline == "1 failed to sync" && failed.hasItems)
    }

    /// A delete in its undo window isn't waiting to sync yet.
    @Test func aHeldDeleteIsNotWaiting() {
        let summary = SettingsSyncSummary(summary: Self.outbox(queued: 1, held: 1), status: Self.synced, online: true)
        #expect(summary.headline == "All changes synced")
        #expect(!summary.hasItems)
    }

    /// Repeated pull failures: "Sync error" and why; a single one stays quiet.
    @Test func repeatedFailuresSayWhy() {
        var status = Self.synced
        status.lastFailure = .rejected(status: 403, message: "Forbidden by Cloudflare Access")
        status.consecutiveFailures = SyncPillState.failuresBeforeError
        let summary = SettingsSyncSummary(summary: Self.outbox(), status: status, online: true)
        #expect(summary.headline == "Sync error")
        #expect(summary.problem == "Forbidden by Cloudflare Access")
        status.consecutiveFailures = 1
        let once = SettingsSyncSummary(summary: Self.outbox(), status: status, online: true)
        #expect(once.headline == "All changes synced" && once.problem == nil)
    }

    @Test func neverSyncedAndNoStore() {
        let summary = SettingsSyncSummary(summary: nil, status: SyncStatus(), online: true)
        #expect(summary.lastSyncAt == nil && summary.headline == "All changes synced" && !summary.hasItems)
    }

    @Test func aDifferentServer() {
        var status = Self.synced
        status.identityMismatch = true
        let summary = SettingsSyncSummary(summary: Self.outbox(queued: 2), status: status, online: true)
        #expect(summary.headline == "Different server")
        #expect(summary.connection == .online)
    }
}
