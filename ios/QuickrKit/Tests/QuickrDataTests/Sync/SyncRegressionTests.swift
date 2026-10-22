import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// Regressions from the SYNC Codex review (docs/ios/reviews/m1-wp-sync-codex.md): S8 under a
/// flush takeover, connect serialization, the reset intent fence, fenced mismatch writes and
/// partial epoch headers while staging.
@Suite(.timeLimit(.minutes(5))) struct SyncRegressionTests {
    static let e2 = SyncRebuildTests.e2
    static let e3 = SyncRebuildTests.e3

    // MARK: - Finding 1: S8 when the swap takes over an expired flush lease

    /// A sender really holds `flush`, has a create in flight that the user undid (a
    /// `cancels_create` delete follows it), and dies. The swap takes over the expired lease: the
    /// takeover transaction recovers the in-flight items **and** removes the cancelled create,
    /// so the POST can never be resent ahead of its DELETE.
    @Test func swapTakeoverOfAnExpiredFlushLeaseRemovesCancelledCreates() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let sender = try #require(try await store.leases.tryAcquire(.flush, owner: "widget:F"))
        let create = try await store.enqueue(Payloads.create())
        let update = try await store.enqueue(Payloads.update("0f1e2d3c-4b5a-4968-8778-000000000002"))
        // The sender's claims, under its own lease token.
        try await store.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'in_flight', claim_token = ?, claim_owner = ?, claim_layer_gen = 1,
                      claim_epoch = ?, attempts = 1 WHERE id IN (?, ?)
                    """,
                arguments: [sender.token, sender.owner, FakeFeedServer.fixtureEpoch, create.id, update.id])
        }
        let cancel = try await store.outbox.appendRawForTesting(
            NewOutboxItem(payload: Payloads.delete(create.id), origin: .app, cancelsCreate: true))
        // The sender dies; its 30 s lease expires (the coordinator's own lease is fresh).
        env.clock.advance(by: .seconds(31))
        env.server.rotateEpoch(to: Self.e2)
        #expect(await coordinator.sync(reason: .activation) == .synced)
        #expect(try await store.state().layerGen == 2)
        #expect(try await store.item(create.id) == nil)
        #expect(try await store.item(cancel.id)?.state == .pending)
        let recovered = try #require(try await store.item(update.id))
        #expect(recovered.state == .uncertain && recovered.maybeDelivered && recovered.claimToken == nil)
        #expect(try await store.leases.record(.flush).owner == nil)
    }

    // MARK: - Finding 2: connect is serialized

    /// While connect fetches server B, a sync for A is requested. Connect must still activate B,
    /// apply B's first page and pull B; it never joins A's run.
    @Test func connectNeverJoinsTheRunOfThePreviousServer() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let serverB = try FakeFeedServer()
        serverB.serverId = "00000000-0000-4000-8000-0000000000bb"
        let transportB = FakeTransport()
        transportB.stub(where: { $0.url.path == "/api/v1/changes" }, { try serverB.respond($0) })
        let gateB = FeedGate()
        let feedA = env.feed
        let coordinator = env.coordinator(feed: { url in
            url.host == "b.example"
                ? GatedFeed(
                    inner: APIClient(baseURL: url, transport: transportB, identity: StaticServerIdentity(nil)),
                    gate: gateB)
                : feedA(url)
        })
        try await env.connect(coordinator)
        env.server.addEntry()
        env.gate.arm { $0 == 16 }
        gateB.arm { $0 == 0 }
        let connect = Task { await coordinator.connect(baseURL: URL(string: "https://b.example")!) }
        try await gateB.waitUntilParked()
        let syncA = Task { await coordinator.sync(reason: .timer) }
        try await Task.sleep(for: .milliseconds(50))
        // Releases A only later, so a connect that joined A's run would see A's result.
        let releaseA = Task {
            try? await Task.sleep(for: .milliseconds(300))
            env.gate.release()
        }
        gateB.release()
        #expect(await connect.value == .connected(serverId: serverB.serverId, isNew: true, sync: .synced))
        let store = try await env.activeStore()
        #expect(store.serverId == serverB.serverId)
        let state = try await store.state()
        #expect(state.cursor == serverB.head && state.bootstrapComplete)
        // A's sync was queued behind the connect and then pulled the active store, B.
        #expect(env.gate.parked.isEmpty)
        #expect(await syncA.value == .synced)
        releaseA.cancel()
    }

    @Test func concurrentConnectsRunOneAfterTheOther() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        env.gate.arm { $0 == 0 }
        let first = Task { await coordinator.connect(baseURL: SyncEnv.baseURL) }
        try await env.gate.waitUntilParked()
        let second = Task { await coordinator.connect(baseURL: SyncEnv.baseURL) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.afters() == [0])  // the second probe waits for the first connect
        env.gate.release()
        let id = FakeFeedServer.defaultServerId
        #expect(await first.value == .connected(serverId: id, isNew: true, sync: .synced))
        #expect(await second.value == .connected(serverId: id, isNew: false, sync: .synced))
    }

    // MARK: - Finding 3: the reset retire belongs to the current attempt

    /// Two callers hold the same persisted intent. X holds the leases and is about to retire; the
    /// relaunched coordinator times out waiting for them and aborts. X's retire, right after the
    /// abort, is refused in its own transaction: nothing is retired and the intent is gone.
    @Test func aTimedOutResumeAbortsTheAttemptBeforeAnotherCallerRetires() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let old = try await env.connect(env.coordinator())
        let intent = try await env.partitions.persistResetIntent(store: old, confirmedCount: 0, confirmedMaxSeq: 0)
        let x = try #require(try await old.leases.acquireSyncThenFlush(owner: "app:X", waitingUpTo: .seconds(60)))
        let relaunched = env.coordinator(
            owner: "app:B", partitions: try env.otherProcess(),
            configure: {
                $0.resetLeaseWait = .milliseconds(50)
            })
        _ = await relaunched.bootstrapIfNeeded()
        #expect(await relaunched.resumedReset == .timedOut)
        let outcome = try await old.retire(
            confirmedCount: 0, confirmedMaxSeq: 0, intentToken: intent.pendingToken, sync: x.sync, flush: x.flush)
        #expect(outcome == .intentAborted)
        #expect(try await !old.isRetired())
        let server = try await env.partitions.registry.repository.server(id: FakeFeedServer.defaultServerId)
        #expect(server?.pendingGen == nil && server?.storeGen == 1)
    }

    // MARK: - Finding 4: mismatch writes are fenced on the coordinator's lease

    /// A coordinator's old response with only a new epoch header is released after another
    /// coordinator took over: its `startRebuild` is fenced, so nothing is written.
    @Test func anOldPartialHeaderResponseAfterTakeoverWritesNothing() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let a = env.coordinator(owner: "app:A")
        let store = try await env.connect(a)
        let once = Mutex(false)
        env.server.intercept { after in
            guard after == 16,
                once.withLock({ used in
                    defer { used = true }
                    return !used
                })
            else { return nil }
            return HTTPResponse(status: 500, headers: [QuickrHeader.epoch: Self.e2])
        }
        env.gate.arm { $0 == 16 }
        let suspended = Task { await a.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        env.clock.advance(by: .seconds(61))
        let b = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await b.sync(reason: .activation) == .synced)
        let before = try await store.fingerprint()
        env.gate.release()
        #expect(await suspended.value == .superseded)
        #expect(try await store.fingerprint() == before)
        #expect(try await store.state().rebuilding == nil)
    }

    /// The same, for a mismatch without any epoch header: the `epoch_suspect` write is fenced on
    /// the captured live context and `sync` claim, so it can't re-set a flag the newer
    /// coordinator cleared.
    @Test func anOldEpochlessMismatchAfterTakeoverDoesNotSetSuspect() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let feed = env.feed
        let once = EpochlessMismatchFeed.Once()
        let coordinatorFeed: FeedFactory = { url in EpochlessMismatchFeed(inner: feed(url), once: once) }
        let a = env.coordinator(owner: "app:A", feed: coordinatorFeed)
        let store = try await env.connect(env.coordinator(owner: "app:setup"))
        env.gate.arm { $0 == 16 }
        let suspended = Task { await a.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        env.clock.advance(by: .seconds(61))
        let b = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await b.sync(reason: .activation) == .synced)
        env.gate.release()
        #expect(await suspended.value == .superseded)
        #expect(try await !store.state().epochSuspect)
    }

    @Test func anEpochlessMismatchUnderAValidLeaseSetsSuspect() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let feed = env.feed
        let store = try await env.connect(env.coordinator(owner: "app:setup"))
        let once = EpochlessMismatchFeed.Once()
        let a = env.coordinator(owner: "app:A", feed: { url in EpochlessMismatchFeed(inner: feed(url), once: once) })
        guard case .failed(.protocolError) = await a.sync(reason: .timer) else {
            Issue.record("expected a protocol error")
            return
        }
        #expect(try await store.state().epochSuspect)
    }

    // MARK: - Finding 5: partial epoch headers while staging

    /// Staging for E2 is under way; the server rotates again and a staged request answers with
    /// only an `X-QuickR-Epoch: E3` header. Staging restarts toward E3 and swaps.
    @Test func aPartialEpochHeaderWhileStagingRestartsTowardTheNewEpoch() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator(pageLimit: 5)
        let store = try await env.connect(coordinator)
        env.server.rotateEpoch(to: Self.e2)
        env.server.intercept { after in after > 10 && after != 16 ? HTTPResponse(status: 503) : nil }
        _ = await coordinator.sync(reason: .timer)
        #expect(try await store.state().rebuilding == Self.e2)
        let stageCursor = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state")
        }
        env.server.rotateEpoch(to: Self.e3)
        let once = Mutex(false)
        env.server.intercept { after in
            guard after == stageCursor,
                once.withLock({ used in
                    defer { used = true }
                    return !used
                })
            else {
                return nil
            }
            return HTTPResponse(status: 500, headers: [QuickrHeader.epoch: Self.e3])
        }
        let requests = env.transport.requests.count
        #expect(await coordinator.sync(reason: .timer) == .synced)
        #expect(Array(env.afters(from: requests).prefix(2)) == [stageCursor, 0])
        let state = try await store.state()
        #expect(state.epoch == Self.e3 && state.layerGen == 2)
    }
}

/// Answers the first live request with an epoch mismatch that carries no epoch header (the
/// classifier's `missingHeaders` shape), then behaves like `inner`.
struct EpochlessMismatchFeed: FeedFetcher {
    final class Once: Sendable {
        private let used = Mutex(false)

        func take() -> Bool {
            used.withLock { used in
                defer { used = true }
                return !used
            }
        }
    }

    let inner: any FeedFetcher
    let once: Once

    func listChanges(after cursor: Int, limit: Int, options: RequestOptions) async throws -> APIResponse<ChangePage> {
        let response = try await inner.listChanges(after: cursor, limit: limit, options: options)
        guard cursor == 16, once.take() else { return response }
        return APIResponse(
            outcome: .epochMismatch(
                .missingHeaders(status: 200, observed: ObservedIdentity(serverId: nil, epoch: nil))),
            status: 200, observed: ObservedIdentity(serverId: nil, epoch: nil), expected: options.expecting,
            bodyIsTrusted: false)
    }
}
