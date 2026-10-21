import Foundation
import QuickrCore
import QuickrData
import QuickrUI
import Testing

@testable import QuickR

/// The entries list's delete acts in the store a row was read from (`EntriesModel.Row.binding`,
/// captured when it was rendered), never the model's or the session's latest.
@MainActor @Suite(.timeLimit(.minutes(5))) struct EntryDeleterTests {
    /// Rows rendered under server A; the app switches to B, whose store has an entry with the same
    /// id, and the list republishes under B. The old row's delete is refused and B is untouched;
    /// B's own row deletes.
    @Test func anOldRowsDeleteNeverReachesTheNewStore() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded)
        await environment.start()
        let session = try #require(environment.session)
        defer { Task { await session.shutdown() } }
        let topicId = PlaceholderTopicRepository.coffee
        let now = Date()
        let entry = Entry(
            id: UUID(), topicId: topicId, version: 1, revision: 1, source: "test", channel: .ios, capturedAt: now,
            createdAt: now, updatedAt: now, answers: [:])
        let storeA = try #require(session.store)
        try await storeA.writer.write { db in _ = try ServerLayer.upsert(db, entry: entry) }

        let model = EntriesModel(session: session, topicRef: "coffee", now: now)
        let first = Task { await model.observe() }
        defer { first.cancel() }
        try await eventually { model.rows.contains { $0.id == entry.id } }
        let oldRow = try #require(model.rows.first { $0.id == entry.id })
        let bindingA = try #require(session.binding)
        #expect(oldRow.binding == bindingA)

        // Server B, with the same topic and an entry with the same id; the list follows.
        let storeB = try await session.partitions.createStore(serverId: "server-b", baseURL: "https://b.quickr.example")
        let topics = try await PlaceholderTopicRepository().topics().map(\.topic)
        try await storeB.writer.write { db in
            for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
            _ = try ServerLayer.upsert(db, entry: entry)
        }
        try await session.partitions.registry.setActive("server-b")
        await session.rebind()
        let second = Task { await model.observe() }
        defer { second.cancel() }
        try await eventually { model.binding == session.binding && model.rows.contains { $0.id == entry.id } }
        let newRow = try #require(model.rows.first { $0.id == entry.id })
        #expect(newRow.binding != bindingA)

        // The old row's action, as its swipe or VoiceOver action would run it now.
        let deleter = EntryDeleter(environment: environment)
        await deleter.delete(oldRow)
        let active = try #require(session.store)
        #expect(try await active.entries.entry(id: entry.id) != nil, "B's entry is still there")
        #expect(try await active.outbox.items().isEmpty, "no delete queued in B")
        #expect(environment.toasts.items.last?.toast.title == "Couldn’t delete")

        await deleter.delete(newRow)
        #expect(try await active.entries.entry(id: entry.id) == nil, "B's own row deletes (held for Undo)")
        #expect(environment.toasts.items.last?.toast.title == "Entry deleted")
    }

    /// Polls (main actor) until `condition` holds, failing after 10 s.
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
