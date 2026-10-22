import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// outbox.md §13 cases 21, 22, 24–28: the adjacency rule (§8.1), K1–K3 and revision chaining (§7.3).
@Suite(.timeLimit(.minutes(5))) struct OutboxCoalescingTests {
    @Test("21 · K1: an update merges into the adjacent unsent create; no PATCH is ever sent")
    func case21() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox, answers: ["mood": .int(2), "where": .string("home")])
        let result = try await outbox.updateEntry(
            id: id, topicId: h.topic.id,
            patch: EntryUpdateDTO(answers: ["mood": .int(5), "where": nil], notes: "later"), origin: .app)
        guard case .merged(let merged) = result else {
            Issue.record("not merged: \(result)")
            return
        }
        #expect(try merged.id == id.wireString && h.items.count == 1)
        _ = try await outbox.flushNow()
        #expect(h.server.count(.post) == 1 && h.server.count(.patch) == 0)
        let entry = try #require(h.server.entry(id))
        #expect(entry.answers == ["mood": .int(5)] && entry.notes == "later")
    }

    @Test("22 · an update after an uncertain create is appended and chains to the create's revision")
    func case22() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        let result = try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "n"), origin: .app)
        guard case .appended(let update) = result else {
            Issue.record("not appended: \(result)")
            return
        }
        #expect(update.baseRevision == nil)
        _ = try await outbox.flushNow()
        let patch = try #require(h.server.requests.last { $0.method == .patch })
        #expect(patch.expectedRevision == 1)
        #expect(try h.server.entry(id)?.revision == 2 && h.items.isEmpty)
    }

    @Test("24 · (single process) unarchive, create, archive: no K3 across the create; all three succeed")
    func case24() async throws {
        let h = try OutboxHarness(topicRevision: 4, topicStatus: .archived)
        let app = h.outbox()
        let widget = try h.process("widget:1")
        try await app.unarchiveTopic(id: h.topic.id, origin: .app)
        let id = try await h.log(widget)
        let result = try await app.archiveTopic(id: h.topic.id, origin: .app)
        guard case .appended = result else {
            Issue.record("cancelled across a topic barrier: \(result)")
            return
        }
        #expect(try h.items.map(\.kind) == [.topicUnarchive, .entryCreate, .topicArchive])
        _ = try await app.flushNow()
        let path = "/api/v1/topics/\(h.topic.id.wireString)"
        #expect(
            h.server.calls == ["POST \(path)/unarchive", "POST \(path)/entries", "POST \(path)/archive"])
        #expect(h.server.handled.allSatisfy { !$0.hasSuffix("409") })
        #expect(try h.server.entry(id) != nil && h.items.isEmpty)
        #expect(h.server.with { $0.topics[h.topic.id.wireString]?.status } == .archived)
    }

    @Test("25 · an update after a topic barrier is appended, and the flush keeps user order")
    func case25() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 1)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "u1"), origin: .app)
        try await outbox.archiveTopic(id: h.topic.id, origin: .app)
        let result = try await outbox.updateEntry(
            id: entry.id, topicId: h.topic.id, patch: h.patch(mood: 1), origin: .app)
        guard case .appended = result else {
            Issue.record("merged across a barrier: \(result)")
            return
        }
        _ = try await outbox.flushNow()
        #expect(h.server.requests.map(\.method) == [.patch, .post, .patch])
        #expect(h.server.requests.map(\.expectedRevision) == [1, 1, 2])
        #expect(h.server.entry(entry.id)?.notes == "u1" && h.server.entry(entry.id)?.answers["mood"] == .int(1))
    }

    @Test("26 · K2: a third update merges into the latest of two adjacent unsent updates")
    func case26() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 2)
        let now = h.wall.now()
        let payload = { (patch: EntryUpdateDTO) in
            NewOutboxItem(
                payload: .entryUpdate(entryId: entry.id.wireString, topicId: h.topic.id.wireString, patch: patch),
                origin: .widget)
        }
        // Two adjacent updates that didn't coalesce (written directly, as by an older build).
        try h.write { db in
            _ = try OutboxStorage.append(db, payload(h.patch(notes: "a")), now: now)
            _ = try OutboxStorage.append(
                db, payload(EntryUpdateDTO(answers: ["mood": .int(1), "where": .string("home")])), now: now)
        }
        let latest = try #require(try h.items.last)
        let result = try await outbox.updateEntry(
            id: entry.id, topicId: h.topic.id, patch: EntryUpdateDTO(answers: ["mood": .int(5), "where": nil]),
            origin: .app)
        guard case .merged(let merged) = result else {
            Issue.record("not merged: \(result)")
            return
        }
        #expect(merged.id == latest.id && merged.seq == latest.seq && merged.rowVersion == latest.rowVersion + 1)
        guard case .entryUpdate(_, _, let patch) = try merged.payload() else {
            Issue.record("kind")
            return
        }
        #expect(patch.answers?["mood"] == .some(WireAnswer(.int(5))))
        #expect(patch.answers?.keys.contains("where") == true && patch.answers?["where"] == .some(nil))
        #expect(try h.items.count == 2 && h.items.first?.baseRevision == 2 && merged.baseRevision == nil)
    }

    @Test("27 · K3: archive then unarchive, adjacent and unsent, cancel; no requests")
    func case27() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        try await outbox.archiveTopic(id: h.topic.id, origin: .app)
        #expect(try await outbox.unarchiveTopic(id: h.topic.id, origin: .app) == .cancelled)
        #expect(try h.items.isEmpty)
        _ = try await outbox.flushNow()
        #expect(h.server.requests.isEmpty)
    }

    @Test("28 · unarchive after an in-flight archive is appended and sent with the archive's revision")
    func case28() async throws {
        let h = try OutboxHarness(topicRevision: 7)
        let outbox = h.outbox()
        try await outbox.archiveTopic(id: h.topic.id, origin: .app)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flush = background { try await outbox.flushNow() }
        await gate.arrival()
        guard case .appended = try await outbox.unarchiveTopic(id: h.topic.id, origin: .app) else {
            Issue.record("not appended")
            return
        }
        gate.open()
        _ = try await flush.value
        #expect(h.server.requests.map(\.expectedRevision) == [7, 8])
        #expect(h.server.with { $0.topics[h.topic.id.wireString]?.status } == .active)
        #expect(try h.items.isEmpty)
    }
}
