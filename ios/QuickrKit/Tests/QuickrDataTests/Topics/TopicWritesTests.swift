import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// The online-only topic writes (sync-protocol.md §11) against `FakeServer` through the real
/// `APIClient`: fail-closed scope, Expect headers, fenced application of the response (or a
/// delete's tombstone and outbox cascade), the pull after it, and how each failure reads.
@Suite struct TopicWritesTests {
    /// The coordinator runs a write asked for.
    final class SyncRequests: Sendable {
        private let log = Mutex<[SyncReason]>([])
        var reasons: [SyncReason] { log.withLock { $0 } }
        func record(_ reason: SyncReason) { log.withLock { $0.append(reason) } }
    }

    /// A transport that is offline: nothing ever leaves.
    struct Offline: Transport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            throw TransportError.unreachable("offline")
        }
    }

    static let binding = AppSession.Binding(serverId: "server-1", storeGen: 1, baseURL: FakeServer.base)

    let harness: OutboxHarness
    let syncs = SyncRequests()

    init() throws {
        harness = try OutboxHarness()
    }

    func writes(transport: (any Transport)? = nil) async throws -> TopicWrites {
        let scope = try #require(await TopicWrites.scope(binding: Self.binding, store: harness.store))
        return writes(scope, transport: transport)
    }

    func writes(_ scope: TopicWrites.Scope, transport: (any Transport)? = nil) -> TopicWrites {
        let syncs = syncs
        return TopicWrites(
            scope: scope, store: harness.store, transport: transport ?? harness.server,
            credentials: StaticAccessCredentials(nil), requestSync: { syncs.record($0) })
    }

    func local(_ id: UUID) async throws -> Topic? { try await harness.store.topics.topic(id: id)?.topic }

    static let daily = Schedule.daily(
        Schedule.Daily(times: [TimeOfDay("08:00")!], days: [1, 2, 3, 4, 5], timezone: "Europe/London"))

    // MARK: Scope

    @Test func scopeNeedsTheBoundStoreAndItsIdentity() async throws {
        let scope = try #require(await TopicWrites.scope(binding: Self.binding, store: harness.store))
        #expect(scope.identity == ServerIdentity(serverId: "server-1", epoch: "E1"))
        #expect(scope.binding == Self.binding)

        #expect(await TopicWrites.scope(binding: nil, store: harness.store) == nil)
        #expect(await TopicWrites.scope(binding: Self.binding, store: nil) == nil)
        var other = Self.binding
        other.serverId = "server-2"
        #expect(await TopicWrites.scope(binding: other, store: harness.store) == nil, "another server's store")
        var newer = Self.binding
        newer.storeGen = 2
        #expect(await TopicWrites.scope(binding: newer, store: harness.store) == nil, "a reset store")
    }

    @Test func noEpochYetMeansNoScope() async throws {
        try harness.setSyncState("epoch = NULL")
        #expect(await TopicWrites.scope(binding: Self.binding, store: harness.store) == nil)
    }

    // MARK: Create

    @Test func createAppliesTheTopicAndPulls() async throws {
        let body = TopicCreateDTO(name: "Water", slug: "water", questions: Make.questions, schedule: Self.daily)
        guard case .done(let topic) = await try writes().create(body) else {
            Issue.record("not done")
            return
        }
        #expect(topic.slug == "water")
        #expect(try await local(topic.id)?.schedule == Self.daily, "the response row is in the store")
        #expect(syncs.reasons == [.afterOnlineOnly])
        let request = try #require(harness.server.requests.last)
        #expect(request.method == .post && request.url.path == "/api/v1/topics")
        #expect(request.headers[QuickrHeader.expectServerId] == "server-1")
        #expect(request.headers[QuickrHeader.expectEpoch] == "E1")
    }

    @Test func aSlugConflictIsRejectedAndNothingChanges() async throws {
        let body = TopicCreateDTO(name: "Mood again", slug: harness.topic.slug, questions: Make.questions)
        guard case .rejected(409, let problem?) = await try writes().create(body) else {
            Issue.record("not rejected")
            return
        }
        #expect(problem.code == .conflict)
        #expect(try await harness.store.topics.topics().count == 1)
        #expect(syncs.reasons.isEmpty)
    }

    @Test func offlineSendsNothingAndSaysSo() async throws {
        let outcome = await try writes(transport: Offline()).create(
            TopicCreateDTO(name: "Water", questions: Make.questions))
        guard case .offline = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(harness.server.requests.isEmpty)
        #expect(syncs.reasons.isEmpty)
    }

    @Test func aLostAnswerIsUnconfirmedAndPulls() async throws {
        harness.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        let outcome = await try writes().create(TopicCreateDTO(name: "Water", slug: "water", questions: Make.questions))
        guard case .unconfirmed = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(syncs.reasons == [.afterOnlineOnly], "the pull shows whether it was created")
        #expect(harness.server.handled == ["POST /api/v1/topics → 201"])
        #expect(try await harness.store.topics.topics().count == 1, "nothing applied without an answer")
    }

    // MARK: Identity

    @Test func anotherEpochIsResyncingAndNothingExecutes() async throws {
        harness.server.with { $0.epoch = "E2" }
        let outcome = await try writes().update(topicId: harness.topic.id, TopicUpdateDTO(name: "Renamed"))
        guard case .resyncing = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(syncs.reasons == [.requested])
        #expect(harness.server.with { $0.topics[harness.topic.id.wireString]?.name } == "Mood")
        #expect(try await local(harness.topic.id)?.name == "Mood")
    }

    @Test func anotherServerIsResyncing() async throws {
        harness.server.with { $0.serverId = "server-2" }
        let outcome = await try writes().delete(topicId: harness.topic.id)
        guard case .resyncing = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(syncs.reasons == [.requested])
    }

    // MARK: Update

    @Test func scheduleSetAndClearedIsApplied() async throws {
        let w = try await writes()
        guard
            case .done = await w.update(topicId: harness.topic.id, TopicUpdateDTO(schedule: .value(.init(Self.daily))))
        else {
            Issue.record("set failed")
            return
        }
        #expect(try await local(harness.topic.id)?.schedule == Self.daily)
        guard case .done = await w.update(topicId: harness.topic.id, TopicUpdateDTO(schedule: .null)) else {
            Issue.record("clear failed")
            return
        }
        #expect(try await local(harness.topic.id)?.schedule == nil)
        #expect(try await local(harness.topic.id)?.revision == 3)
        #expect(syncs.reasons == [.afterOnlineOnly, .afterOnlineOnly])
    }

    @Test func aStaleRevisionChangesNothing() async throws {
        let outcome = await try writes().update(
            topicId: harness.topic.id, TopicUpdateDTO(name: "Renamed", expectedRevision: 7))
        guard case .staleRevision = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(try await local(harness.topic.id)?.name == "Mood")
        #expect(syncs.reasons.isEmpty)
    }

    @Test func aSwapMeanwhileDiscardsTheLocalWriteButStillReportsSuccess() async throws {
        let scope = try #require(await TopicWrites.scope(binding: Self.binding, store: harness.store))
        try harness.setSyncState("layer_gen = layer_gen + 1")  // an epoch rebuild swapped meanwhile
        let outcome = await writes(scope).update(topicId: harness.topic.id, TopicUpdateDTO(name: "Renamed"))
        guard case .done(let topic) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(topic.name == "Renamed", "the server executed it")
        #expect(try await local(harness.topic.id)?.name == "Mood", "the fence kept the stale response out")
        #expect(syncs.reasons == [.afterOnlineOnly], "the pull brings it")
    }

    @Test func aMissingTopicIsNotFound() async throws {
        let outcome = await try writes().update(topicId: UUID(), TopicUpdateDTO(name: "x"))
        guard case .notFound = outcome else {
            Issue.record("\(outcome)")
            return
        }
    }

    // MARK: Delete

    @Test func deletingAnActiveTopicIsRefused() async throws {
        guard case .rejected(409, let problem?) = await try writes().delete(topicId: harness.topic.id) else {
            Issue.record("not refused")
            return
        }
        #expect(problem.detail == "archive the topic before deleting it")
        #expect(try await local(harness.topic.id) != nil)
    }

    /// Codex r1: an archive queued behind a failed entry change never leaves the outbox, so a
    /// confirmed delete sends it itself, then deletes; nothing waits on the queue.
    @Test func aQueuedArchiveBehindAFailedChangeIsSentByTheDelete() async throws {
        let topicId = harness.topic.id
        let outbox = harness.outbox()
        let failed = try await harness.log(outbox)
        try harness.write { db in
            try db.execute(
                sql: "UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected' WHERE id = ?",
                arguments: [failed.wireString])
        }
        try await outbox.archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        #expect(harness.server.with { $0.topics[topicId.wireString]?.status } == .active, "not on the server yet")

        guard case .done = await try writes().delete(topicId: topicId) else {
            Issue.record("not deleted")
            return
        }
        #expect(
            harness.server.handled.suffix(2) == [
                "POST /api/v1/topics/\(topicId.wireString)/archive → 200",
                "DELETE /api/v1/topics/\(topicId.wireString) → 204",
            ])
        #expect(try await local(topicId) == nil)
        let left = try await harness.store.outbox.items(topicId: topicId.wireString)
        #expect(left.allSatisfy { $0.state == .failed && $0.failureReason == .deletedElsewhere }, "\(left)")
        #expect(!left.contains { $0.kind == .topicArchive }, "the queued archive is resolved with the topic")
    }

    @Test func aFailedArchiveStopsTheDeleteBeforeItIsSent() async throws {
        let topicId = harness.topic.id
        try await harness.outbox().archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        harness.server.inject(.post, .respond(FakeServer.problem(500, "internal_error", "boom")))
        guard case .unconfirmed = await try writes().delete(topicId: topicId) else {
            Issue.record("not unconfirmed")
            return
        }
        #expect(harness.server.count(.delete) == 0, "no DELETE after a failed archive")
        #expect(try await local(topicId) != nil)
    }

    @Test func aQueuedUnarchiveIsNotSentAsAnArchive() async throws {
        let topicId = harness.topic.id
        harness.server.setArchived(topicId, true)
        try await harness.outbox().unarchiveTopic(id: topicId, baseRevision: 1, origin: .app)
        guard case .done = await try writes().delete(topicId: topicId) else {
            Issue.record("not deleted")
            return
        }
        #expect(harness.server.count(.post) == 0, "nothing archived")
    }

    @Test func offlineTheQueuedArchiveAndTheDeleteBothWait() async throws {
        let topicId = harness.topic.id
        try await harness.outbox().archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        guard case .offline = await try writes(transport: Offline()).delete(topicId: topicId) else {
            Issue.record("not offline")
            return
        }
        #expect(try await local(topicId) != nil)
        #expect(try await TopicWrites.pendingArchives(topicId: topicId, in: harness.store).count == 1)
    }

    @Test func deletingTombstonesLocallyAndResolvesItsOutboxItems() async throws {
        let topicId = harness.topic.id
        harness.server.setArchived(topicId, true)
        let entry = try harness.seedEntry()
        let outbox = harness.outbox()
        _ = try await harness.log(outbox)  // a queued create for the topic
        try await outbox.updateEntry(
            id: entry.id, topicId: topicId, patch: harness.patch(notes: "later"), baseRevision: 1, origin: .app)
        #expect(try await TopicWrites.unsyncedChanges(topicId: topicId, in: harness.store) == 2)
        try await outbox.archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        #expect(
            try await TopicWrites.unsyncedChanges(topicId: topicId, in: harness.store) == 2, "an archive isn't lost")
        #expect(
            try await TopicWrites.pendingArchives(topicId: topicId, in: harness.store).map(\.kind) == [.topicArchive])

        guard case .done = await try writes().delete(topicId: topicId) else {
            Issue.record("not deleted")
            return
        }
        #expect(try await local(topicId) == nil)
        #expect(try harness.read { db in try ServerLayer.isTombstoned(db, kind: .topic, id: topicId.wireString) })
        #expect(try harness.isTombstoned(entry.id), "its entries went with it")
        #expect(try harness.view(entry.id) == nil)
        let left = try await harness.store.outbox.items(topicId: topicId.wireString)
        #expect(left.allSatisfy { $0.state == .failed && $0.failureReason == .deletedElsewhere }, "\(left)")
        #expect(syncs.reasons == [.afterOnlineOnly, .afterOnlineOnly], "after the queued archive, then the delete")
    }
}
