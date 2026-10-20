import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

@Suite struct EntryFixDraftTests {
    let topic = TopicRef(
        id: UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c10")!, slug: "workout", name: "Workout")
    let questions = [
        Question(key: "type", label: "Type", kind: .choice(.init(options: [EnumOption(value: "run", label: "Run")]))),
        Question(key: "distance", label: "Distance", kind: .double(.init(unit: "km"))),
    ]
    let captured = Date(timeIntervalSince1970: 1_790_000_000)

    func item(
        state: OutboxState = .failed, reason: OutboxFailureReason? = .rejected, maybeDelivered: Bool = false,
        kind: OutboxKind = .entryCreate, error: String? = nil
    ) throws -> OutboxItem {
        let body = EntryCreateDTO(
            id: nil, answers: ["type": .string("run"), "distance": .double(5)], source: "ios", capturedAt: captured,
            notes: "windy", version: 2)
        let payload = try OutboxPayload.entryCreate(topic: topic, body: body).encoded()
        return OutboxItem(
            seq: 1, id: "3f2504e0-4f89-11d3-9a0c-0305e82c3301", kind: kind,
            entityId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            topicId: topic.id, payloadJSON: payload, state: state, maybeDelivered: maybeDelivered,
            failureReason: reason,
            lastErrorJSON: error, origin: .app, createdAt: captured, updatedAt: captured, rowVersion: 4)
    }

    @Test func aRejectedCreateBecomesADraftWithItsProblem() throws {
        let error = #"""
            {"message": "Some answers need attention", "status": 422,
             "body": {"code": "invalid_answers", "detail": "Some answers need attention",
                      "errors": [{"loc": ["body", "answers", "distance"], "message": "Must be at most 3 km"}]}}
            """#
        let draft = try #require(try item(error: error).entryFixDraft(questions: questions))
        #expect(draft.itemId == "3f2504e0-4f89-11d3-9a0c-0305e82c3301" && draft.rowVersion == 4)
        #expect(draft.topic == topic)
        // Typed by the questions: 5 is a double here.
        #expect(draft.answers == ["type": .string("run"), "distance": .double(5)])
        #expect(draft.capturedAt == captured && draft.notes == "windy")
        #expect(draft.problem?.code == .invalidAnswers)
        #expect(draft.problem?.errors.first?.message == "Must be at most 3 km")
        #expect(draft.message == "Some answers need attention")
    }

    @Test func aFailureWithoutABodyKeepsItsMessage() throws {
        let draft = try #require(
            try item(error: #"{"message": "Rejected (400)", "status": 400}"#).entryFixDraft(questions: questions))
        #expect(draft.problem == nil && draft.message == "Rejected (400)")
        let none = try #require(try item().entryFixDraft(questions: questions))
        #expect(none.problem == nil && none.message == nil)
    }

    @Test func onlyAFailedNeverDeliveredCreateCanBeFixed() throws {
        #expect(try item(state: .pending, reason: nil).entryFixDraft(questions: questions) == nil)
        #expect(try item(maybeDelivered: true).entryFixDraft(questions: questions) == nil)
        #expect(try item(reason: .deletedElsewhere).entryFixDraft(questions: questions) == nil)
        #expect(try item(reason: .conflict).entryFixDraft(questions: questions) == nil)
        #expect(try item(reason: .topicArchived).entryFixDraft(questions: questions) != nil)
        #expect(try item(reason: .futureTime).entryFixDraft(questions: questions) != nil)
    }

    /// `Limits.serverDefaults` (used before any limits are fetched) matches the server's.
    @Test func serverDefaultLimitsMatchTheFixture() throws {
        let fixture = try Fixtures.api("getLimits")
        let decoded = try LimitsDTO.decode(try #require(fixture.body), using: WireCoding.decoder()).toDomain()
        #expect(Limits.serverDefaults == decoded)
    }
}
