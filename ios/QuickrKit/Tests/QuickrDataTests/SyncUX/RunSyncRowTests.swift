import Foundation
import QuickrCore
import QuickrData
import Testing

/// The sync sheet's rows for `run.event` items (timers.md §8.1): their titles, and Fix.
@Suite struct RunSyncRowTests {
    static let topicId = SyncSheetModelTests.topicId
    static let runId = "7b000000-0000-4000-8000-000000000001"
    static let topic = TopicRef(id: UUID(uuidString: topicId)!, slug: "morning", name: "Morning")

    static func event(_ type: String, answers: [String: WireAnswer?]? = nil) -> OutboxPayload {
        .runEvent(
            RunEventPayload(
                topic: topic, runId: runId,
                event: RunEventInDTO(
                    id: UUID().wireString, type: type, at: "2026-10-24T08:00:00.000Z", answers: answers)))
    }

    static func failed(_ payload: OutboxPayload, reason: OutboxFailureReason = .rejected, status: Int = 422)
        throws -> OutboxItem
    {
        let id = UUID().wireString
        return OutboxItem(
            seq: 1, id: id, kind: payload.kind, entityId: runId, topicId: topicId, payloadJSON: try payload.encoded(),
            state: .failed, maybeDelivered: false, attempts: 1, due: nil, failureReason: reason,
            lastErrorJSON: #"{"message":"no","status":\#(status)}"#, origin: .app,
            createdAt: SyncSheetModelTests.t0, updatedAt: SyncSheetModelTests.t0)
    }

    private func row(_ item: OutboxItem) throws -> SyncItemRow {
        let model = SyncSheetModel(
            items: [item], topics: [Self.topicId: SyncTopicInfo(name: "Morning")], online: true,
            lastSyncAt: nil, now: SyncSheetModelTests.now)
        return try #require(model.rows.first)
    }

    private var ref: TopicLinkRef { TopicLinkRef(id: UUID(uuidString: Self.topicId)!) }

    @Test func aRefusedFinishIsFixedInTheAnswersForm() throws {
        let item = try Self.failed(Self.event("finish", answers: ["mood": WireAnswer(.string("good"))]))
        let row = try row(item)
        let title: String = row.title
        #expect(title == "Details · Morning")
        let fix: Route? = row.fix
        let runId = try #require(UUID(uuidString: Self.runId))
        #expect(fix == .runDetails(ref, runId: runId, fix: item.id))
    }

    @Test func aRefusedStopWithAnswersIsFixedInTheAnswersForm() throws {
        let item = try Self.failed(Self.event("stop", answers: ["mood": WireAnswer(.string("ok"))]))
        let fix: Route? = try row(item).fix
        let runId = try #require(UUID(uuidString: Self.runId))
        #expect(fix == .runDetails(ref, runId: runId, fix: item.id))
    }

    @Test func aRefusedPlainStopOpensTheRunScreen() throws {
        let row = try row(try Self.failed(Self.event("stop")))
        let fix: Route? = row.fix
        #expect(fix == .run(ref))
        let title: String = row.title
        #expect(title == "Stop · Morning")
    }

    @Test func noFixWhenTheRunIsGoneOrTheRefusalIsNotAnAnswerError() throws {
        let gone = try Self.failed(Self.event("finish"), reason: .deletedElsewhere, status: 404)
        let goneFix: Route? = try row(gone).fix
        #expect(goneFix == nil)
        let conflict = try Self.failed(Self.event("finish"), status: 409)
        let conflictFix: Route? = try row(conflict).fix
        #expect(conflictFix == nil)
        let next = try Self.failed(Self.event("next"))
        let nextFix: Route? = try row(next).fix
        #expect(nextFix == nil)
    }
}
