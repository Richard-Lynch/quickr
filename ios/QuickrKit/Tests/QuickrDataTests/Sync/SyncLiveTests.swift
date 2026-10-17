import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// Bootstrap, steady-state pulls and the merge rules (sync-protocol.md §2, §4, §10, §13 S1, S2,
/// S8, S14), file-backed, against the simulated feed.
@Suite(.timeLimit(.minutes(1))) struct SyncLiveTests {
    // MARK: - §2.1 bootstrap

    @Test func connectCreatesTheStoreAndAppliesTheFirstPageFromMemory() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let result = await coordinator.connect(baseURL: SyncEnv.baseURL)
        #expect(result == .connected(serverId: FakeFeedServer.defaultServerId, isNew: true, sync: .synced))
        // The first page was applied from memory: one request in all.
        #expect(env.afters() == [0])
        let store = try await env.activeStore()
        #expect(store.storeGen == 1 && store.url?.lastPathComponent == "\(FakeFeedServer.defaultServerId).g1.sqlite")
        let state = try await store.state()
        #expect(state.epoch == FakeFeedServer.fixtureEpoch && state.cursor == 16 && state.headSeen == 16)
        #expect(state.bootstrapComplete && state.layerGen == 1 && state.lastPullAt == env.wall.now())
        #expect(try await store.ids("topic") == env.server.liveTopicIds())
        #expect(try await store.ids("entry") == Set(env.server.liveEntries().keys))
        #expect(try await store.count("topic_version") == 4)
        #expect(env.recorder.events.contains(.bootstrapped(serverId: FakeFeedServer.defaultServerId)))
        #expect(env.recorder.flushes == [.afterPull])
        let server = try await env.partitions.registry.repository.server(id: FakeFeedServer.defaultServerId)
        #expect(server?.lastSyncAt == env.wall.now())
        // Derived fields are the client's own (§3.3): Water has 2 entries in the fixture.
        let water = try await store.topics.topic(id: UUID(uuidString: FakeFeedServer.water)!)
        #expect(water?.topic.entryCount == 2)
    }

    @Test func connectToAKnownServerActivatesItsStoreAndPullsFromItsCursor() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        env.server.addEntry()
        let result = await coordinator.connect(baseURL: SyncEnv.baseURL)
        #expect(result == .connected(serverId: FakeFeedServer.defaultServerId, isNew: false, sync: .synced))
        // The probe page is discarded; the pull continues from the store's cursor.
        #expect(env.afters() == [0, 0, 16])
        #expect(try await env.activeStore().state().cursor == 17)
    }

    @Test func connectRejectsAResponseWithoutIdentityHeaders() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        env.server.intercept { _ in HTTPResponse(status: 200, body: Data("<html>".utf8)) }
        #expect(await env.coordinator().connect(baseURL: SyncEnv.baseURL) == .notQuickr)
        #expect(try await env.partitions.registry.repository.servers().isEmpty)
    }

    /// S1 (unit simulation of the INT case): every page commits with its cursor; a bootstrap
    /// killed mid-way resumes from the last committed cursor, and the final state equals the
    /// server's.
    @Test func s1BootstrapResumesFromTheLastCommittedCursor() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        for minute in 0..<20 { env.server.addEntry(glasses: minute, minutes: minute) }
        env.server.updateEntry("0f1e2d3c-4b5a-4968-8778-000000000004", glasses: 9)
        env.server.deleteEntry("0f1e2d3c-4b5a-4968-8778-000000000003")
        let head = env.server.head
        env.server.intercept { after in
            after >= 13 ? HTTPResponse(status: 503, headers: [:], body: Data()) : nil
        }
        let first = env.coordinator(pageLimit: 5)
        let result = await first.connect(baseURL: SyncEnv.baseURL)
        guard case .connected(_, true, .failed(.unreachable)) = result else {
            Issue.record("expected the bootstrap to fail mid-way, got \(result)")
            return
        }
        let interrupted = try await env.activeStore()
        let cursor = try await interrupted.state().cursor
        #expect(cursor == 13)
        #expect(try await !interrupted.state().bootstrapComplete)
        #expect(first.status.activity == .idle && first.status.lastFailure != nil)

        // The app is relaunched (a new process: its own registry pool).
        env.server.intercept(nil)
        let requestsBefore = env.transport.requests.count
        let relaunched = env.coordinator(owner: "app:B", partitions: try env.otherProcess(), pageLimit: 5)
        #expect(await relaunched.bootstrapIfNeeded() == .synced)
        #expect(env.afters(from: requestsBefore).first == 13)
        let store = try await env.activeStore()
        let state = try await store.state()
        #expect(state.cursor == head && state.bootstrapComplete)
        let revisions = try await store.writer.read { db in
            Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, revision FROM entry").map {
                    ($0["id"] as String, $0["revision"] as Int)
                })
        }
        #expect(revisions == env.server.liveEntries())
        #expect(try await store.ids("topic") == env.server.liveTopicIds())
        #expect(try await store.count("tombstone", "kind = 'entry'") == 1)
        // A drained store needs no bootstrap.
        #expect(await relaunched.bootstrapIfNeeded() == .synced)
        #expect(env.afters(from: requestsBefore).count == (head - 13 + 4) / 5)
    }

    @Test func bootstrapStatusReportsLoadingHistoryProgress() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        for minute in 0..<10 { env.server.addEntry(minutes: minute) }
        let coordinator = env.coordinator(pageLimit: 5)
        let updates = coordinator.statusUpdates()
        let collector = Task {
            var seen: [SyncStatus.Activity] = []
            for await status in updates {
                seen.append(status.activity)
                if status.bootstrapComplete, status.activity == .idle { break }
            }
            return seen
        }
        try await env.connect(coordinator)
        let seen = await collector.value
        #expect(seen.contains(.pulling(bootstrapping: true, cursor: 7, head: 26)))
        #expect(seen.last == .idle)
        #expect(!coordinator.status.isBehind && coordinator.status.cursor == 26)
    }

    // MARK: - Steady state (§4)

    @Test func steadyStatePullAppliesUpsertsUpdatesAndDeletions() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let topic = env.server.addTopic(name: "Sleep")
        env.server.addVersion(topicId: topic, number: 1)
        let entry = env.server.addEntry(topicId: topic, glasses: 3)
        env.server.updateEntry(entry, glasses: 4)
        env.server.deleteEntry("0f1e2d3c-4b5a-4968-8778-000000000004")
        #expect(await coordinator.sync(reason: .pullToRefresh) == .synced)
        #expect(env.afters() == [0, 16])
        let state = try await store.state()
        #expect(state.cursor == env.server.head && state.headSeen == env.server.head)
        let row = try await store.entries.entry(id: UUID(uuidString: entry)!)
        #expect(row?.entry.revision == 2 && row?.entry.answers["glasses"] == .int(4))
        #expect(try await store.count("entry", "id = '0f1e2d3c-4b5a-4968-8778-000000000004'") == 0)
        #expect(try await store.count("tombstone", "id = '0f1e2d3c-4b5a-4968-8778-000000000004'") == 1)
        #expect(env.recorder.flushes == [.afterPull, .afterPull])
        #expect(env.recorder.events.filter { $0 == .layerChanged(serverId: FakeFeedServer.defaultServerId) }.count == 2)
    }

    @Test func anEmptyPageIsDrainedWithoutChanges() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let before = try await store.fingerprint()
        env.wall.advance(by: 60)
        #expect(await coordinator.sync(reason: .timer) == .synced)
        let after = try await store.state()
        #expect(after.cursor == 16 && after.lastPullAt == env.wall.now())
        #expect(try await store.fingerprint() != before)  // last_pull_at moved, nothing else
    }

    /// S2: a page fetched before one of our PATCHes but applied after its ack keeps the newer row.
    @Test func s2RevisionGuardDropsAnOlderRowArrivingAfterAnAck() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let id = "0f1e2d3c-4b5a-4968-8778-000000000005"
        env.server.updateEntry(id, glasses: 2)  // revision 2, on the page
        env.gate.arm { $0 == 16 }
        let sync = Task { await coordinator.sync(reason: .pullToRefresh) }
        try await env.gate.waitUntilParked()
        // Our PATCH lands as revision 3 and its ack commits while the page is in flight.
        try await store.writer.write { db in
            try db.execute(
                sql: "UPDATE entry SET revision = 3, answers_json = '{\"glasses\":7}' WHERE id = ?", arguments: [id])
        }
        env.gate.release()
        #expect(await sync.value == .synced)
        let row = try await store.entries.entry(id: UUID(uuidString: id)!)
        #expect(row?.entry.revision == 3 && row?.entry.answers["glasses"] == .int(7))
        #expect(try await store.state().cursor == 17)
    }

    // MARK: - §4.3 tombstones and dependents

    /// S14 with the recorded fixtures: `listChanges.bootstrap`, then `listChanges.topic_deletion`.
    @Test func s14TopicTombstoneCascadesAndResolvesDependents() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let bootstrap = try Fixtures.api("listChanges.bootstrap").response()
        let deletion = try Fixtures.api("listChanges.topic_deletion").response()
        env.server.intercept { after in after == 0 ? bootstrap : deletion }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let topic = FakeFeedServer.oldHabit
        let ref = TopicRef(id: UUID(uuidString: topic)!, slug: "old-habit", name: "Old habit")
        #expect(try await store.count("topic_version", "topic_id = '\(topic)'") == 1)

        let create = try await store.enqueue(Payloads.create(topic: ref))
        let doomed = UUID().wireString
        let update = try await store.enqueue(Payloads.update(doomed, topicId: topic))
        let later = try await store.enqueue(Payloads.delete(doomed, topicId: topic))
        let held = try await store.enqueue(
            Payloads.delete(UUID().wireString, topicId: topic), hold: env.clock.now().adding(.seconds(5)))
        let archive = try await store.enqueue(.topicArchive(topicId: topic))
        let unarchive = try await store.enqueue(.topicUnarchive(topicId: topic))
        let inFlight = try await store.enqueue(Payloads.create(topic: ref))
        try await store.setItemState(inFlight.id, .inFlight)
        let other = try await store.enqueue(Payloads.create())
        try await store.writer.write { db in
            for table in ["ui_draft", "stats_cache", "widget_state"] {
                let extra = table == "stats_cache" ? ", epoch" : ""
                let value = table == "stats_cache" ? ", 'E1'" : ""
                for topicId in [topic, FakeFeedServer.water] {
                    try db.execute(
                        sql: """
                            INSERT INTO \(table) (key, topic_id, payload_json\(extra), \(
                                table == "stats_cache" ? "fetched_at" : "updated_at"))
                            VALUES ('\(table)-\(topicId)', '\(topicId)', '{}'\(value), 0)
                            """)
                }
            }
        }
        try await env.partitions.registry.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notification_category (id, server_id, topic_id, actions_json, created_at)
                    VALUES ('cat-1', ?, ?, '[]', 0)
                    """,
                arguments: [FakeFeedServer.defaultServerId, topic])
        }

        #expect(await coordinator.sync(reason: .push) == .synced)
        #expect(try await store.state().cursor == 20)
        #expect(try await store.count("topic", "id = '\(topic)'") == 0)
        #expect(try await store.count("topic_version", "topic_id = '\(topic)'") == 0)
        #expect(try await store.count("tombstone", "kind = 'version' AND topic_id = '\(topic)'") == 1)
        #expect(try await store.count("tombstone", "kind = 'topic' AND id = '\(topic)'") == 1)
        // Dependents follow the §4.3 table.
        let failedCreate = try await store.item(create.id)
        #expect(failedCreate?.state == .failed && failedCreate?.failureReason == .deletedElsewhere)
        #expect(failedCreate?.lastErrorJSON?.contains("Deleted on another device") == true)
        for retired in [update, later, held, archive] { #expect(try await store.item(retired.id) == nil) }
        #expect(try await store.item(unarchive.id)?.failureReason == .deletedElsewhere)
        #expect(try await store.item(inFlight.id)?.state == .inFlight)
        #expect(try await store.item(other.id)?.state == .pending)
        // Local state for the topic is cleared; the other topic's and the categories are kept.
        for table in ["ui_draft", "stats_cache", "widget_state"] {
            #expect(try await store.count(table, "topic_id = '\(topic)'") == 0)
            #expect(try await store.count(table, "topic_id = '\(FakeFeedServer.water)'") == 1)
        }
        #expect(try await env.partitions.registry.repository.notificationCategories().count == 1)
        #expect(
            env.recorder.events.contains(
                .topicsDeleted(serverId: FakeFeedServer.defaultServerId, topicIds: [UUID(uuidString: topic)!])))
    }

    /// `listChanges.deletion`: an entry tombstone fails a queued update and retires a queued delete.
    @Test func entryTombstoneResolvesItsDependents() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let bootstrap = try Fixtures.api("listChanges.bootstrap").response()
        let deletion = try Fixtures.api("listChanges.deletion").response()
        env.server.intercept { after in after == 0 ? bootstrap : deletion }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let id = "0f1e2d3c-4b5a-4968-8778-000000000005"
        let update = try await store.enqueue(Payloads.update(id))
        let unrelated = try await store.enqueue(Payloads.update("0f1e2d3c-4b5a-4968-8778-000000000004"))
        #expect(await coordinator.sync(reason: .push) == .synced)
        #expect(try await store.count("entry", "id = '\(id)'") == 0)
        #expect(try await store.item(update.id)?.failureReason == .deletedElsewhere)
        #expect(try await store.item(unrelated.id)?.state == .pending)
        #expect(try await store.entries.entry(id: UUID(uuidString: id)!) == nil)
        // A replayed upsert of a tombstoned id is dropped (ids are never reused, F3).
        let water = try await store.topics.topic(id: UUID(uuidString: FakeFeedServer.water)!)
        #expect(water?.topic.entryCount == 1)
    }

    // MARK: - §4.4 pull-ack

    @Test func pullAckRemovesALandedCreateAndChainsTheNextItem() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let id = UUID()
        let create = try await store.enqueue(Payloads.create(), id: id)
        try await store.setItemState(create.id, .uncertain)
        let update = try await store.enqueue(Payloads.update(id.wireString))
        #expect(update.baseRevision == nil)
        let inFlightId = UUID()
        let inFlight = try await store.enqueue(Payloads.create(), id: inFlightId)
        try await store.setItemState(inFlight.id, .inFlight)
        env.server.addEntry(id: id)  // the POST committed; its response was lost
        env.server.addEntry(id: inFlightId)
        #expect(await coordinator.sync(reason: .push) == .synced)
        #expect(try await store.item(create.id) == nil)
        #expect(try await store.item(update.id)?.baseRevision == 1)
        // An in-flight create is left to its sender's CAS.
        #expect(try await store.item(inFlight.id)?.state == .inFlight)
    }

    // MARK: - §2.2 page checks

    @Test func anUndecodablePageAppliesNothingAndKeepsTheCursor() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.addEntry()
        let headers: HTTPHeaders = [
            QuickrHeader.serverId: FakeFeedServer.defaultServerId, QuickrHeader.epoch: FakeFeedServer.fixtureEpoch,
        ]
        env.server.intercept { _ in HTTPResponse(status: 200, headers: headers, body: Data("{\"items\":7}".utf8)) }
        let before = try await store.fingerprint()
        guard case .failed(.protocolError) = await coordinator.sync(reason: .timer) else {
            Issue.record("expected a protocol error")
            return
        }
        #expect(try await store.fingerprint() == before)
        #expect(coordinator.status.consecutiveFailures == 1 && coordinator.status.retryDelay == .seconds(2))
        #expect(coordinator.status.isBehind)
    }

    @Test func aPageWhoseNextIsBelowTheCursorIsAProtocolError() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let body = """
            {"server_id":"\(FakeFeedServer.defaultServerId)","epoch":"\(FakeFeedServer.fixtureEpoch)","head":16,
             "next":3,"has_more":false,"server_time":"2026-03-04T12:00:00Z","items":[],"deleted":[]}
            """
        let headers: HTTPHeaders = [
            QuickrHeader.serverId: FakeFeedServer.defaultServerId, QuickrHeader.epoch: FakeFeedServer.fixtureEpoch,
        ]
        env.server.intercept { _ in HTTPResponse(status: 200, headers: headers, body: Data(body.utf8)) }
        let before = try await store.fingerprint()
        #expect(await coordinator.sync(reason: .timer) == .failed(.protocolError("next 3 is below the cursor 16")))
        #expect(try await store.fingerprint() == before)
    }

    @Test func failuresBackOffAndASuccessResetsThem() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        env.server.intercept { _ in HTTPResponse(status: 502) }
        _ = await coordinator.sync(reason: .timer)
        _ = await coordinator.sync(reason: .retry)
        _ = await coordinator.sync(reason: .retry)
        #expect(coordinator.status.consecutiveFailures == 3 && coordinator.status.retryDelay == .seconds(8))
        env.server.intercept(nil)
        #expect(await coordinator.sync(reason: .retry) == .synced)
        #expect(coordinator.status.consecutiveFailures == 0 && coordinator.status.lastFailure == nil)
    }

    @Test func automaticRetryRunsAfterTheBackoff() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let delays = DelayLog()
        let coordinator = env.coordinator(configure: {
            $0.autoRetry = true
            $0.sleep = { delay in delays.append(delay) }
        })
        try await env.connect(coordinator)
        env.server.addEntry()
        env.server.intercept { after in after == 16 && delays.values.isEmpty ? HTTPResponse(status: 502) : nil }
        _ = await coordinator.sync(reason: .timer)
        try await eventually("the retry drained the feed") { try await env.activeStore().state().cursor == 17 }
        #expect(delays.values == [.seconds(2)])
    }

    @Test func backoffFollowsTheFormula() {
        #expect(SyncBackoff.delay(failures: 1, jitter: 0) == .seconds(2))
        #expect(SyncBackoff.delay(failures: 4, jitter: 0) == .seconds(16))
        #expect(SyncBackoff.delay(failures: 4, jitter: 0.2) == .milliseconds(19_200))
        #expect(SyncBackoff.delay(failures: 4, jitter: -0.5) == .milliseconds(12_800))
        #expect(SyncBackoff.delay(failures: 30, jitter: 0.2) == .seconds(300))
    }

    // MARK: - §10 skew

    @Test func skewIsSmoothedAndSlowRoundTripsAreDiscarded() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        env.wall.set(Make.t0.addingTimeInterval(-10))  // the server is 10 s ahead
        let store = try await env.connect(coordinator)
        #expect(try await store.state().skewMilliseconds == 10_000)
        env.wall.set(Make.t0.addingTimeInterval(-20))
        _ = await coordinator.sync(reason: .timer)
        #expect(try await store.state().skewMilliseconds == 13_000)
        // A 6 s round trip is discarded.
        env.gate.arm { _ in true }
        let sync = Task { await coordinator.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        env.wall.advance(by: 6)
        env.gate.release()
        #expect(await sync.value == .synced)
        #expect(try await store.state().skewMilliseconds == 13_000)
        #expect(!coordinator.status.clockIsOff)
    }

    // MARK: - §8.3 identity (S8, unit side)

    /// S8's coordinator side: a page from another server never applies; the store enters identity
    /// mismatch, stops pulling, and "Keep waiting" clears it when the server comes back.
    @Test func s8IdentityMismatchStopsSyncUntilTheServerMatchesAgain() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let item = try await store.enqueue(Payloads.create())
        env.server.serverId = "00000000-0000-4000-8000-0000000000ff"
        env.server.addEntry()
        let before = try await store.fingerprint()
        #expect(await coordinator.sync(reason: .activation) == .identityMismatch)
        #expect(try await store.state().identityMismatch)
        #expect(try await store.item(item.id)?.state == .pending)
        let flushes = env.recorder.flushes.count
        let requests = env.transport.requests.count
        #expect(await coordinator.sync(reason: .activation) == .identityMismatch)
        #expect(env.transport.requests.count == requests && env.recorder.flushes.count == flushes)
        #expect(coordinator.status.identityMismatch)
        // Still the other server: keep waiting.
        #expect(await coordinator.recheckIdentity() == .identityMismatch)
        let mismatched = try await store.fingerprint()
        #expect(mismatched != before)  // only the flag
        env.server.serverId = FakeFeedServer.defaultServerId
        #expect(await coordinator.recheckIdentity() == .synced)
        let cleared = try await store.state()
        #expect(!cleared.identityMismatch && cleared.cursor == 17)
    }

    @Test func aSuccessWithoutIdentityHeadersIsAnIdentityMismatch() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.intercept { _ in HTTPResponse(status: 200, body: Data("{}".utf8)) }
        #expect(await coordinator.sync(reason: .activation) == .identityMismatch)
        #expect(try await store.state().identityMismatch)
    }

    @Test func aProxyErrorWithoutHeadersIsRetriedNotInterpreted() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.intercept { _ in HTTPResponse(status: 403, body: Data("Access denied".utf8)) }
        guard case .failed(.unreachable) = await coordinator.sync(reason: .activation) else {
            Issue.record("expected a retryable failure")
            return
        }
        #expect(try await !store.state().identityMismatch)
    }

    @Test func noActiveStoreMeansNothingToSync() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        #expect(await env.coordinator().sync(reason: .launch) == .noActiveStore)
        #expect(await env.coordinator().bootstrapIfNeeded() == .noActiveStore)
    }

    @Test func aSecondCoordinatorIsBusyWhileTheFirstHoldsSync() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let first = env.coordinator()
        try await env.connect(first)
        env.gate.arm { _ in true }
        let sync = Task { await first.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        let second = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await second.sync(reason: .timer) == .busy)
        env.gate.release()
        #expect(await sync.value == .synced)
    }

    @Test func callsDuringARunJoinIt() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        env.gate.arm { _ in true }
        let first = Task { await coordinator.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        let second = Task { await coordinator.sync(reason: .pullToRefresh) }
        try await Task.sleep(for: .milliseconds(20))
        env.gate.release()
        #expect(await first.value == .synced)
        #expect(await second.value == .synced)
        // The joined call made the run go once more.
        #expect(env.afters() == [0, 16, 16])
    }
}

final class DelayLog: Sendable {
    private let state = Mutex<[Duration]>([])

    var values: [Duration] { state.withLock { $0 } }

    func append(_ delay: Duration) { state.withLock { $0.append(delay) } }
}
