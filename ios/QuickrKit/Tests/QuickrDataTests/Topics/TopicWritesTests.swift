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

    func writes(transport: (any Transport)? = nil, leaseWait: Duration = .seconds(60)) async throws -> TopicWrites {
        let scope = try #require(await TopicWrites.scope(binding: Self.binding, store: harness.store))
        return writes(scope, transport: transport, leaseWait: leaseWait)
    }

    func writes(_ scope: TopicWrites.Scope, transport: (any Transport)? = nil, leaseWait: Duration = .seconds(60))
        -> TopicWrites
    {
        let syncs = syncs
        return TopicWrites(
            scope: scope, store: harness.store, transport: transport ?? harness.server,
            credentials: StaticAccessCredentials(nil), leaseWait: leaseWait, requestSync: { syncs.record($0) })
    }

    /// The `flush` lease is free (nobody holds it).
    func leaseIsFree() throws -> Bool { try harness.lease().owner == nil }

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

    // MARK: Versions

    /// The harness topic's questions with one more (an added question is allowed).
    static var nextQuestions: [Question] {
        Make.questions + [Question(key: "energy", label: "Energy", kind: .int(.init(min: 1, max: 10)))]
    }

    static func version(_ questions: [Question] = nextQuestions, timer: TopicTimer? = nil) -> TopicDraft.Version {
        TopicDraft.Version(questions: questions, timer: timer, changeNote: "")
    }

    @Test func aCheckReportsAndChangesNothing() async throws {
        let body = TopicRequests.versionCheck(Self.version(), baseVersion: 1)
        guard case .done(let report) = await try writes().checkVersion(topicId: harness.topic.id, body) else {
            Issue.record("not done")
            return
        }
        #expect(report.ok && report.nextVersion == 2)
        #expect(report.changes.map(\.questionKey) == ["energy"])
        #expect(syncs.reasons.isEmpty, "a dry run pulls nothing")
        #expect(try await local(harness.topic.id)?.currentVersion == 1)
        let request = try #require(harness.server.requests.last)
        #expect(request.url.path == "/api/v1/topics/\(harness.topic.id.wireString)/versions/check")
    }

    @Test func aCheckOnAStaleBaseIsAConflict() async throws {
        let body = TopicRequests.versionCheck(Self.version(), baseVersion: 0)
        guard case .rejected(409, let problem?) = await try writes().checkVersion(topicId: harness.topic.id, body)
        else {
            Issue.record("not a conflict")
            return
        }
        #expect(problem.code == .conflict)
        #expect(syncs.reasons.isEmpty)
    }

    @Test func aCheckWithoutAnAnswerFailsWithoutAPull() async throws {
        harness.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        let body = TopicRequests.versionCheck(Self.version(), baseVersion: 1)
        guard case .failed(let message) = await try writes().checkVersion(topicId: harness.topic.id, body) else {
            Issue.record("not failed")
            return
        }
        #expect(message == TopicWrites.noAnswerMessage)
        #expect(syncs.reasons.isEmpty)
    }

    static let timer = TopicTimer(steps: [.init(key: "load", label: "Load"), .init(key: "rinse", label: "Rinse")])

    /// The base version's row, as a pull leaves it.
    func storeVersion(_ number: Int, timer: TopicTimer?) throws {
        try harness.write { db in
            _ = try ServerLayer.insert(
                db, version: TopicVersion(version: number, questions: Make.questions, timer: timer, createdAt: Make.t0),
                id: UUID(), topicId: self.harness.topic.id)
        }
    }

    @Test func aPublishAppliesTheTopicAndPulls() async throws {
        try storeVersion(1, timer: Self.timer)
        let outcome = await try writes().publishVersion(
            topicId: harness.topic.id, Self.version(timer: Self.timer), baseVersion: 1, changeNote: "  add energy \n")
        guard case .done(let topic) = outcome else {
            Issue.record("not done")
            return
        }
        #expect(topic.currentVersion == 2)
        let stored = try #require(try await local(harness.topic.id))
        #expect(stored.currentVersion == 2 && stored.questions.map(\.key) == ["mood", "where", "weight", "energy"])
        #expect(syncs.reasons == [.afterOnlineOnly], "the pull brings the version's row")
        let request = try #require(harness.server.requests.last)
        #expect(request.url.path == "/api/v1/topics/\(harness.topic.id.wireString)/versions")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Any]
        #expect(sent?["change_note"] as? String == "add energy")
        #expect(sent?["base_version"] as? Int == 1)
        // The draft's timer (timers.md §2.1), normalised (timers2.md §1.4).
        let timer = try #require(sent?["timer"] as? [String: Any])
        #expect(Self.stepLabels(timer) == [["key": "load", "label": "Load"], ["key": "rinse", "label": "Rinse"]])
        #expect(Self.isNormalised(timer))
    }

    @Test func aPublishOfAnUntimedVersionSendsANullTimer() async throws {
        try storeVersion(1, timer: nil)
        guard
            case .done = await try writes().publishVersion(
                topicId: harness.topic.id, Self.version(), baseVersion: 1, changeNote: "")
        else {
            Issue.record("not done")
            return
        }
        let sent = try JSONSerialization.jsonObject(with: try #require(harness.server.requests.last?.body))
        let body = try #require(sent as? [String: Any])
        #expect(body.keys.contains("timer") && body["timer"] is NSNull, "sent, as null: leaving it out is a 422")
    }

    @Test func aCheckSendsTheDraftsTimer() async throws {
        let body = TopicRequests.versionCheck(Self.version(timer: Self.timer), baseVersion: 1)
        _ = await try writes().checkVersion(topicId: harness.topic.id, body)
        let sent = try JSONSerialization.jsonObject(with: try #require(harness.server.requests.last?.body))
        let object = try #require(sent as? [String: Any])
        let timer = try #require(object["timer"] as? [String: Any])
        #expect(Self.stepLabels(timer) == [["key": "load", "label": "Load"], ["key": "rinse", "label": "Rinse"]])
        #expect(Self.isNormalised(timer))
    }

    /// Each sent step's key and label.
    static func stepLabels(_ timer: [String: Any]) -> [[String: String]]? {
        (timer["steps"] as? [[String: Any]])?.map {
            ["key": $0["key"] as? String ?? "", "label": $0["label"] as? String ?? ""]
        }
    }

    /// Every list of the normalised `Timer` is sent (timers2.md §1.4): laps, variables, alerts.
    static func isNormalised(_ timer: [String: Any]) -> Bool {
        let steps = timer["steps"] as? [[String: Any]] ?? []
        return timer["laps"] is [Any] && timer["variables"] is [Any] && steps.allSatisfy { $0["alerts"] is [Any] }
    }

    @Test func aStalePublishIsAConflictAndNothingChanges() async throws {
        let body = TopicRequests.publish(Self.version(), baseVersion: 1, changeNote: "")
        guard case .done = await try writes().publishVersion(topicId: harness.topic.id, body) else {
            Issue.record("first publish")
            return
        }
        let again = await try writes().publishVersion(topicId: harness.topic.id, body)
        guard case .rejected(409, let problem?) = again, problem.code == .conflict else {
            Issue.record("\(again)")
            return
        }
        #expect(try await local(harness.topic.id)?.currentVersion == 2)
        #expect(syncs.reasons == [.afterOnlineOnly], "only the first one pulled")
    }

    @Test func anIncompatiblePublishIsRejected() async throws {
        // `mood` changes type: never allowed under the same key.
        var questions = Make.questions
        questions[0] = Question(key: "mood", label: "Mood", kind: .double(.init()))
        let body = TopicRequests.publish(Self.version(questions), baseVersion: 1, changeNote: "")
        guard case .rejected(422, let problem?) = await try writes().publishVersion(topicId: harness.topic.id, body)
        else {
            Issue.record("not rejected")
            return
        }
        #expect(problem.code.rawValue == "incompatible_version")
        #expect(try await local(harness.topic.id)?.currentVersion == 1)
    }

    @Test func latestAppliesTheServersTopic() async throws {
        var newer = harness.topic
        newer.currentVersion = 3
        newer.revision = 5
        newer.questions = Self.nextQuestions
        harness.server.put(newer)
        guard case .done(let topic) = await try writes().latest(topicId: harness.topic.id) else {
            Issue.record("not done")
            return
        }
        #expect(topic.currentVersion == 3)
        #expect(try await local(harness.topic.id)?.currentVersion == 3)
        #expect(syncs.reasons == [.afterOnlineOnly])
        #expect(harness.server.requests.last?.method == .get)
        // By the immutable id, never the slug: a slug changed elsewhere can't make it 404.
        #expect(harness.server.requests.last?.url.lastPathComponent == harness.topic.id.wireString)
    }

    @Test func aVersionCheckOrPublishOnAnotherEpochIsResyncing() async throws {
        harness.server.with { $0.epoch = "E2" }
        // The check has no preconditions, but its answer comes from another epoch.
        let check = TopicRequests.versionCheck(Self.version(), baseVersion: 1)
        guard case .resyncing = await try writes().checkVersion(topicId: harness.topic.id, check) else {
            Issue.record("check not resyncing")
            return
        }
        let body = TopicRequests.publish(Self.version(), baseVersion: 1, changeNote: "")
        guard case .resyncing = await try writes().publishVersion(topicId: harness.topic.id, body) else {
            Issue.record("not resyncing")
            return
        }
        #expect(syncs.reasons == [.requested, .requested])
        #expect(try await local(harness.topic.id)?.currentVersion == 1)
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

    // MARK: Delete under the flush lease (Codex r2)

    /// A flush that starts while the delete is sending its archive finds `flush` held: the
    /// queued archive is sent once, by the delete.
    @Test func aConcurrentFlushIsBusyAndTheArchiveIsSentOnce() async throws {
        let topicId = harness.topic.id
        let outbox = harness.outbox()
        try await outbox.archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        let gate = Gate()
        defer { gate.open() }
        harness.server.inject(where: { $0.url.path.hasSuffix("/archive") }, .delay(gate))
        let w = try await writes()
        let deleting = Task { await w.delete(topicId: topicId) }
        try await within("the request reaches the server") { await gate.arrival() }
        let flush = try await within("the flush returns") {
            try await outbox.flush(force: true, budget: .seconds(3))
        }
        #expect(flush.ending == .busy)
        gate.open()
        let result = try await within("the delete returns") { await deleting.value }
        guard case .done = result else {
            Issue.record("not deleted")
            return
        }
        #expect(harness.server.handled.filter { $0.hasSuffix("/archive → 200") }.count == 1)
        #expect(try leaseIsFree())
    }

    /// An unarchive queued before the archive (not adjacent, so K3 kept both) can't be flushed
    /// between the delete's archive and its DELETE.
    @Test func aQueuedUnarchiveNeverRunsBetweenTheArchiveAndTheDelete() async throws {
        let topicId = harness.topic.id
        harness.server.setArchived(topicId, true)
        let outbox = harness.outbox()
        try await outbox.unarchiveTopic(id: topicId, baseRevision: 1, origin: .app)
        _ = try await harness.log(outbox)
        try await outbox.archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        let gate = Gate()
        defer { gate.open() }
        harness.server.inject(where: { $0.url.path.hasSuffix("/archive") }, .delay(gate))
        let w = try await writes()
        let deleting = Task { await w.delete(topicId: topicId) }
        try await within("the request reaches the server") { await gate.arrival() }
        _ = try await within("the flush returns") {
            try await outbox.flush(force: true, budget: .seconds(3))
        }
        gate.open()
        let result = try await within("the delete returns") { await deleting.value }
        guard case .done = result else {
            Issue.record("not deleted")
            return
        }
        #expect(!harness.server.handled.contains { $0.contains("/unarchive") }, "\(harness.server.handled)")
        #expect(harness.server.handled.last == "DELETE /api/v1/topics/\(topicId.wireString) → 204")
        let left = try await harness.store.outbox.items(topicId: topicId.wireString)
        #expect(!left.contains { $0.kind == .topicArchive || $0.kind == .topicUnarchive })
    }

    @Test func theLeaseIsReleasedOnEveryPath() async throws {
        let topicId = harness.topic.id
        // Refused (an active topic).
        guard case .rejected = await try writes().delete(topicId: topicId) else {
            Issue.record("not refused")
            return
        }
        #expect(try leaseIsFree(), "after a refusal")
        // Offline.
        try await harness.outbox().archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        guard case .offline = await try writes(transport: Offline()).delete(topicId: topicId) else {
            Issue.record("not offline")
            return
        }
        #expect(try leaseIsFree(), "after offline")
        // Cancelled while the DELETE is in the network.
        let gate = Gate()
        defer { gate.open() }
        harness.server.inject(.delete, .delay(gate))
        let w = try await writes()
        let deleting = Task { await w.delete(topicId: topicId) }
        try await within("the request reaches the server") { await gate.arrival() }
        deleting.cancel()
        _ = try await within("the delete returns") { await deleting.value }
        #expect(try leaseIsFree(), "after a cancellation")
        gate.open()
        // Done.
        harness.server.setArchived(topicId, true)
        _ = await try writes().delete(topicId: topicId)
        #expect(try leaseIsFree(), "after a delete")
    }

    /// The lease expired while the archive was in the network (another flusher may hold it now):
    /// the DELETE isn't sent.
    @Test func aLeaseLostDuringTheArchiveStopsBeforeTheDelete() async throws {
        let topicId = harness.topic.id
        try await harness.outbox().archiveTopic(id: topicId, baseRevision: 1, origin: .app)
        let gate = Gate()
        defer { gate.open() }
        harness.server.inject(where: { $0.url.path.hasSuffix("/archive") }, .delay(gate))
        let w = try await writes()
        let deleting = Task { await w.delete(topicId: topicId) }
        try await within("the request reaches the server") { await gate.arrival() }
        harness.clock.advance(by: .seconds(60))
        gate.open()
        let result = try await within("the delete returns") { await deleting.value }
        guard case .busy = result else {
            Issue.record("not stopped")
            return
        }
        #expect(harness.server.count(.delete) == 0)
        #expect(try await local(topicId) != nil)
    }

    @Test func aHeldLeaseIsBusyAndSendsNothing() async throws {
        let other = try #require(try await harness.store.leases.tryAcquire(.flush, owner: "app:other"))
        let outcome = await try writes(leaseWait: .milliseconds(200)).delete(topicId: harness.topic.id)
        guard case .busy = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(harness.server.requests.isEmpty)
        _ = try await harness.store.leases.release(other)
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

    // T2-M3
    // MARK: Appearance (appearance.md §1.1, §7)

    /// The Details save with an appearance is one PATCH with `expected_revision`; the response's
    /// appearance is in the store and the view.
    @Test func updateAppearanceSendsOnePatchAndAppliesTheTheme() async throws {
        let topicId = harness.topic.id
        let change = TopicDetailsChange(
            name: "Mood!", appearance: AppearanceUpdate(color: .some(.violet), icon: .some(.emoji("🧠")), tags: ["Mind"])
        )
        guard case .done(let topic) = await try writes().updateAppearance(topicId: topicId, change, expectedRevision: 1)
        else {
            Issue.record("not done")
            return
        }
        let theme = TopicAppearance(color: .violet, icon: .emoji("🧠"), tags: ["Mind"])
        #expect(topic.appearance == theme && topic.name == "Mood!")
        #expect(try await harness.store.topics.topic(id: topicId)?.appearance == theme, "the response row is stored")
        #expect(syncs.reasons == [.afterOnlineOnly])
        #expect(harness.server.requests.count == 1, "one PATCH, details and appearance together")
        let request = try #require(harness.server.requests.last)
        #expect(request.method == .patch && request.url.path == "/api/v1/topics/\(topicId.wireString)")
        let sentBody = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(body["expected_revision"] as? Int == 1)
        #expect(body["name"] as? String == "Mood!")
        let sent = try #require(body["appearance"] as? [String: Any])
        #expect(sent["color"] as? String == "violet" && sent["tags"] as? [String] == ["Mind"])

        // Clearing: null and [] clear, an omitted field is kept.
        let clear = TopicDetailsChange(appearance: AppearanceUpdate(icon: .some(nil), tags: []))
        guard
            case .done(let cleared) = await try writes().updateAppearance(topicId: topicId, clear, expectedRevision: 2)
        else {
            Issue.record("not cleared")
            return
        }
        #expect(cleared.appearance == TopicAppearance(color: .violet))
        #expect(try await harness.store.topics.topic(id: topicId)?.appearance == TopicAppearance(color: .violet))
    }

    /// Changed elsewhere since the screen read it: a 409, and the local theme is untouched.
    @Test func aStaleAppearanceSaveIsRefusedAndNothingChanges() async throws {
        let topicId = harness.topic.id
        harness.server.setArchived(topicId, true)  // revision 2 on the server
        let change = TopicDetailsChange(appearance: AppearanceUpdate(color: .some(.red)))
        guard case .staleRevision = await try writes().updateAppearance(topicId: topicId, change, expectedRevision: 1)
        else {
            Issue.record("not stale")
            return
        }
        #expect(try await harness.store.topics.topic(id: topicId)?.appearance == .empty)
        #expect(syncs.reasons.isEmpty)
    }

    /// A create with an appearance sends it and stores the themed topic.
    @Test func createSendsTheAppearanceAndStoresIt() async throws {
        let theme = TopicAppearance(color: .cyan, icon: .emoji("💧"), tags: ["Daily"])
        let body = TopicCreateDTO(name: "Water", slug: "water", questions: Make.questions, appearance: theme)
        guard case .done(let topic) = await try writes().create(body) else {
            Issue.record("not done")
            return
        }
        #expect(topic.appearance == theme)
        #expect(try await harness.store.topics.topic(id: topic.id)?.appearance == theme)
    }
    // end T2-M3
}
