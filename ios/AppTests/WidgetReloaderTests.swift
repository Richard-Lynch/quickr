import Foundation
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

/// `WidgetReloader` over real stores: timelines and Controls each reload once for the first state,
/// then only when what they show changed: none for a description, timelines alone for a queued log
/// (Controls don't show it), both for a new last entry, both for another store (a server switch).
/// Each step waits for the first check that read what it wrote (`checked`), then counts: no wall-clock
/// deadline for a reload to beat, and no settle-and-hope for one that mustn't happen.
@Suite @MainActor struct WidgetReloaderTests {
    final class Counter {
        var timelines = 0
        var controls = 0
    }

    func store(_ partitions: StorePartitions, _ serverId: String, _ topic: Topic) async throws -> LocalStore {
        let store = try await partitions.createStore(serverId: serverId, baseURL: "https://\(serverId).example")
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        return store
    }

    @Test(.timeLimit(.minutes(2))) func timelinesAndControlsReloadOnlyForWhatTheyShow() async throws {
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
        let (checks, checked) = AsyncStream.makeStream(of: [WidgetTopic].self)
        var iterator = checks.makeAsyncIterator()
        /// Skips the checks that read an earlier state, up to the first that read `state`.
        func checkThatRead(_ state: (WidgetTopic) -> Bool) async {
            while let shown = await iterator.next(isolation: #isolation) {
                if let first = shown.first, state(first) { return }
            }
        }
        let reloader = WidgetReloader(
            settle: .milliseconds(50), reloadTimelines: { counter.timelines += 1 },
            reloadControls: { counter.controls += 1 }, checked: { checked.yield($0) })
        var following = Task { await reloader.observe(store) }
        defer { following.cancel() }
        await checkThatRead { $0.topic.id == coffee.id }
        #expect(counter.timelines == 1 && counter.controls == 1, "the first state")

        // Not shown anywhere: no reload.
        coffee.description = "Edited elsewhere"
        coffee.revision += 1
        try await store.writer.write { [coffee] db in _ = try ServerLayer.upsert(db, topic: coffee) }
        await checkThatRead { $0.topic.description == "Edited elsewhere" }
        #expect(counter.timelines == 1 && counter.controls == 1, "a description change")

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
        await checkThatRead { $0.queued == 1 }
        #expect(counter.timelines == 2, "the widgets show it queued")
        #expect(counter.controls == 1, "Controls don't")

        // A new last answer (the store derives it from the entries): both.
        let quick = try #require(QuickLog(questions: coffee.questions))
        let entry = Entry(
            id: UUID(), topicId: coffee.id, version: 1, revision: 1, source: "test", channel: .ios,
            capturedAt: now.addingTimeInterval(60), createdAt: now, updatedAt: now,
            answers: [quick.question!.key: .int(2)])
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, entry: entry) }
        await checkThatRead { $0.lastAnswer == .int(2) }
        #expect(counter.timelines == 3 && counter.controls == 2, "a new last answer")

        // A pull that only moves the clock skew: under a minute, nothing; by minutes, the timelines
        // (due state moves with it), not the Controls.
        func setSkew(_ ms: Double) async throws {
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE sync_state SET skew_ms = ? WHERE id = 1", arguments: [ms])
            }
        }
        try await setSkew(20_000)
        await checkThatRead { $0.skew == 20 }
        #expect(counter.timelines == 3 && counter.controls == 2, "a few seconds of drift")
        try await setSkew(5 * 60_000)
        await checkThatRead { $0.skew == 5 * 60 }
        #expect(counter.timelines == 4, "a clock 5 min off")
        #expect(counter.controls == 2, "Controls don't show due state")

        // Another server's store with the same topic id: both, though nothing else differs.
        following.cancel()
        _ = await following.value
        let other = try await self.store(partitions, "b", coffee)
        following = Task { await reloader.observe(other) }
        await checkThatRead { $0.scope == other.scope }
        #expect(counter.timelines == 5 && counter.controls == 3, "a server switch")
    }
}
