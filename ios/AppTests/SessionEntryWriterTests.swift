import Foundation
import QuickrCore
import QuickrData
import QuickrUI
import Testing

@testable import QuickR

/// `SessionEntryWriter` keeps each write tied to the store it went to (server and generation).
@MainActor @Suite(.timeLimit(.minutes(2))) struct SessionEntryWriterTests {
    /// Log on server A, switch to server B while the Undo toast is still up, then Undo: refused,
    /// A's entry left alone, and B's outbox untouched.
    @Test func undoAfterAServerSwitchIsRefusedAndLeavesTheEntry() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded, categoryCenter: nil)
        await environment.start()
        let session = try #require(environment.session)
        defer { Task { await session.shutdown() } }
        let writer = environment.entryWriter

        let question = Question(key: "cups", label: "Cups", required: true, kind: .int(.init(min: 0)))
        let coffee = QuickLogTopic(
            id: PlaceholderTopicRepository.coffee, slug: "coffee", name: "Coffee", version: 1,
            quick: .number(question: question))
        let entry = try await writer.log(coffee, answers: ["cups": .int(2)])
        #expect(entry.scope == EntryScope(serverId: "test-server", storeGen: try #require(session.binding).storeGen))
        let storeA = try #require(session.store)
        #expect(try await storeA.outbox.item(id: entry.id.wireString) != nil)

        // Switch servers: B becomes the active store.
        _ = try await session.partitions.createStore(serverId: "server-b", baseURL: "https://b.quickr.example")
        try await session.partitions.registry.setActive("server-b")
        await session.rebind()
        #expect(session.binding?.serverId == "server-b")
        #expect(writer.scope != entry.scope)

        await #expect(throws: EntryWriteError.scopeChanged) { _ = try await writer.undoLog(entry.id, in: entry.scope) }
        await #expect(throws: EntryWriteError.scopeChanged) {
            _ = try await writer.undoDelete(entry.id, in: entry.scope)
        }
        #expect(await writer.sendNow(entry, wait: .seconds(30)) == .queued)  // waits in A, never read from B
        #expect(try await storeA.outbox.item(id: entry.id.wireString) != nil, "A's entry is still queued")
        #expect(try await session.store?.outbox.items().isEmpty == true, "B's outbox is untouched")

        // The toast says so, and never "Undone".
        await environment.entryToasts.undoLog(entry, topicName: "Coffee")
        #expect(environment.toasts.items.last?.toast.title == "Couldn’t undo")
        #expect(environment.toasts.items.last?.toast.message == "The server changed since then. Nothing was undone.")
    }

    /// A row still on screen from server A after a switch to B, deleted with A's scope (what the
    /// entries list passes: the store its rows came from): refused, and B's entry with the same
    /// id is left alone.
    @Test func deleteInAStaleScopeIsRefusedAndLeavesTheNewStore() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded)
        await environment.start()
        let session = try #require(environment.session)
        defer { Task { await session.shutdown() } }
        let writer = environment.entryWriter
        let topicId = PlaceholderTopicRepository.coffee
        let now = Date()
        let entry = Entry(
            id: UUID(), topicId: topicId, version: 1, revision: 1, source: "test", channel: .ios, capturedAt: now,
            createdAt: now, updatedAt: now, answers: [:])
        let storeA = try #require(session.store)
        try await storeA.writer.write { db in _ = try ServerLayer.upsert(db, entry: entry) }
        let scopeA = try #require(writer.scope)
        let bindingA = try #require(session.binding)

        // Server B has the same topic and an entry with the same id.
        let storeB = try await session.partitions.createStore(serverId: "server-b", baseURL: "https://b.quickr.example")
        let topics = try await PlaceholderTopicRepository().topics().map(\.topic)
        try await storeB.writer.write { db in
            for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
            _ = try ServerLayer.upsert(db, entry: entry)
        }
        try await session.partitions.registry.setActive("server-b")
        await session.rebind()
        #expect(writer.scope != scopeA)

        await #expect(throws: EntryWriteError.scopeChanged) {
            try await writer.delete(entryId: entry.id, topicId: topicId, in: scopeA)
        }
        // As the entries list deletes: with the binding its rows came from (A's).
        let row = ViewEntry(entry: entry, syncState: .synced)
        await #expect(throws: EntryWriteError.scopeChanged) { _ = try await writer.delete(row, from: bindingA) }
        let active = try #require(session.store)
        #expect(try await active.entries.entry(id: entry.id) != nil, "B's entry is still there")
        #expect(try await active.outbox.items().isEmpty, "no delete queued in B")

        // In its own scope the delete goes through (held for Undo).
        let scope = try await writer.delete(row, from: try #require(session.binding))
        #expect(scope == writer.scope)
        #expect(try await active.entries.entry(id: entry.id) == nil, "hidden by the held delete")
    }

    /// The edit screen's save, opened on server A and saved after a switch to B: refused, B
    /// untouched. In its own store it queues an `entry.update` with only the changed answers.
    @Test func updateInAStaleScopeIsRefusedAndQueuesInItsOwn() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded)
        await environment.start()
        let session = try #require(environment.session)
        defer { Task { await session.shutdown() } }
        let writer = environment.entryWriter
        let topicId = PlaceholderTopicRepository.coffee
        let now = Date()
        let entry = Entry(
            id: UUID(), topicId: topicId, version: 1, revision: 2, source: "test", channel: .ios, capturedAt: now,
            createdAt: now, updatedAt: now, answers: ["cups": .int(1)])
        try await #require(session.store).writer.write { db in _ = try ServerLayer.upsert(db, entry: entry) }
        let scopeA = try #require(writer.scope)
        let patch = EntryPatch(answers: ["cups": .some(.int(3))])

        let storeB = try await session.partitions.createStore(serverId: "server-b", baseURL: "https://b.quickr.example")
        try await session.partitions.registry.setActive("server-b")
        await session.rebind()
        await #expect(throws: EntryWriteError.scopeChanged) {
            try await writer.update(entryId: entry.id, topicId: topicId, patch: patch, baseRevision: 2, in: scopeA)
        }
        #expect(try await storeB.outbox.items().isEmpty, "nothing queued in B")

        // Back on A: queued, with the revision the user edited.
        try await session.partitions.registry.setActive("test-server")
        await session.rebind()
        try await writer.update(
            entryId: entry.id, topicId: topicId, patch: patch, baseRevision: 2, in: try #require(writer.scope))
        let items = try await #require(session.store).outbox.items()
        #expect(items.map(\.kind) == [.entryUpdate])
        #expect(items.first?.baseRevision == 2)
        #expect(items.first?.payloadJSON.contains("\"cups\"") == true)
    }

    /// In the same store, Undo removes the never-sent create.
    @Test func undoInTheSameStoreRemovesTheEntry() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded, categoryCenter: nil)
        await environment.start()
        let session = try #require(environment.session)
        defer { Task { await session.shutdown() } }
        let writer = environment.entryWriter
        let question = Question(key: "cups", label: "Cups", required: true, kind: .int(.init(min: 0)))
        let coffee = QuickLogTopic(
            id: PlaceholderTopicRepository.coffee, slug: "coffee", name: "Coffee", version: 1,
            quick: .number(question: question))
        let entry = try await writer.log(coffee, answers: ["cups": .int(2)])
        #expect(try await writer.undoLog(entry.id, in: entry.scope))
        #expect(try await session.store?.outbox.item(id: entry.id.wireString) == nil)
    }
}
