import Foundation
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

/// `WidgetReloader` over a real store: one reload for the first state, none for a change the
/// widgets don't show, one for a change they do.
@Suite @MainActor struct WidgetReloaderTests {
    final class Counter {
        var reloads = 0
    }

    /// Polls `condition` every 20 ms; false if it doesn't hold within `seconds`.
    func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func reloadsOnlyWhenWhatWidgetsShowChanges() async throws {
        let location = TestStores.emptyLocation()
        defer { TestStores.remove(location) }
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try await partitions.createStore(serverId: "s", baseURL: "https://quickr.example")
        try await partitions.registry.setActive("s")
        var mood = try #require(try await PlaceholderTopicRepository().topics().first?.topic)
        try await store.writer.write { [mood] db in _ = try ServerLayer.upsert(db, topic: mood) }

        let counter = Counter()
        let reloader = WidgetReloader(settle: .milliseconds(50)) { counter.reloads += 1 }
        let following = Task { await reloader.observe(store) }
        defer { following.cancel() }

        #expect(await eventually { counter.reloads == 1 }, "the first state")

        // Not shown on a widget: no reload.
        mood.description = "Edited elsewhere"
        mood.revision += 1
        try await store.writer.write { [mood] db in _ = try ServerLayer.upsert(db, topic: mood) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.reloads == 1, "a description change isn't a widget change")

        // Shown (the "Last …" line): one reload.
        mood.lastCapturedAt = Date()
        mood.entryCount += 1
        mood.revision += 1
        try await store.writer.write { [mood] db in _ = try ServerLayer.upsert(db, topic: mood) }
        #expect(await eventually { counter.reloads == 2 }, "a new last entry")
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.reloads == 2, "once")
    }
}
