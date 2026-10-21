// PerfSeed is compiled only in debug builds (and QUICKR_PERF ones); `make ios-release-test-build`
// checks the Release build compiles without it.
#if DEBUG || QUICKR_PERF
import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The PERF seed is what the timing tests and the perf launch measure: it has to hold what it
/// says, and be the same every time.
@Suite(.timeLimit(.minutes(2))) struct PerfSeedTests {
    @Test func theStandardSeedHoldsAHeavyUsersStore() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let summary = try await PerfSeed.seed(at: StoreLocation(root: directory.url))
        #expect(summary.topics == 20 && summary.entries == 10_000 && summary.versions == 39)
        // Every outbox state is represented.
        #expect(Set(summary.outbox.keys) == Set(OutboxState.allCases), "\(summary.outbox)")

        let partitions = try StorePartitions.open(at: StoreLocation(root: directory.url), notifier: nil)
        let store = try #require(try await partitions.openActiveStoreIfExists())
        let (entries, topics, versions, items, busiest, bootstrapped) = try await store.writer.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM entry")!,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM topic")!,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM topic_version")!,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM outbox_item")!,
                try Int.fetchOne(db, sql: "SELECT max(n) FROM (SELECT count(*) AS n FROM entry GROUP BY topic_id)")!,
                try Bool.fetchOne(db, sql: "SELECT bootstrap_complete FROM sync_state")!
            )
        }
        #expect(entries == 10_000 && topics == 20 && versions == summary.versions)
        #expect(items == summary.outbox.values.reduce(0, +))
        #expect(busiest > 2_500, "skewed towards a few busy topics")
        #expect(bootstrapped)
    }

    @Test func theSeedIsTheSameEveryTime() async throws {
        let spec = PerfSeed.Spec(topics: 6, entries: 600)
        var digests: [String] = []
        for _ in 0..<2 {
            let directory = try TempDirectory()
            defer { directory.cleanup() }
            _ = try await PerfSeed.seed(at: StoreLocation(root: directory.url), spec: spec)
            let partitions = try StorePartitions.open(at: StoreLocation(root: directory.url), notifier: nil)
            let store = try #require(try await partitions.openActiveStoreIfExists())
            digests.append(
                try await store.writer.read { db in
                    // The server layer's entries and the whole outbox (ids, payloads, states, claims).
                    try Row.fetchAll(
                        db, sql: "SELECT id, topic_id, version, captured_at, answers_json, notes FROM entry ORDER BY id"
                    )
                    .map(\.description).joined(separator: "\n")
                        + (try Row.fetchAll(db, sql: "SELECT * FROM outbox_item ORDER BY seq"))
                        .map(\.description).joined(separator: "\n")
                })
        }
        #expect(digests[0] == digests[1] && !digests[0].isEmpty)
    }
}
#endif
