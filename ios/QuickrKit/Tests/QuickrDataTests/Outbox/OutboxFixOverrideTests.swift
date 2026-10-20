import Foundation
import GRDB
import QuickrCore
import Testing

@testable import QuickrData

/// Fixing a refused edit while later edits of the entry wait behind it (outbox.md §7.2, §11): the
/// fields the user corrected are their latest word, so the later queued edits drop them.
@Suite struct OutboxFixOverrideTests {
    /// U1 (mood 9) refused; U2 (mood 3, notes "later") queued behind it.
    func refusedThenQueued(_ h: OutboxHarness, _ outbox: Outbox, later: EntryUpdateDTO) async throws
        -> (Entry, OutboxItem)
    {
        let entry = try h.seedEntry()
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(mood: 9), origin: .app)
        let u1 = try #require(try h.items.first)
        try h.write { db in
            try db.execute(
                sql: "UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected' WHERE id = ?",
                arguments: [u1.id])
        }
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: later, origin: .app)
        #expect(try h.items.count == 2, "U2 is its own item behind the refused U1")
        return (entry, try #require(try h.item(u1.id)))
    }

    func fixed(_ entry: Entry, _ h: OutboxHarness, mood: Int) -> OutboxPayload {
        .entryUpdate(entryId: entry.id.wireString, topicId: h.topic.id.wireString, patch: h.patch(mood: mood))
    }

    func patch(_ item: OutboxItem) throws -> EntryUpdateDTO {
        guard case .entryUpdate(_, _, let patch) = try item.payload() else { throw CancellationError() }
        return patch
    }

    @Test func theEntryBeforeAnItemLeavesItAndLaterOnesOut() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let (entry, u1) = try await refusedThenQueued(h, outbox, later: h.patch(notes: "later", mood: 3))
        let before = try h.read { db in try StoreView.entry(db, id: entry.id.wireString, before: u1.seq) }
        #expect(before?.answers == entry.answers, "the server's row: neither U1 nor U2")
        #expect(before?.notes == entry.notes)
        #expect(try h.view(entry.id)?.entry.answers["mood"] == .int(3), "the view applies both")
    }

    @Test func aCorrectionBeatsALaterQueuedEdit() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let (entry, u1) = try await refusedThenQueued(h, outbox, later: h.patch(notes: "later", mood: 3))
        try await outbox.fix(
            itemId: u1.id, payload: fixed(entry, h, mood: 5), rowVersion: u1.rowVersion,
            overriding: EntryOverride(answerKeys: ["mood"]))
        let items = try h.items
        #expect(items.count == 2)
        let u2 = try patch(items[1])
        #expect(u2.answers?["mood"] == nil, "the corrected field leaves the later edit")
        #expect(u2.notes == "later", "its other fields stay")
        let view = try #require(try h.view(entry.id))
        #expect(view.entry.answers["mood"] == .int(5), "the correction is the latest word")
        #expect(view.entry.notes == "later")
    }

    @Test func aLaterEditLeftWithNothingIsRemoved() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let (entry, u1) = try await refusedThenQueued(h, outbox, later: h.patch(mood: 3))
        try await outbox.fix(
            itemId: u1.id, payload: fixed(entry, h, mood: 5), rowVersion: u1.rowVersion,
            overriding: EntryOverride(answerKeys: ["mood"]))
        #expect(try h.items.map(\.id) == [u1.id])
        #expect(try h.view(entry.id)?.entry.answers["mood"] == .int(5))
    }

    @Test func withoutCorrectionsLaterEditsStay() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let (entry, u1) = try await refusedThenQueued(h, outbox, later: h.patch(mood: 3))
        try await outbox.fix(itemId: u1.id, payload: fixed(entry, h, mood: 5), rowVersion: u1.rowVersion)
        #expect(try h.items.count == 2)
        #expect(try h.view(entry.id)?.entry.answers["mood"] == .int(3), "U2 still applies after U1")
    }
}
