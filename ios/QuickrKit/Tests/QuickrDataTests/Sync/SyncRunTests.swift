import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@_spi(Testing) @testable import QuickrData

/// R2 (timers.md §13.3): runs through the feed into the store (§7.2). Run items and deletions,
/// live and staged, under the §4.2 guards; a topic tombstone clears its runs and aliases; a stop's
/// entry keeps its timing; the store migration that adds runs re-pulls the server layer.
@Suite(.timeLimit(.minutes(5))) struct SyncRunTests {
    static let everything = UUID(uuidString: FakeFeedServer.everything)!
    static let runA = "0a000000-0000-4000-8000-000000000001"
    static let aliasA = "0a000000-0000-4000-8000-000000000002"
    static let runB = "0a000000-0000-4000-8000-0000000000b1"
    static let aliasB = "0a000000-0000-4000-8000-0000000000b2"

    /// A fixture body's object at `path`.
    static func fixture(_ name: String, _ key: String) throws -> [String: Any] {
        let body = try #require(try Fixtures.api(name).body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object[key] as? [String: Any])
    }

    /// Run A, open (running, revision 3, alias A′), on Everything: `recordRunEvent.next`'s run.
    static func openRun() throws -> [String: Any] { try fixture("recordRunEvent.next", "run") }

    /// Run A's entry once stopped, with its timing: `recordRunEvent.finish`'s entry.
    static func stoppedEntry() throws -> [String: Any] { try fixture("recordRunEvent.finish", "entry") }

    /// Run B: run A's shape under other ids, on Water.
    static func otherRun() throws -> [String: Any] {
        var run = try openRun()
        run["id"] = runB
        run["topic_id"] = FakeFeedServer.water
        run["aliases"] = [aliasB]
        return run
    }

    static func domain(_ run: [String: Any]) throws -> Run {
        let data = try JSONSerialization.data(withJSONObject: run)
        return try WireCoding.decoder().decode(RunDTO.self, from: data).toDomain()
    }

    static func domainEntry(_ entry: [String: Any]) throws -> Entry {
        let data = try JSONSerialization.data(withJSONObject: entry)
        return try WireCoding.decoder().decode(EntryDTO.self, from: data).toDomain()
    }

    static func tombstones(_ store: LocalStore, kind: String, prefix: String = "") async throws -> Set<String> {
        try await store.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM \(prefix)tombstone WHERE kind = ?", arguments: [kind]))
        }
    }

    // MARK: - Live pages

    /// A run item stores the run and its aliases; a later revision replaces it; the run reads back
    /// by its id and by an alias's.
    @Test func liveRunItemsStoreTheRunAndItsAliases() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        #expect(try await store.runs.runs().isEmpty)

        var run = try Self.openRun()
        env.server.putRun(run)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.runs.runs() == [try Self.domain(run)])
        #expect(try await store.runs.runs(topicId: Self.everything) == [try Self.domain(run)])
        #expect(try await store.runs.runs(topicId: UUID(uuidString: FakeFeedServer.water)!).isEmpty)
        #expect(try await store.runs.run(id: UUID(uuidString: Self.aliasA)!)?.id.wireString == Self.runA)
        #expect(try await store.ids("run_alias") == [Self.aliasA])

        // A later revision (a pause) replaces it.
        run = try Self.fixture("recordRunEvent.void", "run")
        env.server.putRun(run)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        let stored = try #require(try await store.runs.run(id: UUID(uuidString: Self.runA)!))
        #expect(stored == (try Self.domain(run)) && stored.revision == 4)
    }

    /// A stop: the page carries the entry (with its timing) and the run's deletion. The run and its
    /// aliases go, the run is tombstoned, and the entry reads back with the timing the API has.
    @Test func aStopDeletesTheRunAndKeepsItsEntrysTiming() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.putRun(try Self.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)

        let entry = try Self.stoppedEntry()
        env.server.closeRun(Self.runA, entry: entry)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.runs.runs().isEmpty)
        #expect(try await store.count("run_alias") == 0)
        #expect(try await Self.tombstones(store, kind: "run") == [Self.runA])
        let expected = try Self.domainEntry(entry)
        let timing = try #require(expected.timing)
        let viewed = try #require(try await store.entries.entry(id: expected.id)).entry
        #expect(viewed.timing == timing)
        #expect(viewed.capturedAt == expected.capturedAt)

        // A late page carrying the run again (from before the close) is dropped by the tombstone.
        var stale = try Self.openRun()
        stale["revision"] = 99
        let late = try Self.domain(stale)
        let outcome = try await store.writer.write { db in try ServerLayer.upsert(db, run: late) }
        #expect(outcome == .tombstoned)
        #expect(try await store.runs.runs().isEmpty)
    }

    /// The local cascade (sync-protocol.md §4.3 step 2; timers.md §7.2): an incremental page
    /// carries only the topic's deletion, and the store deletes the topic's runs and aliases and
    /// tombstones them as kind `run`. Another topic's run stays.
    @Test func aTopicTombstoneClearsItsRunsAndAliases() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.putRun(try Self.openRun())
        env.server.putRun(try Self.otherRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.ids("run") == [Self.runA, Self.runB])

        env.server.deleteTopic(FakeFeedServer.everything)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.ids("run") == [Self.runB])
        #expect(try await store.ids("run_alias") == [Self.aliasB])
        #expect(try await Self.tombstones(store, kind: "run") == [Self.runA, Self.aliasA])
        #expect(try await store.runs.run(id: UUID(uuidString: Self.aliasA)!) == nil)
    }

    /// The observation I-OUTBOX and I-RUNUI read: it emits when a page changes the runs.
    @Test func observeRunsEmitsOnEveryPageThatChangesThem() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        var values = store.observeRuns().makeAsyncIterator()
        #expect(try await values.next() == [])

        let run = try Self.openRun()
        env.server.putRun(run)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await values.next() == [try Self.domain(run)])

        env.server.closeRun(Self.runA, entry: try Self.stoppedEntry())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await values.next() == [])
    }

    // MARK: - Staged pages (§7)

    /// An epoch rebuild with an open run in the staged pages: staging stores it in `stage_run`
    /// (paged, so the run and its deletion fall on different pages), the swap moves it to the live
    /// layer, and a run that closed before the restore isn't brought back.
    @Test func anEpochRebuildStagesAnOpenRun() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator(pageLimit: 2)
        let store = try await env.connect(coordinator)
        env.server.putRun(try Self.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.ids("run") == [Self.runA])

        // On the server: A stops (its entry, then its delete), B starts; then the epoch rotates.
        let entry = try Self.stoppedEntry()
        env.server.closeRun(Self.runA, entry: entry)
        env.server.putRun(try Self.otherRun())
        env.server.rotateEpoch(to: SyncRebuildTests.e2)
        // Park the last staged page, after its predecessors were staged. Pages hold 2 log rows, so
        // A's last row before its delete (17) and its entry (18) end a page and the delete (19)
        // starts the last one.
        let snapshot = env.server.snapshot()
        let seqs = snapshot.log.map(\.seq)
        let afters = [0] + stride(from: 1, to: seqs.count, by: 2).map { seqs[$0] }
        let lastAfter = try #require(afters.last { $0 < env.server.head })
        #expect(snapshot.runsClosedAt[Self.runA] == seqs[seqs.firstIndex(of: lastAfter)! + 1])
        #expect(try await store.state().cursor != lastAfter, "the gate parks a staged page, not the live one")
        env.gate.arm { $0 == lastAfter }
        let syncing = Task { await coordinator.sync(reason: .activation) }
        try await env.gate.waitUntilParked()
        // Mid-rebuild: the live layer is untouched; staging has what the earlier pages carried.
        #expect(try await store.ids("run") == [Self.runA])
        #expect(try await store.state().rebuilding == SyncRebuildTests.e2)
        #expect(try await store.count("stage_entry", "timing_json IS NOT NULL") == 1)
        // A's last row before its delete was on an earlier page: skipped there, not upserted (§7.1).
        #expect(try await store.count("stage_run") == 0)
        env.gate.release()
        #expect(await syncing.value == .synced)

        let state = try await store.state()
        #expect(state.epoch == SyncRebuildTests.e2 && state.rebuilding == nil && state.layerGen == 2)
        #expect(try await store.ids("run") == [Self.runB])
        #expect(try await store.runs.runs() == [try Self.domain(try Self.otherRun())])
        #expect(try await store.ids("run_alias") == [Self.aliasB])
        #expect(try await store.count("stage_run") == 0)
        #expect(try await store.count("stage_run_alias") == 0)
        #expect(try await Self.tombstones(store, kind: "run") == [Self.runA])
        let viewed = try #require(try await store.entries.entry(id: try Self.domainEntry(entry).id)).entry
        #expect(viewed.timing == (try Self.domainEntry(entry)).timing)
    }

    /// The same guards in the staging tables: a topic deletion cascades to `stage_run` and
    /// `stage_run_alias`, and the live layer is untouched.
    @Test func stagedDeletionsCascadeInTheStageTables() async throws {
        let s = try TestStore()
        let run = try Self.domain(try Self.openRun())
        try s.write { (db: Database) throws in
            #expect(try ServerLayer.upsert(db, run: run, into: .stage) == .applied)
            #expect(try String.fetchAll(db, sql: "SELECT id FROM stage_run_alias") == [Self.aliasA])
            try ServerLayer.applyDeletion(
                db, kind: .topic, id: Self.everything, topicId: Self.everything, seq: 40, into: .stage)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stage_run") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stage_run_alias") == 0)
            #expect(
                Set(try String.fetchAll(db, sql: "SELECT id FROM stage_tombstone WHERE kind = 'run'"))
                    == [Self.runA, Self.aliasA])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") == 0)
            #expect(try ServerLayer.upsert(db, run: run, into: .stage) == .tombstoned)
            #expect(try ServerLayer.upsert(db, run: run) == .applied)
        }
    }

    // MARK: - Guards (§4.2)

    @Test func revisionGuardDropsAnOlderRun() throws {
        let s = try TestStore()
        let newer = try Self.domain(try Self.fixture("recordRunEvent.void", "run"))
        let older = try Self.domain(try Self.openRun())
        try s.write { (db: Database) throws in
            #expect(try ServerLayer.upsert(db, run: newer) == .applied)
            #expect(try ServerLayer.upsert(db, run: older) == .stale)
            #expect(try ServerLayer.upsert(db, run: newer) == .applied, "equal revisions overwrite")
            #expect(try Int.fetchOne(db, sql: "SELECT revision FROM run") == 4)
        }
    }

    /// A run deletion that names an alias (a topic's deletion lists them) removes that alias row.
    @Test func aRunDeletionByAliasRemovesTheAlias() throws {
        let s = try TestStore()
        let run = try Self.domain(try Self.openRun())
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, run: run)
            try ServerLayer.applyDeletion(
                db, kind: .run, id: UUID(uuidString: Self.aliasA)!, topicId: Self.everything, seq: 7)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run_alias") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run") == 1)
        }
    }
}
