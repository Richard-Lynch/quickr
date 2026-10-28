import Foundation
import QuickrCore

// The coordinator's seams: how it reads the feed, how it asks the outbox to flush, and how it
// tells the rest of the app what changed. Each is a protocol so tests and other processes can
// plug in their own.

/// One feed page request (sync-protocol.md §1.1): `GET /changes?after=&limit=500`, classified
/// with the identity and epoch checks first (§1.4). `APIClient` satisfies it as is.
///
/// `options.expecting` is the identity the response is checked against: the store's
/// `(server_id, epoch)` for a live page, `(server_id, target epoch)` for a staged page, nil for a
/// bootstrap from `after=0` (which adopts whatever the page reports, §2.2).
public protocol FeedFetcher: Sendable {
    func listChanges(after cursor: Int, limit: Int, options: RequestOptions) async throws -> APIResponse<ChangePage>
    /// The same feed, handing its responses' offset samples to `serverOffset` (timers.md §5.1)
    /// and their API levels to `levels`, which also holds requests back while this build is
    /// outdated (client-versions.md §4.1).
    func recording(serverOffset: any ServerOffsetRecorder, levels: any ClientLevelGate) -> any FeedFetcher
}

extension FeedFetcher {
    /// A feed that keeps no samples (test fakes).
    public func recording(serverOffset: any ServerOffsetRecorder, levels: any ClientLevelGate) -> any FeedFetcher {
        self
    }
}

extension APIClient: FeedFetcher {
    public func recording(serverOffset: any ServerOffsetRecorder, levels: any ClientLevelGate) -> any FeedFetcher {
        var client = self
        client.serverOffset = serverOffset
        client.levels = levels
        return client
    }
}

/// Builds the feed for a server's base URL (the store's `base_url`, or the URL typed during
/// onboarding).
public typealias FeedFactory = @Sendable (URL) -> any FeedFetcher

/// Why the coordinator asks for a flush.
public enum FlushRequestReason: String, Sendable, Hashable {
    /// A pull drained (outbox.md §10 "after a pull").
    case afterPull
    /// A rebuild swapped in a new layer: kept items are resent with the new epoch (§7 step 3).
    case afterSwap
}

/// How the coordinator asks the outbox to flush (OUTBOX supplies it). It must return at once:
/// the flush runs elsewhere, under its own `flush` lease. The coordinator calls it only after it
/// has released every lease it held, and never flushes itself.
public protocol FlushRequester: Sendable {
    func requestFlush(reason: FlushRequestReason)
}

// The app routes its `Outbox`'s signals to the coordinator with `SyncCoordinator.handle(_:)`, and
// the coordinator's flush requests to the outbox with `OutboxFlushBridge` (OutboxBridge.swift).

/// What the coordinator reports after it commits, for the parts of the app that react outside
/// the store: notifications (§4.3 step 4), widgets, categories and APNs (§2.1, §12.1 step 8).
public enum SyncEvent: Sendable, Hashable {
    /// Topics were tombstoned (a page, or a swap that dropped them). Remove their pending and
    /// delivered notifications; widgets render "Topic deleted". Categories are kept.
    case topicsDeleted(serverId: String, topicIds: [UUID])
    /// The server layer changed: reload widget timelines, recompute the badge.
    case layerChanged(serverId: String)
    /// A rebuild swapped the layer (§7): everything derived from it may have changed.
    case layerSwapped(serverId: String, layerGen: Int)
    /// A store finished its first bootstrap: register categories and APNs (§2.1).
    case bootstrapped(serverId: String)
    /// A reset moved the server to a fresh file (§12.1 step 8): re-register categories.
    case storeReset(serverId: String, storeGen: Int)
}

/// Receives `SyncEvent`s. Must return at once (dispatch any work itself).
public protocol SyncEventSink: Sendable {
    func handle(_ event: SyncEvent)
}

/// Ignores every event and flush request.
public struct NoSyncSideEffects: FlushRequester, SyncEventSink {
    public init() {}

    public func requestFlush(reason: FlushRequestReason) {}

    public func handle(_ event: SyncEvent) {}
}
