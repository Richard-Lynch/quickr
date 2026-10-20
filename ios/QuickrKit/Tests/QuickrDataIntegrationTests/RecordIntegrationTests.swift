import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// RECORD's fix path against the real backend: an entry the server refuses becomes a failed item
/// whose stored error decodes to the server's `Problem` (`entryFixDraft`), and `Outbox.fix` with
/// a corrected body delivers it.
extension IntegrationTests {
    @Suite("Record") @MainActor struct RecordCases {
        @Test("A refused entry's Problem comes back for fix mode; the fixed entry is delivered")
        func refusedEntryIsFixed() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTopic()
            let root = FileManager.default.temporaryDirectory.appending(path: "quickr-it-record-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            let session = try AppSession(
                configuration: .init(
                    location: StoreLocation(root: root), transport: RecordingTransport(), notifier: nil,
                    coordinator: coordinator))
            await session.start(serverURL: it.config.proxyURL)
            let store = try #require(session.store)
            let scheduler = try #require(session.scheduler)

            // n is 0–100 on the server: 500 is refused.
            let id = try await session.log(topic: topic, answers: ["n": .int(500)], notes: "too many", version: 1)
            guard case .failed(let info) = await scheduler.sendNow(itemId: id.wireString, wait: .seconds(8)) else {
                Issue.record("the server should refuse n = 500")
                return
            }
            // sendNow's own failure carries the Problem too (the record screen's EntryDelivery).
            #expect(info?.problem?.code == .invalidAnswers)
            let item = try #require(try await store.outbox.item(id: id.wireString))
            #expect(item.state == .failed && item.failureReason == .rejected)

            let questions = [Question(key: "n", label: "N", required: false, kind: .int(.init(min: 0, max: 100)))]
            let draft = try #require(item.entryFixDraft(questions: questions))
            #expect(draft.answers == ["n": .int(500)] && draft.notes == "too many")
            let problem = try #require(draft.problem, "the server's 422 body is kept and decodes")
            #expect(problem.code == .invalidAnswers)
            #expect(ProblemMapping.entryForm(problem, questionKeys: ["n"]).fields[.answer("n")] != nil)

            let outbox = try #require(session.outbox)
            let body = EntryCreateDTO(
                id: nil, answers: ["n": .int(50)], source: OutboxOrigin.app.source, capturedAt: draft.capturedAt,
                notes: draft.notes, version: 1)
            try await outbox.fix(
                itemId: draft.itemId, payload: .entryCreate(topic: topic, body: body), rowVersion: draft.rowVersion)
            #expect(await scheduler.sendNow(itemId: id.wireString, wait: .seconds(8)) == .sent)
            let server = try #require(try await it.a.entry(id))
            #expect(WebServer.answer(server) == 50)
            #expect(server["notes"] as? String == "too many")
            await session.shutdown()
        }
    }
}
