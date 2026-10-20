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
        let environment = AppEnvironment.live(location: seeded)
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

    /// In the same store, Undo removes the never-sent create.
    @Test func undoInTheSameStoreRemovesTheEntry() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded)
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
