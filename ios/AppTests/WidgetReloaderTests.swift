import Foundation
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

/// `WidgetReloader` over real stores: timelines and Controls each reload once for the first state,
/// then only when what they show changed: none for a description, timelines alone for a queued log
/// (Controls don't show it), both for a new last entry, both for another store (a server switch).
@Suite @MainActor struct WidgetReloaderTests {
    final class Counter {
        var timelines = 0
        var controls = 0
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

    /// Settles past the reloader's debounce, then checks the counts didn't move.
    func stays(_ counter: Counter, timelines: Int, controls: Int) async throws -> Bool {
        try await Task.sleep(for: .milliseconds(400))
        return counter.timelines == timelines && counter.controls == controls
    }

    func store(_ partitions: StorePartitions, _ serverId: String, _ topic: Topic) async throws -> LocalStore {
        let store = try await partitions.createStore(serverId: serverId, baseURL: "https://\(serverId).example")
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        return store
    }

    @Test func timelinesAndControlsReloadOnlyForWhatTheyShow() async throws {
        let location = TestStores.emptyLocation()
        defer { TestStores.remove(location) }
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        // Its own quick-log topic (the placeholders have no questions).
        let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 20, unit: "cups")))
        var coffee = Topic(
            id: UUID(), slug: "coffee", name: "Coffee", currentVersion: 1, revision: 1, questionCount: 1,
            createdAt: Date(), updatedAt: Date(), questions: [cups])
        let store = try await store(partitions, "a", coffee)
        try await partitions.registry.setActive("a")

        let counter = Counter()
        let reloader = WidgetReloader(
            settle: .milliseconds(50), reloadTimelines: { counter.timelines += 1 },
            reloadControls: { counter.controls += 1 })
        var following = Task { await reloader.observe(store) }
        defer { following.cancel() }
        #expect(await eventually { counter.timelines == 1 && counter.controls == 1 }, "the first state")

        // Not shown anywhere: no reload.
        coffee.description = "Edited elsewhere"
        coffee.revision += 1
        try await store.writer.write { [coffee] db in _ = try ServerLayer.upsert(db, topic: coffee) }
        #expect(try await stays(counter, timelines: 1, controls: 1), "a description change")

        // A log this device queued with the same answer as before (none yet): "queued" on the widget,
        // nothing a Control shows.
        let now = Date()
        try await store.writer.write { [coffee] db in
            _ = try OutboxStorage.append(
                db,
                NewOutboxItem(
                    id: UUID(),
                    payload: .entryCreate(
                        topic: TopicRef(id: coffee.id, slug: coffee.slug, name: coffee.name),
                        body: EntryCreateDTO(id: nil, answers: [:], source: "ios", capturedAt: now, version: 1)),
                    baseRevision: nil, origin: .app, hold: nil),
                now: now)
        }
        #expect(await eventually { counter.timelines == 2 }, "the widgets show it queued")
        #expect(try await stays(counter, timelines: 2, controls: 1), "Controls don't")

        // A new last answer (the store derives it from the entries): both.
        let quick = try #require(QuickLog(questions: coffee.questions))
        let entry = Entry(
            id: UUID(), topicId: coffee.id, version: 1, revision: 1, source: "test", channel: .ios,
            capturedAt: now.addingTimeInterval(60), createdAt: now, updatedAt: now,
            answers: [quick.question.key: .int(2)])
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, entry: entry) }
        #expect(await eventually { counter.timelines == 3 && counter.controls == 2 }, "a new last answer")

        // A pull that only moves the clock skew: under a minute, nothing; by minutes, the timelines
        // (due state moves with it), not the Controls.
        func setSkew(_ ms: Double) async throws {
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE sync_state SET skew_ms = ? WHERE id = 1", arguments: [ms])
            }
        }
        try await setSkew(20_000)
        #expect(try await stays(counter, timelines: 3, controls: 2), "a few seconds of drift")
        try await setSkew(5 * 60_000)
        #expect(await eventually { counter.timelines == 4 }, "a clock 5 min off")
        #expect(try await stays(counter, timelines: 4, controls: 2), "Controls don't show due state")

        // Another server's store with the same topic id: both, though nothing else differs.
        following.cancel()
        _ = await following.value
        let other = try await self.store(partitions, "b", coffee)
        following = Task { await reloader.observe(other) }
        #expect(await eventually { counter.timelines == 5 && counter.controls == 3 }, "a server switch")
    }
}
