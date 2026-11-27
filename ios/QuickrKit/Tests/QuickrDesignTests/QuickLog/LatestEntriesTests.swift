import Foundation
import QuickrCore
import QuickrUI
import Testing

/// The tiles' latest-entry cache (T2-WIRE, content-display.md §5): one store's, like QuickLogModels.
@Suite @MainActor struct LatestEntriesTests {
    static func entry(_ topic: UUID) -> Entry {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        return Entry(
            id: UUID(), topicId: topic, version: 1, revision: 1, source: "test", channel: .ios, capturedAt: at,
            createdAt: at, updatedAt: at, answers: ["mood": .string("good")])
    }

    @Test func keepsTheActiveStoresEntriesAndDropsThemOnASwitch() {
        let writer = FakeEntryWriter()
        let cache = LatestEntries(writer: writer)
        let topic = UUID()
        let entry = Self.entry(topic)
        cache.update(topic, entry: entry, from: writer.scope)
        #expect(cache[topic] == entry)
        cache.update(topic, entry: Self.entry(topic), from: EntryScope("server-B/1"))
        #expect(cache[topic] == entry, "another store's late update is ignored")
        writer.scope = EntryScope("server-B/1")
        #expect(cache[topic] == nil, "a server switch starts over")
        cache.update(topic, entry: entry, from: writer.scope)
        cache.retain([])
        #expect(cache[topic] == nil, "a topic gone from the store is dropped")
    }
}
