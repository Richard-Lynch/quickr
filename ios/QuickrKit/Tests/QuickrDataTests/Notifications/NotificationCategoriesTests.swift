import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// Category registration (notifications.md §5.2, §5.3; N5, N6).
@Suite(.timeLimit(.minutes(2))) struct NotificationCategoriesTests {
    static let server = "0b9e0000-0000-4000-8000-0000000000aa"

    static func severity(_ n: Int) -> Question {
        Question(
            key: "severity", label: "Severity",
            kind: .choice(.init(options: (0..<n).map { EnumOption(value: "s\($0)", label: "S\($0)") })))
    }

    static let glasses = Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20, unit: "glasses")))

    static func row(_ topic: UUID = UUID(), _ question: Question = severity(2)) -> NotificationCategories.Row {
        let category = NotificationCategory(
            serverId: server, topicId: topic.wireString, version: 1, questions: [question])!
        return .init(serverId: server, topicId: topic.wireString, category: category)
    }

    struct World {
        let registry = Registry(writer: try! TestDatabase.registry())
        let center: FakeNotificationCenter
        let categories: NotificationCategories

        init(center: FakeNotificationCenter = FakeNotificationCenter()) {
            self.center = center
            categories = NotificationCategories(registry: registry, center: center)
        }

        var table: [String] {
            get throws { try registry.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM notification_category ORDER BY id") } }
        }

        var registrations: [[String]] { center.withState { $0.categoryRegistrations.map { $0.map(\.id).sorted() } } }
    }

    @Test func registeringInsertsTheRowsAndRegistersTheWholeTable() async throws {
        let w = World()
        let (a, b) = (Self.row(), Self.row(UUID(), Self.glasses))
        try await w.categories.register([a])
        try await w.categories.register([b])
        let union = [a.category.id, b.category.id].sorted()
        #expect(try w.table == union)
        #expect(w.registrations == [[a.category.id], union], "every call registers the union, not just its rows")
        // The registered categories carry their actions.
        let registered = w.center.withState { $0.categories }
        #expect(registered.first { $0.id == b.category.id }?.actions == b.category.spec.actions)
    }

    @Test func registeringIsIdempotentAndNeverChangesACategoryInPlace() async throws {
        let w = World()
        let a = Self.row()
        try await w.categories.register([a, a])
        var changed = a
        changed.category.actions = [.init(kind: "log", identifier: "q1|x", title: "Changed")]
        try await w.categories.register([changed])  // same id: the stored row stays
        #expect(try w.table == [a.category.id])
        #expect(w.registrations.count == 2)
        let actions = w.center.withState { $0.categories.first?.actions.map(\.title) }
        #expect(actions == ["S0", "S1"])
    }

    @Test func aNumberCategoryRegistersItsTextInputAndAMoreCategoryItsForegroundAction() async throws {
        let w = World()
        let number = NotificationCategory(
            serverId: Self.server, topicId: UUID().wireString, version: 1, questions: [Self.glasses], last: .int(3))!
        let choice = NotificationCategory(
            serverId: Self.server, topicId: UUID().wireString, version: 1, questions: [Self.severity(6)])!
        try await w.categories.register([
            .init(serverId: Self.server, topicId: "t1", category: number),
            .init(serverId: Self.server, topicId: "t2", category: choice),
        ])
        let registered = w.center.withState { $0.categories }
        let numberActions = try #require(registered.first { $0.id == number.id }?.actions)
        #expect(numberActions.map(\.title) == ["✓ 3 glasses", "Other value…"])
        #expect(numberActions.last?.kind == .input(buttonTitle: "Log", placeholder: "Value in glasses"))
        let more = try #require(registered.first { $0.id == choice.id }?.actions.last)
        #expect(more.title == "More…" && more.kind == .open && more.kind.opensApp)
    }

    /// A row a newer build wrote with an action kind this one doesn't know keeps the rest.
    @Test func anUnreadableActionIsLeftOutNotTheCategory() async throws {
        let w = World()
        try await w.registry.writer.write { db in
            try db.execute(
                sql: "INSERT INTO notification_category VALUES ('quickr.t.x.0', 's', 't', ?, 0)",
                arguments: [#"[{"kind":"log","identifier":"q1|a","title":"A"},{"kind":"future","identifier":"q1|b","title":"B"}]"#])
            try db.execute(sql: "INSERT INTO notification_category VALUES ('quickr.t.y.0', 's', 't', 'not json', 0)")
        }
        try await w.categories.register([])
        let registered = w.center.withState { $0.categories }
        #expect(registered.map(\.id) == ["quickr.t.x.0", "quickr.t.y.0"])
        #expect(registered[0].actions.map(\.title) == ["A"] && registered[1].actions.isEmpty)
    }

    // MARK: - Reconciliation (N5)

    @Test func reconcilingReRegistersTheUnionWhenTheSystemLostACategory() async throws {
        let w = World()
        let (a, b) = (Self.row(), Self.row())
        try await w.categories.register([a, b])
        w.center.withState { $0.categories.removeAll { $0.id == b.category.id } }  // lost (a reboot, a race)
        #expect(try await w.categories.reconcile())
        #expect(w.registrations.count == 2 && w.registrations.last == [a.category.id, b.category.id].sorted())
    }

    @Test func reconcilingWithNothingMissingMakesNoCall() async throws {
        let w = World()
        try await w.categories.register([Self.row()])
        w.center.withState { $0.categories.append(NotificationCategorySpec(id: "someone.else", actions: [])) }
        #expect(try await !w.categories.reconcile())
        #expect(w.registrations.count == 1)
    }

    // MARK: - No transaction across the center's queries (N6)

    /// The registry's write connection is traced: BEGIN and COMMIT/ROLLBACK statements open and
    /// close `open`. The fake center checks it on every asynchronous query.
    @Test func noTransactionIsOpenWhileTheCenterIsAsked() async throws {
        let open = Mutex(false)
        let sawTransaction = Mutex(false)
        let queriedInside = Mutex<[String]>([])
        let center = FakeNotificationCenter { name in
            if open.withLock({ $0 }) { queriedInside.withLock { $0.append(name) } }
        }
        let w = World(center: center)
        try await w.registry.writer.writeWithoutTransaction { db in
            db.trace { event in
                let sql = "\(event)".uppercased()
                if sql.hasPrefix("BEGIN") {
                    open.withLock { $0 = true }
                    sawTransaction.withLock { $0 = true }
                } else if sql.hasPrefix("COMMIT") || sql.hasPrefix("ROLLBACK") || sql.hasPrefix("END") {
                    open.withLock { $0 = false }
                }
            }
        }
        try await w.categories.register([Self.row(), Self.row()])
        w.center.withState { $0.categories.removeAll() }
        #expect(try await w.categories.reconcile())  // asks, then registers in a transaction
        _ = await center.deliveredNotifications()
        #expect(sawTransaction.withLock { $0 }, "the trace sees the registration's transaction")
        #expect(queriedInside.withLock { $0 }.isEmpty)
        #expect(!open.withLock { $0 })
    }

    // MARK: - Refresh from a store (after a sync: every quick-loggable topic, ahead of any push)

    @Test func refreshRegistersEveryQuickLoggableActiveTopicOfTheStore() async throws {
        let w = World()
        let s = try TestStore()
        var water = Make.topic(name: "Water")
        water.questions = [Self.glasses]
        var mood = Make.topic(name: "Mood")
        mood.questions = [Self.severity(6)]
        var notes = Make.topic(name: "Notes")
        notes.questions = [Question(key: "note", label: "Note", kind: .string(.init()))]
        var old = Make.topic(name: "Old", status: .archived)
        old.questions = [Self.severity(2)]
        try s.write { db in
            for topic in [water, mood, notes, old] { _ = try ServerLayer.upsert(db, topic: topic) }
            _ = try ServerLayer.upsert(db, entry: Make.entry(topicId: water.id, minutes: 1, answers: ["glasses": .int(3)]))
            _ = try ServerLayer.upsert(db, entry: Make.entry(topicId: water.id, minutes: 2, answers: ["glasses": .int(5)]))
            for (minutes, value) in [(1, "s5"), (2, "s5"), (3, "s4"), (4, "s4"), (5, "s0"), (6, "s5")] {
                _ = try ServerLayer.upsert(
                    db, entry: Make.entry(topicId: mood.id, minutes: Double(minutes), answers: ["severity": .string(value)]))
            }
        }
        let ids = try await w.categories.refresh(from: s.store)
        let expectedWater = NotificationCategory(
            serverId: "server-1", topicId: water.id.wireString, version: 1, questions: [Self.glasses], last: .int(5))!
        let expectedMood = NotificationCategory(
            serverId: "server-1", topicId: mood.id.wireString, version: 1, questions: [Self.severity(6)],
            counts: ["s5": 3, "s4": 2, "s0": 1])!
        #expect(Set(ids) == [expectedWater.id, expectedMood.id], "no category for a text topic or an archived one")
        #expect(try w.table == [expectedWater.id, expectedMood.id].sorted())
        guard case .choice(let choice) = expectedMood.descriptor else { Issue.record("an enum"); return }
        #expect(choice.options.map(\.value) == ["s5", "s4", "s0"], "the 3 most used, most used first")
        #expect(expectedWater.actions.first?.title == "✓ 5 glasses", "the latest answer")

        // Nothing changed: no new row, no registration.
        try await w.categories.refresh(from: s.store)
        #expect(w.registrations.count == 1)

        // A new last value is a new category; the old one stays registered (append-only).
        try s.write { db in
            _ = try ServerLayer.upsert(db, entry: Make.entry(topicId: water.id, minutes: 9, answers: ["glasses": .int(8)]))
        }
        let after = try await w.categories.refresh(from: s.store)
        #expect(w.registrations.count == 2)
        #expect(try w.table.count == 3 && !after.contains(expectedWater.id))
        #expect(w.registrations.last?.contains(expectedWater.id) == true)
    }
}
