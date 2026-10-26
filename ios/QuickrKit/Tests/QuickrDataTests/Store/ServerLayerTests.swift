import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The §4.2 upsert guards and §4.3 tombstones (sync-protocol.md).
@Suite(.timeLimit(.minutes(5))) struct ServerLayerTests {
    @Test func rowsRoundTripThroughTheStore() async throws {
        let s = try TestStore()
        let schedule = Schedule.daily(.init(times: [TimeOfDay(hour: 9, minute: 30)], timezone: "Europe/London"))
        let topic = Make.topic(schedule: schedule)
        let entry = Make.entry(
            topicId: topic.id, answers: ["mood": .int(4), "where": .string("home"), "x": .double(1.5)], notes: "n")
        try s.write { (db: Database) throws in
            #expect(try ServerLayer.upsert(db, topic: topic) == .applied)
            #expect(try ServerLayer.upsert(db, entry: entry) == .applied)
            #expect(try ServerLayer.insert(db, version: Make.version(), id: UUID(), topicId: topic.id) == .applied)
        }
        let stored = try #require(try await s.store.topics.topic(id: topic.id)?.topic)
        var expected = topic
        expected.entryCount = 1
        expected.lastCapturedAt = entry.capturedAt
        expected.due = nil
        #expect(stored == expected)
        #expect(try await s.store.entries.entry(id: entry.id) == ViewEntry(entry: entry, syncState: .synced))
        #expect(try await s.store.versions.versions(topicId: topic.id).map(\.questions) == [Make.questions])
    }

    /// A topic read from the store has its current version's timer (timers.md §2.1): none before
    /// that version's row arrives, and none once an untimed version is current.
    @Test func aTopicReadFromTheStoreHasItsCurrentVersionsTimer() async throws {
        let s = try TestStore()
        let timer = TopicTimer(steps: [.init(key: "pour", label: "Pour"), .init(key: "drink", label: "Drink")])
        var topic = Make.topic()
        topic.timer = timer
        try s.write { (db: Database) throws in _ = try ServerLayer.upsert(db, topic: topic) }
        #expect(try await s.store.topics.topic(id: topic.id)?.topic.timer == nil)

        var v1 = Make.version(1)
        v1.timer = timer
        try s.write { (db: Database) throws in
            _ = try ServerLayer.insert(db, version: v1, id: UUID(), topicId: topic.id)
        }
        #expect(try await s.store.topics.topic(id: topic.id)?.topic.timer == timer)
        #expect(try await s.store.topics.topic(slug: topic.slug)?.topic.timer == timer)
        #expect(try await s.store.topics.topics().map(\.topic.timer) == [timer])

        topic.currentVersion = 2
        topic.revision = 2
        topic.timer = nil
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.insert(db, version: Make.version(2), id: UUID(), topicId: topic.id)
        }
        #expect(try await s.store.topics.topic(id: topic.id)?.topic.timer == nil)
    }

    @Test func revisionGuardDropsOlderAndAcceptsEqualOrNewer() throws {
        let s = try TestStore()
        let topic = Make.topic(revision: 3)
        let entry = Make.entry(topicId: topic.id, revision: 5, notes: "r5")
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.upsert(db, entry: entry)
            var older = entry
            older.revision = 4
            older.notes = "r4"
            #expect(try ServerLayer.upsert(db, entry: older) == .stale)
            var olderTopic = topic
            olderTopic.revision = 2
            olderTopic.name = "Old"
            #expect(try ServerLayer.upsert(db, topic: olderTopic) == .stale)
            var same = entry
            same.notes = "r5 again"
            #expect(try ServerLayer.upsert(db, entry: same) == .applied)
            var newer = entry
            newer.revision = 6
            newer.notes = "r6"
            #expect(try ServerLayer.upsert(db, entry: newer) == .applied)
            #expect(try String.fetchOne(db, sql: "SELECT notes FROM entry") == "r6")
            #expect(try String.fetchOne(db, sql: "SELECT name FROM topic") == "Mood")
        }
    }

    @Test func tombstoneGuardDropsEveryKind() throws {
        let s = try TestStore()
        let topic = Make.topic()
        let entry = Make.entry(topicId: topic.id)
        let versionId = UUID()
        try s.write { (db: Database) throws in
            try ServerLayer.applyDeletion(db, kind: .entry, id: entry.id, topicId: topic.id, seq: 7)
            try ServerLayer.applyDeletion(db, kind: .version, id: versionId, topicId: topic.id, seq: 8)
            #expect(try ServerLayer.upsert(db, entry: entry) == .tombstoned)
            #expect(
                try ServerLayer.insert(db, version: Make.version(), id: versionId, topicId: topic.id) == .tombstoned)
            #expect(try ServerLayer.upsert(db, topic: topic) == .applied)

            try ServerLayer.applyDeletion(db, kind: .topic, id: topic.id, topicId: topic.id, seq: 9)
            #expect(try ServerLayer.upsert(db, topic: topic) == .tombstoned)
            // A child of a deleted topic is dropped too, even with an id never seen before.
            #expect(try ServerLayer.upsert(db, entry: Make.entry(topicId: topic.id)) == .tombstoned)
            #expect(try ServerLayer.insert(db, version: Make.version(2), id: UUID(), topicId: topic.id) == .tombstoned)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry") == 0)
        }
    }

    @Test func versionsAreImmutable() throws {
        let s = try TestStore()
        let topicId = UUID()
        let id = UUID()
        try s.write { (db: Database) throws in
            #expect(try ServerLayer.insert(db, version: Make.version(1), id: id, topicId: topicId) == .applied)
            var changed = Make.version(1)
            changed.changeNote = "rewritten"
            #expect(try ServerLayer.insert(db, version: changed, id: id, topicId: topicId) == .exists)
            #expect(try String.fetchOne(db, sql: "SELECT change_note FROM topic_version") == "v1")
        }
    }

    @Test func topicTombstoneCascadesLocally() throws {
        let s = try TestStore()
        let topic = Make.topic()
        let other = Make.topic(name: "Sleep")
        let entries = [Make.entry(topicId: topic.id), Make.entry(topicId: topic.id), Make.entry(topicId: other.id)]
        let versionId = UUID()
        try s.write { (db: Database) throws in
            for t in [topic, other] { _ = try ServerLayer.upsert(db, topic: t) }
            for e in entries { _ = try ServerLayer.upsert(db, entry: e) }
            _ = try ServerLayer.insert(db, version: Make.version(), id: versionId, topicId: topic.id)
            for table in ["ui_draft", "widget_state"] {
                try db.execute(
                    sql: "INSERT INTO \(table) (key, topic_id, payload_json, updated_at) VALUES (?, ?, '{}', 0)",
                    arguments: [table, topic.id.wireString])
            }
            try db.execute(
                sql: "INSERT INTO stats_cache VALUES ('k', ?, 'E1', '{}', 0)", arguments: [topic.id.wireString])

            try ServerLayer.applyDeletion(db, kind: .topic, id: topic.id, topicId: topic.id, seq: 42)

            #expect(try String.fetchAll(db, sql: "SELECT id FROM topic") == [other.id.wireString])
            #expect(try String.fetchAll(db, sql: "SELECT id FROM entry") == [entries[2].id.wireString])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM topic_version") == 0)
            let tombstones = try Row.fetchAll(db, sql: "SELECT kind, id, seq FROM tombstone ORDER BY kind, id")
            #expect(
                Set(tombstones.map { "\($0["kind"] as String):\($0["id"] as String):\($0["seq"] as Int)" }) == [
                    "topic:\(topic.id.wireString):42", "version:\(versionId.wireString):42",
                    "entry:\(entries[0].id.wireString):42", "entry:\(entries[1].id.wireString):42",
                ])
            for table in ["ui_draft", "widget_state", "stats_cache"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
            }
            // Idempotent.
            try ServerLayer.applyDeletion(db, kind: .topic, id: topic.id, topicId: topic.id, seq: 42)
        }
    }

    @Test func stagingTablesAreSeparate() throws {
        let s = try TestStore()
        let topic = Make.topic()
        try s.write { (db: Database) throws in
            try ServerLayer.applyDeletion(db, kind: .topic, id: topic.id, topicId: topic.id, seq: 1, into: .stage)
            #expect(try ServerLayer.upsert(db, topic: topic) == .applied)
            #expect(try ServerLayer.upsert(db, topic: topic, into: .stage) == .tombstoned)
            #expect(try ServerLayer.upsert(db, entry: Make.entry(topicId: topic.id), into: .stage) == .tombstoned)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stage_topic") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") == 0)
        }
    }
}
