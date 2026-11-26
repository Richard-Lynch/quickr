import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@_spi(Testing) @testable import QuickrData

/// R14, R24, R25 and R27 (timers2.md §12.3): closed-run markers instead of run tombstones
/// (§5.2). A `run` deletion means closed, not gone, so a later `reopen` may upsert the run again:
/// the store keeps `run_closed(id, revision)`, an upsert applies only above it (an ack only for an
/// applied `reopen`), a close applies against a row only when the row is older, and every marker
/// write is `max(existing, new)`. The topic cascade still tombstones. `SyncRunTests` (R2) keeps
/// the v1 cases.
@Suite(.timeLimit(.minutes(5))) struct RunSyncTests {
    static let runA = SyncRunTests.runA
    static let aliasA = SyncRunTests.aliasA
    /// The run of `recordRunEvent.stop`/`.reopen`/`.restop`: stopped at revision 2, reopened at 3,
    /// re-stopped at 8 (a remove in between).
    static let runC = "0a000000-0000-4000-8000-000000000003"
    static let forever = StoreSchema.closedForever

    // MARK: - Fixtures

    /// A `RunEventResult` fixture.
    static func result(_ name: String) throws -> RunEventResult {
        let body = try #require(try Fixtures.api(name).body)
        return try WireCoding.decoder().decode(RunEventResultDTO.self, from: body).toDomain()
    }

    /// Run A open (running, alias A′) at `revision`.
    static func openA(revision: Int) throws -> Run {
        var json = try SyncRunTests.openRun()
        json["revision"] = revision
        return try SyncRunTests.domain(json)
    }

    static func feedDeletion(_ id: String, revision: Int?, topicId: UUID = SyncRunTests.everything) -> Deletion {
        Deletion(
            kind: .run, seq: 40, id: UUID(uuidString: id)!, topicId: topicId, deletedAt: Make.t0, revision: revision)
    }

    static func applyDeletion(_ db: Database, _ deletion: Deletion, wall: Date = Make.t0, layer: ServerLayer.Layer = .live)
        throws
    {
        try ServerLayer.applyDeletion(
            db, kind: deletion.kind, id: deletion.id, topicId: deletion.topicId, seq: deletion.seq,
            revision: deletion.revision, wall: wall, into: layer)
    }

    static func marker(_ db: Database, _ id: String, layer: ServerLayer.Layer = .live) throws -> Int? {
        try ServerLayer.closedMarker(db, id: id, layer: layer)
    }

    static func runRevision(_ db: Database, _ id: String) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT revision FROM run WHERE id = ?", arguments: [id])
    }

    static func count(_ db: Database, _ table: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    // MARK: - R14: deletions write markers, upserts beat them

    /// A `run` deletion with `revision` writes the run's marker at it and ∞ for its aliases, deletes
    /// the run and alias rows, and tombstones nothing.
    @Test func R14_aRunDeletionWritesAMarkerAndNoTombstone() throws {
        let s = try TestStore()
        try s.write { (db: Database) throws in
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 3)) == .applied)
            try Self.applyDeletion(db, Self.feedDeletion(Self.runA, revision: 4))
            #expect(try Self.marker(db, Self.runA) == 4)
            #expect(try Self.marker(db, Self.aliasA) == Self.forever)
            #expect(try Self.count(db, "run") == 0)
            #expect(try Self.count(db, "run_alias") == 0)
            #expect(try Self.count(db, "tombstone") == 0)
        }
    }

    /// A feed upsert applies only above the marker: at or below it the run stays closed; above it
    /// (a reopen) it applies, clears the marker and re-inserts the aliases as rows. The alias
    /// itself never becomes a run.
    @Test func R14_aFeedUpsertAppliesOnlyAboveTheMarkerAndClearsIt() throws {
        let s = try TestStore()
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runA, revision: 4))
            try ServerLayer.raiseMarker(db, id: Self.aliasA, revision: Self.forever, wall: Make.t0, layer: .live)
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 3)) == .closed)
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 4)) == .closed)
            #expect(try Self.count(db, "run") == 0)

            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 5)) == .applied)
            #expect(try Self.runRevision(db, Self.runA) == 5)
            #expect(try Self.marker(db, Self.runA) == nil)
            #expect(try String.fetchAll(db, sql: "SELECT id FROM run_alias") == [Self.aliasA])
            // Once the row is back, the §4.2 row guard rules: equal overwrites, older is stale.
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 4)) == .stale)

            var asRun = try SyncRunTests.openRun()
            asRun["id"] = Self.aliasA
            asRun["aliases"] = [String]()
            asRun["revision"] = 1_000
            #expect(try ServerLayer.upsert(db, run: try SyncRunTests.domain(asRun)) == .closed)
        }
    }

    /// Markers are per layer: a staged deletion writes `stage_run_closed` and fences staged
    /// upserts only.
    @Test func R14_stagedDeletionsWriteStagedMarkers() throws {
        let s = try TestStore()
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runA, revision: 4), layer: .stage)
            #expect(try Self.marker(db, Self.runA, layer: .stage) == 4)
            #expect(try Self.marker(db, Self.runA) == nil)
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 3), into: .stage) == .closed)
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 3)) == .applied)
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 5), into: .stage) == .applied)
            #expect(try Self.marker(db, Self.runA, layer: .stage) == nil)
        }
    }

    /// The topic cascade still tombstones its runs and aliases (they are deleted, not closed): no
    /// upsert brings them back at any revision.
    @Test func R14_aTopicTombstoneStillTombstonesItsRuns() throws {
        let s = try TestStore()
        let topic = SyncRunTests.everything
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, run: try Self.openA(revision: 3))
            try ServerLayer.applyDeletion(db, kind: .topic, id: topic, topicId: topic, seq: 50)
            #expect(try ServerLayer.isTombstoned(db, kind: .run, id: Self.runA))
            #expect(try ServerLayer.isTombstoned(db, kind: .run, id: Self.aliasA))
            #expect(try ServerLayer.isClosedRun(db, id: Self.runA))
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 1_000)) == .tombstoned)
            #expect(try Self.count(db, "run") == 0)
        }
    }

    /// Markers prune 30 days after their latest write, the ∞ ones too; a younger one stays.
    @Test func R14_markersPruneAfterThirtyDays() throws {
        let s = try TestStore()
        let day: TimeInterval = 24 * 3600
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runA, revision: 4), wall: Make.t0)
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: nil), wall: Make.t0)
            try Self.applyDeletion(db, Self.feedDeletion(Self.aliasA, revision: 2), wall: Make.t0 + 10 * day)
            try ServerLayer.pruneClosedMarkers(db, wall: Make.t0 + 29 * day)
            #expect(try Self.count(db, "run_closed") == 3)
            try ServerLayer.pruneClosedMarkers(db, wall: Make.t0 + 31 * day)
            #expect(try String.fetchAll(db, sql: "SELECT id FROM run_closed") == [Self.aliasA])
            try ServerLayer.pruneClosedMarkers(db, wall: Make.t0 + 41 * day)
            #expect(try Self.count(db, "run_closed") == 0)
        }
    }

    /// A live page prunes with its own wall clock: a marker 31 days old is gone after the next pull.
    @Test func R14_aLivePagePrunesOldMarkers() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.putRun(try SyncRunTests.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        env.server.closeRun(Self.runA, entry: try SyncRunTests.stoppedEntry())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await SyncRunTests.markers(store) == [Self.runA: 4, Self.aliasA: Self.forever])
        env.wall.advance(by: 31 * 24 * 3600)
        env.server.addEntry(id: UUID())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await SyncRunTests.markers(store).isEmpty)
    }

    // MARK: - R24: acks

    /// A delayed **pre-close** ack (lower revision) for a run the feed has since closed leaves it
    /// closed; so does a higher-revision ack that is not an applied `reopen`. An applied reopen's
    /// ack reopens it and clears the marker.
    @Test func R24_onlyAnAppliedReopenAckReopensAClosedRun() throws {
        let s = try TestStore()
        let reopen = try Self.result("recordRunEvent.reopen")
        let runId = reopen.run.id
        var older = reopen
        older.run.revision = 1
        var void = reopen
        void.effect = .void(.alreadyClosed)
        var lap = reopen
        lap.run.revision = 6
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 2))
            #expect(try ServerLayer.apply(db, runEvent: older, sentTo: runId, type: .lap, wall: Make.t0) == .closed)
            #expect(try ServerLayer.apply(db, runEvent: lap, sentTo: runId, type: .lap, wall: Make.t0) == .closed)
            #expect(try ServerLayer.apply(db, runEvent: void, sentTo: runId, type: .reopen, wall: Make.t0) == .closed)
            #expect(try Self.count(db, "run") == 0)
            #expect(try Self.marker(db, Self.runC) == 2)

            #expect(try ServerLayer.apply(db, runEvent: reopen, sentTo: runId, type: .reopen, wall: Make.t0) == .applied)
            #expect(try Self.runRevision(db, Self.runC) == 3)
            #expect(try Self.marker(db, Self.runC) == nil)
        }
    }

    /// A closing ack writes the marker from `response.run.revision`, against a row (older) or
    /// with none; its aliases and the id it was sent to close at ∞.
    @Test func R24_aClosingAckWritesTheMarkerFromTheResponse() throws {
        let s = try TestStore()
        let stop = try Self.result("recordRunEvent.stop")
        let sentTo = UUID(uuidString: "0a000000-0000-4000-8000-0000000000c3")!
        try s.write { (db: Database) throws in
            #expect(try ServerLayer.apply(db, runEvent: stop, sentTo: stop.run.id, type: .stop, wall: Make.t0) == nil)
            #expect(try Self.marker(db, Self.runC) == stop.run.revision)
            #expect(try Self.count(db, "tombstone") == 0)

            let finish = try Self.result("recordRunEvent.finish")
            _ = try ServerLayer.upsert(db, run: try Self.openA(revision: 8))
            #expect(try ServerLayer.apply(db, runEvent: finish, sentTo: sentTo, type: .finish, wall: Make.t0) == nil)
            #expect(try Self.count(db, "run") == 0)
            #expect(try Self.marker(db, Self.runA) == finish.run.revision)
            #expect(try Self.marker(db, Self.aliasA) == Self.forever)
            #expect(try Self.marker(db, sentTo.wireString) == Self.forever)
            #expect(try Self.count(db, "run_alias") == 0)
        }
    }

    /// A delayed stop ack arriving after a reopen upsert with a higher revision is a no-op apart
    /// from acking the item: the row stays, no marker is written.
    @Test func R24_aDelayedStopAckAfterAReopenIsANoOpApartFromTheAck() async throws {
        let f = try await RunAckFixture(type: .stop)
        let reopen = try Self.result("recordRunEvent.reopen")
        try f.s.write { (db: Database) throws in _ = try ServerLayer.upsert(db, run: reopen.run) }
        let stop = try Self.result("recordRunEvent.stop")
        let outcome = try await f.s.store.ack(
            itemId: f.item.id, sender: f.sender, effect: .runEvent(stop, runId: stop.run.id))
        #expect(outcome == .acked(nil))
        #expect(try await f.s.store.outbox.item(id: f.item.id) == nil)
        try f.s.read { (db: Database) throws in
            #expect(try Self.runRevision(db, Self.runC) == reopen.run.revision)
            #expect(try Self.marker(db, Self.runC) == nil)
        }
    }

    /// The same through the outbox ack: the acked item's own type decides. A queued lap whose ack
    /// carries an open run never reopens the closed run; a queued reopen's applied ack does.
    @Test func R24_theAckedItemsTypeDecides() async throws {
        let lap = try await RunAckFixture(type: .lap)
        try lap.s.write { (db: Database) throws in try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 2)) }
        let reopen = try Self.result("recordRunEvent.reopen")
        #expect(
            try await lap.s.store.ack(
                itemId: lap.item.id, sender: lap.sender, effect: .runEvent(reopen, runId: reopen.run.id))
                == .acked(.closed))
        #expect(try lap.s.read { db in try Self.count(db, "run") } == 0)

        let reopening = try await RunAckFixture(type: .reopen)
        try reopening.s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 2))
        }
        #expect(
            try await reopening.s.store.ack(
                itemId: reopening.item.id, sender: reopening.sender, effect: .runEvent(reopen, runId: reopen.run.id))
                == .acked(.applied))
        #expect(try reopening.s.read { db in try Self.runRevision(db, Self.runC) } == reopen.run.revision)
    }

    // MARK: - R25: the feed

    /// A run deletion with `revision` on one page and its reopen upsert (higher revision) on the
    /// next apply in turn: closed, then open again with the marker cleared.
    @Test func R25_aDeletionThenAReopenAcrossPagesApplyInTurn() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.putRun(try SyncRunTests.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        env.server.closeRun(Self.runA, entry: try SyncRunTests.stoppedEntry())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.ids("run").isEmpty)
        #expect(try await SyncRunTests.markers(store)[Self.runA] == 4)

        var reopened = try SyncRunTests.openRun()
        reopened["revision"] = 5
        env.server.reopenRun(reopened)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.ids("run") == [Self.runA])
        #expect(try await store.runs.run(id: UUID(uuidString: Self.runA)!)?.revision == 5)
        #expect(try await SyncRunTests.markers(store)[Self.runA] == nil)
        #expect(try await store.ids("run_alias") == [Self.aliasA])
    }

    /// Stop, then reopen, in one pull over pages of one row: the page with the delete row emits
    /// the run as it is at read time (open), so both pages apply and the run ends open.
    @Test func R25_aReopenReadThroughItsDeleteRowsPageEndsOpen() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator(pageLimit: 1)
        let store = try await env.connect(coordinator)
        env.server.putRun(try SyncRunTests.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        env.server.closeRun(Self.runA)
        var reopened = try SyncRunTests.openRun()
        reopened["revision"] = 5
        env.server.reopenRun(reopened)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.runs.run(id: UUID(uuidString: Self.runA)!)?.revision == 5)
        #expect(try await SyncRunTests.markers(store).isEmpty)
    }

    /// A deletion received with no local row still fences a delayed older upsert (a page or an
    /// ack from before the close).
    @Test func R25_aDeletionWithNoLocalRowFencesAnOlderUpsert() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        env.server.putRun(try SyncRunTests.openRun())
        env.server.closeRun(Self.runA, entry: try SyncRunTests.stoppedEntry())
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        #expect(try await store.ids("run").isEmpty)
        #expect(try await SyncRunTests.markers(store)[Self.runA] == 4)
        let outcome = try await store.writer.write { db in try ServerLayer.upsert(db, run: try Self.openA(revision: 3)) }
        #expect(outcome == .closed)
        let ack = RunEventResult(eventId: UUID().wireString, effect: .applied, run: try Self.openA(revision: 3), entry: nil)
        let acked = try await store.writer.write { db in
            try ServerLayer.apply(db, runEvent: ack, sentTo: UUID(uuidString: Self.runA)!, type: .lap, wall: Make.t0)
        }
        #expect(acked == .closed)
        #expect(try await store.ids("run").isEmpty)
    }

    /// An older feed deletion applied after a newer ack is a no-op: the reopen ack's row stays.
    @Test func R25_anOlderFeedDeletionAfterANewerAckIsANoOp() throws {
        let s = try TestStore()
        let reopen = try Self.result("recordRunEvent.reopen")
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 2))
            _ = try ServerLayer.apply(db, runEvent: reopen, sentTo: reopen.run.id, type: .reopen, wall: Make.t0)
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 2))
            #expect(try Self.runRevision(db, Self.runC) == 3)
            #expect(try Self.marker(db, Self.runC) == nil)
            // A deletion at the row's own revision is not newer either.
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 3))
            #expect(try Self.runRevision(db, Self.runC) == 3)
            // The re-stop's deletion is: it closes the run again.
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 8))
            #expect(try Self.runRevision(db, Self.runC) == nil)
            #expect(try Self.marker(db, Self.runC) == 8)
        }
    }

    /// Every marker write is `max(existing, new)`, whatever its source: a lower feed deletion or
    /// closing ack never lowers it; ∞ stays ∞.
    @Test func R25_markersAreOnlyEverRaised() throws {
        let s = try TestStore()
        let stop = try Self.result("recordRunEvent.stop")
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 8))
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 5))
            #expect(try Self.marker(db, Self.runC) == 8)
            _ = try ServerLayer.apply(db, runEvent: stop, sentTo: stop.run.id, type: .stop, wall: Make.t0)
            #expect(try Self.marker(db, Self.runC) == 8)
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 9))
            #expect(try Self.marker(db, Self.runC) == 9)
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: nil))
            try Self.applyDeletion(db, Self.feedDeletion(Self.runC, revision: 10))
            #expect(try Self.marker(db, Self.runC) == Self.forever)
        }
    }

    /// A deletion with `revision: null` (a topic cascade's run, listed by a bootstrap) is
    /// permanent: no revision reopens it.
    @Test func R25_aNullRevisionDeletionIsPermanent() throws {
        let s = try TestStore()
        try s.write { (db: Database) throws in
            try Self.applyDeletion(db, Self.feedDeletion(Self.runA, revision: nil))
            #expect(try Self.marker(db, Self.runA) == Self.forever)
            #expect(try ServerLayer.upsert(db, run: try Self.openA(revision: 1_000_000)) == .closed)
        }
    }

    /// A bootstrap after a reopen lists the run as an item (no marker), and a bootstrap of a
    /// closed run carries its deletion's `revision` (the marker fences what came before it).
    @Test func R25_aBootstrapCarriesTheRunsStateAndRevision() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        env.server.putRun(try SyncRunTests.openRun())
        env.server.closeRun(Self.runA, entry: try SyncRunTests.stoppedEntry())
        var reopened = try SyncRunTests.openRun()
        reopened["revision"] = 5
        env.server.reopenRun(reopened)
        var other = try SyncRunTests.otherRun()
        env.server.putRun(other)
        env.server.closeRun(SyncRunTests.runB)
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        #expect(try await store.ids("run") == [Self.runA])
        #expect(try await store.runs.run(id: UUID(uuidString: Self.runA)!)?.revision == 5)
        #expect(try await SyncRunTests.markers(store) == [SyncRunTests.runB: 4])
        other["revision"] = 4
        let fenced = try SyncRunTests.domain(other)
        #expect(try await store.writer.write { db in try ServerLayer.upsert(db, run: fenced) } == .closed)
    }

    /// An epoch rebuild whose staged pages carry stop → reopen → re-stop of a run, one row per
    /// page: staging fences each state by revision, and the swap replaces the live markers with
    /// the staged bootstrap's (the run closed at the re-stop's revision; a live marker the new
    /// epoch doesn't list is gone).
    @Test func R25_anEpochRebuildWithStopReopenRestopInStagedPages() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator(pageLimit: 1)
        let store = try await env.connect(coordinator)
        env.server.putRun(try SyncRunTests.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        let stray = "0a000000-0000-4000-8000-0000000000d1"
        try await store.writer.write { db in
            try ServerLayer.raiseMarker(db, id: stray, revision: 7, wall: Make.t0, layer: .live)
        }

        env.server.closeRun(Self.runA, entry: try SyncRunTests.stoppedEntry())
        var reopened = try SyncRunTests.openRun()
        reopened["revision"] = 5
        env.server.reopenRun(reopened)
        env.server.closeRun(Self.runA)
        #expect(env.server.closedRevision(Self.runA) == 6)
        env.server.rotateEpoch(to: SyncRebuildTests.e2)
        #expect(await coordinator.sync(reason: .activation) == .synced)

        let state = try await store.state()
        #expect(state.epoch == SyncRebuildTests.e2 && state.rebuilding == nil)
        #expect(try await store.ids("run").isEmpty)
        // The staged pages never held the run open, so no alias rows to close: an alias is fenced
        // by the server's id rules alone (§5.2, the alias row of the table).
        #expect(try await SyncRunTests.markers(store) == [Self.runA: 6])
        #expect(try await store.count("stage_run_closed") == 0)
        #expect(try await SyncRunTests.tombstones(store, kind: "run").isEmpty)
    }

    /// The same rebuild with the run open again at the end: the swap brings it back open, with no
    /// marker, though the live layer had it closed.
    @Test func R25_anEpochRebuildEndingOpenReopensTheRun() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator(pageLimit: 1)
        let store = try await env.connect(coordinator)
        env.server.putRun(try SyncRunTests.openRun())
        env.server.closeRun(Self.runA)
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(try await SyncRunTests.markers(store)[Self.runA] == 4)

        var reopened = try SyncRunTests.openRun()
        reopened["revision"] = 5
        env.server.reopenRun(reopened)
        env.server.rotateEpoch(to: SyncRebuildTests.e2)
        #expect(await coordinator.sync(reason: .activation) == .synced)
        #expect(try await store.runs.run(id: UUID(uuidString: Self.runA)!)?.revision == 5)
        #expect(try await SyncRunTests.markers(store).isEmpty)
    }

    // MARK: - The local view

    /// A queued start whose run the feed closed makes no local run (its taps are the server's to
    /// merge): the marker hides it as the tombstone did.
    @Test func aClosedMarkerHidesAQueuedStartsRun() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let id = UUID()
        let runId = try await h.start(id: id)
        #expect(try h.localRun(runId) != nil)
        try h.write { (db: Database) throws in
            try ServerLayer.applyDeletion(
                db, kind: .run, id: id, topicId: h.topic.id, seq: 9, revision: 2, wall: Make.t0)
        }
        #expect(try h.localRun(runId) == nil)
        #expect(try h.read { db in try RunWrites.isKnown(db, runId: runId) })
    }

    /// Lap labelling from the stored v2 timer (timers2.md §3.2): this device's queued laps on a
    /// run of a version with lap types are labelled and typed by the version's timer, the same
    /// as the server's fold would.
    @Test func queuedLapsAreLabelledFromTheStoredV2Timer() async throws {
        let h = try OutboxHarness()
        let timer = TopicTimer(
            steps: [], laps: [.init(key: "run", label: "Run"), .init(key: "rest", label: "Rest")])
        try h.write { db in
            _ = try ServerLayer.insert(
                db, version: TopicVersion(version: 1, questions: [], timer: timer, createdAt: Make.t0), id: UUID(),
                topicId: h.topic.id)
        }
        let server = try h.seedServerRun(steps: [])
        let writes = h.runs()
        _ = try #require(try await writes.lap(runId: server.id.wireString))
        _ = try #require(try await writes.lap(runId: server.id.wireString))
        let local = try #require(try h.localRun(server.id.wireString))
        #expect(local.state.segments.map(\.label) == ["Run 1", "Rest 1"])
        #expect(local.state.segments.map(\.lapType) == ["run", "rest"])
        #expect(local.state.open?.label == "Run 2")
    }
}

/// A run's `run.event` item of `type`, claimed in flight with `flush` held (the ack fixture of
/// `DerivedAndAckTests`, for runs).
struct RunAckFixture {
    let s: TestStore
    let item: OutboxItem
    let sender: SenderContext

    init(type: RunEventType, runId: String = RunSyncTests.runC) async throws {
        s = try TestStore()
        let flush = try #require(try await s.store.leases.tryAcquire(.flush, owner: "app:1"))
        let topic = TopicRef(id: UUID(), slug: "walk", name: "Walk")
        let event = RunEventInDTO(id: UUID().wireString, type: type.rawValue, at: "2026-03-04T12:00:00.000000Z")
        let queued = try s.enqueue(.runEvent(RunEventPayload(topic: topic, runId: runId, event: event)))
        let token = "claim-1"
        try s.write { (db: Database) throws in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'in_flight', claim_token = ?, claim_owner = 'app:1',
                      claim_layer_gen = 1, claim_epoch = 'E1', attempts = 1 WHERE id = ?
                    """,
                arguments: [token, queued.id])
        }
        item = queued
        sender = SenderContext(flush: flush, claimToken: token, layerGen: 1, epoch: "E1")
    }
}
