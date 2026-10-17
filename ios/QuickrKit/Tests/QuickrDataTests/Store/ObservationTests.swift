import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// `ValueObservation` helpers and the cross-process refresh.
@Suite struct ObservationTests {
    @Test func localWritesAreObserved() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        var topics = s.store.observeTopics().makeAsyncIterator()
        #expect(try await topics.next() == [])
        try await s.writer.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        #expect(try await topics.next()?.map(\.topic.id) == [topic.id])
        // An enqueue changes the view too (derived fields).
        try await s.writer.write { db in
            _ = try OutboxStorage.append(
                db, NewOutboxItem(payload: Make.createPayload(topic: topic), origin: .app), now: Make.t0)
        }
        #expect(try await topics.next()?.first?.topic.entryCount == 1)
    }

    @Test func anotherProcessWriteArrivesThroughTheRefreshSignal() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let notifier = RecordingNotifier()
        let url = dir.url.appending(path: "stores/s.g1.sqlite")
        func open() throws -> LocalStore {
            let pool = try SharedDatabase.openPool(
                at: url, migrations: StoreSchema.migrations, notifier: notifier, commitSignal: .dbChanged)
            return LocalStore(
                serverId: "s", storeGen: 1, url: url, writer: pool, leaseClock: FakeLeaseClock(), wallClock: FakeClock()
            )
        }
        let app = try open()
        let widget = try open()  // a second pool stands in for the widget process
        try await app.writer.write { db in try LocalStore.createSyncState(db, serverId: "s", baseURL: "u") }

        let refresh = RefreshSignal(notifier: notifier)
        var states = app.observeSyncState(refresh: refresh.stream()).makeAsyncIterator()
        #expect(try await states.next()??.cursor == 0)
        try await Task.sleep(for: .milliseconds(20))  // let the refresh forwarder subscribe
        try await widget.writer.write { db in try db.execute(sql: "UPDATE sync_state SET cursor = 7") }
        #expect(try await states.next()??.cursor == 7)
    }

    @Test func pokeRefetchesAndEqualValuesAreDropped() async throws {
        let s = try TestStore()
        let refresh = RefreshSignal(notifier: nil)
        let values = s.store.observeOutbox(refresh: refresh.stream())
        var iterator = values.makeAsyncIterator()
        #expect(try await iterator.next() == [])
        refresh.poke()  // same value: dropped
        let item = try s.enqueue(Make.createPayload(topic: Make.topic()))
        #expect(try await iterator.next()?.map(\.id) == [item.id])
    }
}
