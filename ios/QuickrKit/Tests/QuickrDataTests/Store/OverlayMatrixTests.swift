import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The §3.2–§3.3 overlay matrix over every item state and server presence, checked through the
/// pure overlay and through the store: visibility, sync state and error, whether the entity is
/// counted, its version's count, and latest-entry selection.
@Suite(.timeLimit(.minutes(5))) struct OverlayMatrixTests {
    enum Kind: String, Sendable {
        case create, update, delete
    }

    struct Step: Sendable {
        var kind: Kind
        var state: OutboxState
        var reason: OutboxFailureReason? = nil
        var cancelsCreate = false
    }

    struct Spec: Sendable, CustomTestStringConvertible {
        var server: Bool
        var steps: [Step]
        var visible: Bool
        var counted: Bool
        var state: RecordSyncState
        var hasError: Bool { if case .failed = state { true } else { false } }

        var testDescription: String {
            let steps = steps.map { step in
                [step.kind.rawValue, step.state.rawValue, step.reason?.rawValue, step.cancelsCreate ? "cancels" : nil]
                    .compactMap { $0 }.joined(separator: "/")
            }
            return (server ? "server + " : "no server + ") + (steps.isEmpty ? "nothing" : steps.joined(separator: ", "))
        }
    }

    static let specs: [Spec] = {
        var specs: [Spec] = [Spec(server: true, steps: [], visible: true, counted: true, state: .synced)]
        for state in [OutboxState.pending, .inFlight, .uncertain] {
            specs += [
                Spec(
                    server: false, steps: [Step(kind: .create, state: state)], visible: true, counted: true,
                    state: .pending),
                // The server row wins: the create has landed.
                Spec(
                    server: true, steps: [Step(kind: .create, state: state)], visible: true, counted: true,
                    state: .synced),
                Spec(
                    server: true, steps: [Step(kind: .update, state: state)], visible: true, counted: true,
                    state: .pending),
                Spec(
                    server: false, steps: [Step(kind: .update, state: state)], visible: false, counted: false,
                    state: .synced),
                Spec(
                    server: true, steps: [Step(kind: .delete, state: state)], visible: false, counted: false,
                    state: .pending),
                Spec(
                    server: true, steps: [Step(kind: .update, state: state), Step(kind: .delete, state: .pending)],
                    visible: false, counted: false, state: .pending),
            ]
            for server in [false, true] {
                // A cancellation delete (outbox §9.1) hides the create, sent or not.
                specs.append(
                    Spec(
                        server: server,
                        steps: [
                            Step(kind: .create, state: state),
                            Step(kind: .delete, state: .pending, cancelsCreate: true),
                        ],
                        visible: false, counted: false, state: .pending))
            }
        }
        specs.append(
            Spec(
                server: true, steps: [Step(kind: .delete, state: .held)], visible: false, counted: false,
                state: .pending))
        for reason in [OutboxFailureReason.rejected, .conflict, .topicArchived] {
            for server in [false, true] {
                // A failed create shows (the user's content, or the server's) but is never counted.
                specs.append(
                    Spec(
                        server: server, steps: [Step(kind: .create, state: .failed, reason: reason)], visible: true,
                        counted: false, state: .failed(reason)))
                specs.append(
                    Spec(
                        server: server,
                        steps: [
                            Step(kind: .create, state: .failed, reason: reason), Step(kind: .update, state: .pending),
                        ],
                        visible: true, counted: false, state: .failed(reason)))
                for kind in [Kind.update, .delete] {
                    specs.append(
                        Spec(
                            server: server, steps: [Step(kind: kind, state: .failed, reason: reason)], visible: server,
                            counted: server, state: server ? .failed(reason) : .synced))
                }
            }
        }
        // deleted_elsewhere items have no row of their own; whatever the server holds shows as is.
        for kind in [Kind.create, .update, .delete] {
            for server in [false, true] {
                specs.append(
                    Spec(
                        server: server, steps: [Step(kind: kind, state: .failed, reason: .deletedElsewhere)],
                        visible: server, counted: server, state: .synced))
            }
        }
        return specs
    }()

    private static let errorJSON = #"{"message":"Rejected","status":422}"#

    private static func payload(_ kind: Kind, entity: UUID, topic: Topic) -> OutboxPayload {
        switch kind {
        case .create: Make.createPayload(topic: topic, minutes: 5)
        case .update:
            .entryUpdate(
                entryId: entity.wireString, topicId: topic.id.wireString,
                patch: EntryUpdateDTO(answers: ["mood": .int(5)]))
        case .delete: .entryDelete(entryId: entity.wireString, topicId: topic.id.wireString)
        }
    }

    @Test(arguments: specs) func pureOverlay(_ spec: Spec) throws {
        let topic = Make.topic()
        let entity = UUID()
        let server = spec.server ? Make.entry(id: entity, topicId: topic.id) : nil
        let items = spec.steps.enumerated().map { index, step in
            let payload = Self.payload(step.kind, entity: entity, topic: topic)
            return OutboxItem(
                seq: Int64(index + 1), id: step.kind == .create ? entity.wireString : UUID().wireString,
                kind: payload.kind, entityId: entity.wireString, topicId: topic.id.wireString,
                payloadJSON: try! payload.encoded(), state: step.state, failureReason: step.reason,
                lastErrorJSON: step.state == .failed ? Self.errorJSON : nil, cancelsCreate: step.cancelsCreate,
                origin: .app, createdAt: Make.t0, updatedAt: Make.t0)
        }
        let overlay = try EntryOverlay.resolve(server: server, items: items)
        #expect(overlay.isVisible == spec.visible)
        #expect(overlay.isCounted == spec.counted)
        // A row that isn't shown has no state to show.
        if spec.visible {
            #expect(overlay.syncState == spec.state)
            #expect((overlay.lastError != nil) == spec.hasError)
        }
    }

    @Test(arguments: specs) func throughTheStore(_ spec: Spec) async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let entity = UUID()
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.insert(db, version: Make.version(1), id: UUID(), topicId: topic.id)
            if spec.server { _ = try ServerLayer.upsert(db, entry: Make.entry(id: entity, topicId: topic.id)) }
        }
        for step in spec.steps {
            let item = try s.enqueue(
                Self.payload(step.kind, entity: entity, topic: topic),
                id: step.kind == .create ? entity : UUID())
            try s.write { (db: Database) throws in
                try db.execute(
                    sql: """
                        UPDATE outbox_item SET state = ?, failure_reason = ?, last_error_json = ?, cancels_create = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        step.state.rawValue, step.reason?.rawValue, step.state == .failed ? Self.errorJSON : nil,
                        step.cancelsCreate, item.id,
                    ])
            }
        }
        let listed = try await s.store.entries.entries(topicId: topic.id, limit: nil)
        #expect(listed.map(\.id) == (spec.visible ? [entity] : []))
        let single = try await s.store.entries.entry(id: entity)
        #expect((single != nil) == spec.visible)
        if let single {
            #expect(single.syncState == spec.state)
            #expect((single.lastError != nil) == spec.hasError)
        }
        #expect(try await s.store.topics.topic(id: topic.id)?.topic.entryCount == (spec.counted ? 1 : 0))
        #expect(try await s.store.versions.versions(topicId: topic.id).map(\.entryCount) == [spec.counted ? 1 : 0])
        #expect(try await s.store.entries.latestEntry(topicId: topic.id)?.id == (spec.counted ? entity : nil))
    }
}
