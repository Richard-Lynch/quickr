import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// Category registration (notifications.md §5.2, §5.3; N5, N6).
@Suite(.timeLimit(.minutes(5))) struct NotificationCategoriesTests {
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
        let clock = FakeClock()
        let categories: NotificationCategories

        init(
            center: FakeNotificationCenter = FakeNotificationCenter(),
            cap: Int? = NotificationCategories.registrationCap
        ) {
            self.center = center
            categories = NotificationCategories(registry: registry, center: center, wallClock: clock, cap: cap)
        }

        /// The registered ids now.
        var registered: Set<String> { center.withState { Set($0.categories.map(\.id)) } }

        /// Registers `count` rows one at a time, a minute apart (the last is the most recent).
        func registerAging(_ count: Int) async throws -> [NotificationCategories.Row] {
            var rows: [NotificationCategories.Row] = []
            for _ in 0..<count {
                let row = NotificationCategoriesTests.row()
                try await categories.register([row])
                rows.append(row)
                clock.advance(by: 60)
            }
            return rows
        }

        var table: [String] {
            get throws {
                try registry.writer.read { db in
                    try String.fetchAll(db, sql: "SELECT id FROM notification_category ORDER BY id")
                }
            }
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
        #expect(numberActions.map(\.title) == ["Log 3 glasses", "Other value…"])
        #expect(numberActions.last?.kind == .input(buttonTitle: "Log", placeholder: "Value in glasses"))
        let more = try #require(registered.first { $0.id == choice.id }?.actions.last)
        #expect(more.title == "More…" && more.kind == .open && more.kind.opensApp)
    }

    /// A row a newer build wrote with an action kind this one doesn't know keeps the rest.
    @Test func anUnreadableActionIsLeftOutNotTheCategory() async throws {
        let w = World()
        try await w.registry.writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO notification_category (id, server_id, topic_id, actions_json, created_at) VALUES ('quickr.t.x.0', 's', 't', ?, 0)",
                arguments: [
                    #"[{"kind":"log","identifier":"q1|a","title":"A"},{"kind":"future","identifier":"q1|b","title":"B"}]"#
                ])
            try db.execute(
                sql:
                    "INSERT INTO notification_category (id, server_id, topic_id, actions_json, created_at) VALUES ('quickr.t.y.0', 's', 't', 'not json', 0)"
            )
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
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: water.id, minutes: 1, answers: ["glasses": .int(3)]))
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: water.id, minutes: 2, answers: ["glasses": .int(5)]))
            for (minutes, value) in [(1, "s5"), (2, "s5"), (3, "s4"), (4, "s4"), (5, "s0"), (6, "s5")] {
                _ = try ServerLayer.upsert(
                    db,
                    entry: Make.entry(topicId: mood.id, minutes: Double(minutes), answers: ["severity": .string(value)])
                )
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
        guard case .choice(let choice) = expectedMood.descriptor else {
            Issue.record("an enum")
            return
        }
        #expect(choice.options.map(\.value) == ["s5", "s4", "s0"], "the 3 most used, most used first")
        #expect(expectedWater.actions.first?.title == "Log 5 glasses", "the latest answer")

        // Nothing changed: no new row, no registration.
        try await w.categories.refresh(from: s.store)
        #expect(w.registrations.count == 1)

        // A new last value is a new category; the old one, no longer current, stays registered while
        // the cap has room.
        try s.write { db in
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: water.id, minutes: 9, answers: ["glasses": .int(8)]))
        }
        let after = try await w.categories.refresh(from: s.store)
        #expect(w.registrations.count == 2)
        #expect(try w.table.count == 3 && !after.contains(expectedWater.id))
        #expect(w.registrations.last?.contains(expectedWater.id) == true)
    }

    /// I-NOTIF (timers.md §10.1): a timed topic's current category is its Start, whatever its
    /// questions (a text question alone isn't quick-loggable), registered as a background button.
    @Test func refreshRegistersATimedTopicsStart() async throws {
        let w = World()
        let s = try TestStore()
        var walk = Make.topic(name: "Walk")
        walk.questions = [Question(key: "note", label: "Note", kind: .string(.init()))]
        let timer = TopicTimer(steps: [.init(key: "out", label: "Out")])
        let version = TopicVersion(version: 1, questions: walk.questions, timer: timer, createdAt: Make.t0)
        try s.write { [walk] db in
            _ = try ServerLayer.upsert(db, topic: walk)
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: walk.id)
        }
        let ids = try await w.categories.refresh(from: s.store)
        let expected = NotificationCategory(
            serverId: "server-1", topicId: walk.id.wireString, version: 1, descriptor: .timed)
        #expect(ids == [expected.id])
        let registered: [NotificationCategorySpec] = w.center.withState { $0.categories }
        let actions: [NotificationActionSpec] = registered.first { $0.id == expected.id }?.actions ?? []
        #expect(actions.map(\.title) == ["Start"])
        #expect(actions.map(\.id) == ["q1|server-1|\(walk.id.wireString)|1||t|"])
        #expect(actions.allSatisfy { $0.kind == .log }, "no .foreground")
    }

    // MARK: - The cap and its priority (§5.2)

    /// Over the cap, the most recently wanted rows are registered, never more than the cap; with
    /// the system keeping at most 100, all of them stay readable.
    @Test func registrationNeverPassesTheCap() async throws {
        let center = FakeNotificationCenter()
        center.withState { $0.categoryCapacity = 100 }
        let w = World(center: center)
        let rows = try await w.registerAging(150)
        #expect(
            w.center.withState {
                $0.categoryRegistrations.allSatisfy { $0.count <= NotificationCategories.registrationCap }
            })
        #expect(w.registered == Set(rows.suffix(NotificationCategories.registrationCap).map(\.category.id)))
        // Every row was current (registered by a caller), so none was deleted.
        #expect(try w.table.count == 150)
    }

    /// Due within the window first (soonest first), then on screen, then the most recently wanted.
    @Test func theSelectionIsDueThenOnScreenThenRecent() async throws {
        let w = World(cap: 3)
        let old = try await w.registerAging(4)  // old[3] is the most recent
        // On screen: the oldest row.
        w.center.withState { $0.delivered = [NotificationSnapshot(id: "n", categoryIdentifier: old[0].category.id)] }
        var dueSoon = Self.row()
        dueSoon.dueAt = w.clock.now().addingTimeInterval(86_400)
        var dueLater = Self.row()
        dueLater.dueAt = w.clock.now().addingTimeInterval(NotificationCategories.dueWindow + 3 * 86_400)
        w.clock.advance(by: -3_600)  // wanted before the others: only its due time could lift it
        try await w.categories.register([dueLater])
        w.clock.advance(by: 7_200)
        try await w.categories.register([dueSoon])
        // dueSoon (due tier), old[0] (on screen), then the most recent of the rest: old[3]. dueLater
        // is past the window and was wanted earliest, so it isn't selected.
        #expect(w.registered == [dueSoon.category.id, old[0].category.id, old[3].category.id])

        // Room for one: the due one, not the one on screen.
        let one = NotificationCategories(registry: w.registry, center: w.center, wallClock: w.clock, cap: 1)
        try await one.register([])
        #expect(w.registered == [dueSoon.category.id])
        // Room for two: due, then on screen (not the more recent old[3]).
        let two = NotificationCategories(registry: w.registry, center: w.center, wallClock: w.clock, cap: 2)
        try await two.register([])
        #expect(w.registered == [dueSoon.category.id, old[0].category.id])
    }

    /// The NSE's category for the reminder it's showing (due now) goes in even when the cap is
    /// full of recent ones: the lowest-priority row makes room, and a row neither current nor on
    /// screen that fell out is deleted.
    @Test func aJustDeliveredCategoryEvictsTheLowestPriority() async throws {
        let w = World(cap: 3)
        let s = try TestStore()
        var topics: [Topic] = []
        for n in 0..<3 {
            var topic = Make.topic(name: "T\(n)")
            topic.questions = [Self.severity(2)]
            topics.append(topic)
        }
        try s.write { db in for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) } }
        let first = try await w.categories.refresh(from: s.store)
        #expect(w.registered == Set(first))
        // The topics change version: their old categories stop being current.
        try s.write { db in
            for var topic in topics {
                topic.currentVersion = 2
                _ = try ServerLayer.upsert(db, topic: topic)
            }
        }
        // Within a day of being wanted, a row that fell out is kept (the grace)...
        w.clock.advance(by: 60)
        let second = try await w.categories.refresh(from: s.store)
        #expect(try w.registered == Set(second) && w.table.count == 6, "the old versions are still in their grace")
        // ...and after it, deleted.
        w.clock.advance(by: NotificationCategories.deleteGrace)
        try await w.categories.refresh(from: s.store)
        #expect(try w.registered == Set(second) && w.table.count == 3, "the old versions were deleted")

        w.clock.advance(by: 60)
        var nse = Self.row()
        nse.dueAt = w.clock.now()
        try await w.categories.register([nse])
        #expect(w.registered.contains(nse.category.id) && w.registered.count == 3)
        #expect(try w.table.count == 4, "the evicted row is still current: kept for the next selection")
    }

    /// A delivered notification keeps its category through every registration while it's on
    /// screen, even outside the cap; once it's gone and the row isn't current, the row is deleted.
    @Test func aRowOnScreenIsKeptUntilItsNotificationIsGone() async throws {
        let w = World(cap: 1)
        let s = try TestStore()
        var topic = Make.topic(name: "Water")
        topic.questions = [Self.glasses]
        // Due: its current category takes the one place, so the one on screen is outside the cap.
        topic.schedule = .interval(.init(everyMinutes: 60, timezone: "UTC"))
        topic.scheduleUpdatedAt = w.clock.now().addingTimeInterval(-7_200)
        try s.write { db in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: topic.id, minutes: 1, answers: ["glasses": .int(3)]))
        }
        let three = try #require(try await w.categories.refresh(from: s.store).first)
        w.center.withState { $0.delivered = [NotificationSnapshot(id: "n", categoryIdentifier: three)] }
        try s.write { db in
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: topic.id, minutes: 2, answers: ["glasses": .int(4)]))
        }
        w.clock.advance(by: NotificationCategories.deleteGrace + 60)  // past three's grace
        let four = try #require(try await w.categories.refresh(from: s.store).first)
        #expect(w.registered == [four])
        #expect(try w.table == [three, four].sorted(), "on screen: kept although outside the cap and not current")
        w.center.withState { $0.delivered = [] }
        w.clock.advance(by: 60)
        try await w.categories.register([])
        #expect(try w.table == [four])
    }

    /// Reconciling compares the system's set with the capped selection: nothing changed, nothing
    /// registered, however often it runs, even with a table far over the system's limit.
    @Test func reconcilingTheCappedSetDoesntChurn() async throws {
        let center = FakeNotificationCenter()
        center.withState { $0.categoryCapacity = 100 }
        let w = World(center: center)
        _ = try await w.registerAging(150)
        let calls = w.registrations.count
        for _ in 0..<5 { #expect(try await w.categories.reconcile() == false) }
        #expect(w.registrations.count == calls)
        // The system loses one: reconciled once, then quiet again.
        w.center.withState { $0.categories.removeFirst() }
        #expect(try await w.categories.reconcile())
        #expect(try await w.categories.reconcile() == false)
        #expect(w.registrations.count == calls + 1)
    }

    /// The uncapped union (checkpoint D9's mode) over a 100-category system never settles: every
    /// reconcile re-registers. This is what the cap prevents.
    @Test func theUncappedUnionOverTheSystemsLimitChurns() async throws {
        let center = FakeNotificationCenter()
        center.withState { $0.categoryCapacity = 100 }
        let w = World(center: center, cap: nil)
        _ = try await w.registerAging(150)
        #expect(try await w.categories.reconcile())
        #expect(try await w.categories.reconcile())
    }

    /// The app's refresh gives a scheduled topic its due time, so it ranks first.
    @Test func refreshRanksADueTopicFirst() async throws {
        let w = World(cap: 1)
        let s = try TestStore()
        var plain = Make.topic(name: "Plain")
        plain.id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!  // first by id
        plain.questions = [Self.severity(2)]
        var due = Make.topic(name: "Due")
        due.id = UUID(uuidString: "ffffffff-0000-4000-8000-000000000001")!
        due.questions = [Self.severity(3)]
        due.schedule = .interval(.init(everyMinutes: 60, timezone: "UTC"))
        due.scheduleUpdatedAt = w.clock.now().addingTimeInterval(-7_200)
        try s.write { db in for topic in [plain, due] { _ = try ServerLayer.upsert(db, topic: topic) } }
        let ids = try await w.categories.refresh(from: s.store)
        let dueId = try #require(ids.first { $0.contains(due.id.wireString) })
        #expect(w.registered == [dueId])
    }

    /// APP-SKEW (sync-protocol.md §10): the due rank is the server's. Daily (due at 08:00 and
    /// 09:00) at device 08:58: a server 5 min ahead is at 09:03, so it's due since 09:00 (device
    /// 08:55); 5 min behind, at 08:53, still since 08:00 (device 08:05). `dueAt` is device time.
    @Test(arguments: [(5.0 * 60, 8 * 60 + 55.0), (0, 8 * 60.0), (-5.0 * 60, 8 * 60 + 5.0)] as [(TimeInterval, Double)])
    func theDueRankIsTheServers(skew: TimeInterval, dueAtMinutes: Double) async throws {
        let s = try TestStore()
        let midnight = Date(timeIntervalSince1970: 1_772_582_400)  // 2026-03-04T00:00:00Z
        var daily = Make.topic(name: "Daily")
        daily.questions = [Self.severity(2)]
        daily.schedule = .daily(
            .init(times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 9, minute: 0)], timezone: "UTC"))
        daily.createdAt = midnight.addingTimeInterval(-86_400)
        daily.scheduleUpdatedAt = daily.createdAt
        try s.write { db in
            _ = try ServerLayer.upsert(db, topic: daily)
            try db.execute(sql: "UPDATE sync_state SET skew_ms = ? WHERE id = 1", arguments: [skew * 1000])
        }
        let rows = try await NotificationCategories.rows(
            in: s.store, now: midnight.addingTimeInterval(8 * 3600 + 58 * 60))
        #expect(rows.map(\.dueAt) == [midnight.addingTimeInterval(dueAtMinutes * 60)])
    }

    // MARK: - Codex r1: races, starvation, installation, clocks, boundaries

    /// Registers `count` current rows due `dueIn` from now.
    static func dueRows(_ w: World, _ count: Int, dueIn: TimeInterval) async throws -> [NotificationCategories.Row] {
        let rows = (0..<count).map { _ in
            var row = Self.row()
            row.dueAt = w.clock.now().addingTimeInterval(dueIn)
            return row
        }
        try await w.categories.register(rows)
        return rows
    }

    /// The NSE pushes B, the app's current category for topic T. The app's next refresh, from a
    /// delivered snapshot without B and on the same server, makes B not current (T moved to a
    /// new version) while the cap is full of due topics: B, pushed, stays registered and in the
    /// table.
    @Test func aPushSurvivesARefreshThatMakesItNotCurrent() async throws {
        let w = World(cap: 2)
        let s = try TestStore()
        var topic = Make.topic(name: "T")
        topic.questions = [Self.severity(2)]
        try s.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        let b = try #require(try await w.categories.refresh(from: s.store).first)
        _ = try await Self.dueRows(w, 2, dueIn: -3_600)  // another server's, due: they fill the cap
        let pushed = NotificationCategories.Row(
            serverId: s.store.serverId, topicId: topic.id.wireString,
            category: NotificationCategory(
                serverId: s.store.serverId, topicId: topic.id.wireString, version: 1, questions: topic.questions)!)
        #expect(pushed.category.id == b)
        try await w.categories.register([pushed], as: .pushed)
        #expect(w.registered.contains(b))

        topic.currentVersion = 2
        try s.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        w.clock.advance(by: 1)
        let now = try await w.categories.refresh(from: s.store)
        #expect(!now.contains(b))
        let current = try await w.registry.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT current FROM notification_category WHERE id = ?", arguments: [b])
        }
        #expect(current == false, "the refresh cleared it")
        #expect(w.registered.contains(b))
        #expect(try w.table.contains(b))
    }

    /// Push order is the registry's counter, not the clock: after the clock goes back an hour, the
    /// incoming push is in its registration, and it outranks earlier pushes in later ones.
    @Test func pushOrderSurvivesAClockGoingBack() async throws {
        let w = World(cap: 2)
        let (x, y, z) = (Self.row(), Self.row(), Self.row())
        try await w.categories.register([x], as: .pushed)
        try await w.categories.register([y], as: .pushed)
        w.clock.advance(by: -3_600)
        try await w.categories.register([z], as: .pushed)
        #expect(w.registered == [z.category.id, y.category.id])
        try await w.categories.register([])
        #expect(w.registered == [z.category.id, y.category.id], "z is the latest push")
    }

    /// Pushes at the same instant: the incoming one is always in its own registration, whatever
    /// its id.
    @Test func theIncomingPushIsAlwaysIncluded() async throws {
        let w = World(cap: 1)
        let rows = (0..<5).map { _ in Self.row() }.sorted { $0.category.id > $1.category.id }  // last by id last
        for row in rows {
            try await w.categories.register([row], as: .pushed)
            #expect(w.registered == [row.category.id])
        }
    }

    /// The selection's must-include (the push a registration is for) wins over every tier, even
    /// for a row that would rank last: a backstop to the push counter.
    @Test func aRequiredRowIsSelectedWhateverItsRank() async throws {
        let w = World(cap: 1)
        let rows = try await Self.dueRows(w, 3, dueIn: 0)
        let lowest = Self.row()
        try await w.registry.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notification_category (id, server_id, topic_id, actions_json, created_at, used_at)
                    VALUES (?, 's', 't', '[]', 0, 0)
                    """,
                arguments: [lowest.category.id])
        }
        let now = w.clock.now()
        let selected = try await w.registry.writer.read { db in
            try NotificationCategories.select(db, now: now, delivered: [], cap: 1, required: [lowest.category.id])
                .selected.map(\.id)
        }
        #expect(selected == [lowest.category.id])
        let without = try await w.registry.writer.read { db in
            try NotificationCategories.select(db, now: now, delivered: [], cap: 1).selected.map(\.id)
        }
        #expect(Set(rows.map(\.category.id)).contains(try #require(without.first)))
    }

    /// The app asks the system for its set, then the NSE registers, then the app goes on: its
    /// answer is stale, so it registers even though its selection looks installed. For the
    /// refresh (under the lock) and for reconciliation (§5.3) alike.
    @Test(arguments: [false, true])
    func aStaleAnswerFromTheSystemIsntTrusted(reconciling: Bool) async throws {
        let center = GatedCenter(.delivered)
        let w = World(center: center.inner, cap: 2)
        let app = NotificationCategories(registry: w.registry, center: center, wallClock: w.clock, cap: 2)
        let (d, b, c) = (Self.row(), Self.row(), Self.row())
        try await w.categories.register([d])
        w.clock.advance(by: 60)
        try await w.categories.register([b])
        w.clock.advance(by: 60)
        try await w.categories.register([c])
        #expect(w.registered == [b.category.id, c.category.id])

        // The app reads the generation and the system's set {B, C}, then waits.
        let call = Task {
            if reconciling {
                #expect(try await app.reconcile())
            } else {
                try await app.refresh(from: try TestStore().store)
            }
        }
        await center.waitUntilHeld()
        // The NSE, with D on screen, pushes B: {B, D}.
        w.center.withState { $0.delivered = [NotificationSnapshot(id: "d", categoryIdentifier: d.category.id)] }
        let nse = NotificationCategories(
            registry: w.registry, center: w.center, wallClock: w.clock, cap: 2, prunes: false)
        try await nse.register([b], as: .pushed)
        #expect(w.registered == [b.category.id, d.category.id])
        // D is dismissed; the app goes on and selects {B, C}, which its stale answer shows.
        w.center.withState { $0.delivered = [] }
        center.release()
        _ = try await call.value
        #expect(w.registered == [b.category.id, c.category.id])
    }

    /// A push beats a cap full of current topics that were due yesterday, and a push from a
    /// day ago no longer does.
    @Test func aPushIsNeverStarvedByOverdueTopics() async throws {
        let w = World()
        let overdue = try await Self.dueRows(w, NotificationCategories.registrationCap, dueIn: -86_400)
        let pushed = Self.row()
        try await w.categories.register([pushed], as: .pushed)
        #expect(w.registered.contains(pushed.category.id))
        #expect(w.registered.count == NotificationCategories.registrationCap)
        w.clock.advance(by: NotificationCategories.pushWindow + 1)
        try await w.categories.register([])
        #expect(!w.registered.contains(pushed.category.id), "a day later it ranks by use, after the due ones")
        #expect(Set(overdue.map(\.category.id)).isSubset(of: w.registered))
    }

    /// A row due more than the window ago (an inactive server's topic, never refreshed since)
    /// ranks by use, not as due.
    @Test func aLongOverdueRowLosesItsDueRank() async throws {
        let w = World(cap: 1)
        var stale = Self.row()
        stale.dueAt = w.clock.now().addingTimeInterval(-NotificationCategories.dueWindow - 60)
        try await w.categories.register([stale])
        w.clock.advance(by: 60)
        let recent = Self.row()
        try await w.categories.register([recent])
        #expect(w.registered == [recent.category.id])
    }

    /// The window is inclusive at exactly 7 days either way, and one second past it isn't.
    @Test func theDueWindowsEdges() async throws {
        let window = NotificationCategories.dueWindow
        for (dueIn, ranked) in [(window, true), (-window, true), (window + 1, false), (-window - 1, false)] {
            let w = World(cap: 1)
            var due = Self.row()
            due.dueAt = w.clock.now().addingTimeInterval(dueIn)
            try await w.categories.register([due])
            w.clock.advance(by: 0)
            let other = Self.row()  // wanted at the same moment: only a due rank lifts `due`
            try await w.categories.register([other])
            let expected = ranked ? due.category.id : [due.category.id, other.category.id].min()!
            #expect(w.registered == [expected], "due in \(dueIn) s")
        }
    }

    /// Equal ranks are broken by id, so every process picks the same rows.
    @Test func equalRanksAreOrderedById() async throws {
        let w = World(cap: 2)
        let rows = (0..<5).map { _ in Self.row() }
        try await w.categories.register(rows)  // one transaction: one used_at
        #expect(w.registered == Set(rows.map(\.category.id).sorted().prefix(2)))
    }

    /// A topic with reminders off (`notify: false`) gets no due rank from the refresh.
    @Test func aTopicWithRemindersOffHasNoDueRank() async throws {
        let w = World(cap: 1)
        let s = try TestStore()
        var plain = Make.topic(name: "Plain")
        plain.id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!  // first by id
        plain.questions = [Self.severity(2)]
        var quiet = Make.topic(name: "Quiet")
        quiet.id = UUID(uuidString: "ffffffff-0000-4000-8000-000000000001")!
        quiet.questions = [Self.severity(3)]
        quiet.schedule = .interval(.init(everyMinutes: 60, timezone: "UTC", notify: false))
        quiet.scheduleUpdatedAt = w.clock.now().addingTimeInterval(-7_200)
        try s.write { db in for topic in [plain, quiet] { _ = try ServerLayer.upsert(db, topic: topic) } }
        let ids = try await w.categories.refresh(from: s.store)
        #expect(w.registered == [try #require(ids.first { $0.contains(plain.id.wireString) })])
    }

    /// A refresh that changes nothing in the table still registers when time moved a row into
    /// the selection and the system doesn't have it.
    @Test func aRefreshInstallsASelectionTimeChanged() async throws {
        let w = World(cap: 2)
        var later = Self.row()
        later.dueAt = w.clock.now().addingTimeInterval(NotificationCategories.dueWindow + 4 * 86_400)
        try await w.categories.register([later])  // wanted first: last by use
        w.clock.advance(by: 60)
        let others = (0..<2).map { _ in Self.row() }
        try await w.categories.register(others)
        #expect(!w.registered.contains(later.category.id))
        w.clock.advance(by: 5 * 86_400)  // now due within the window
        try await w.categories.refresh(from: try TestStore().store)
        #expect(w.registered.contains(later.category.id))
    }

    /// After the v3 migration (or any loss) the system may have none of the selection: the
    /// app's next refresh installs it even though the table didn't change.
    @Test func aRefreshInstallsTheSelectionTheSystemLacks() async throws {
        let w = World()
        let rows = try await w.registerAging(3)
        w.center.withState { $0.categories = [] }
        let calls = w.registrations.count
        try await w.categories.refresh(from: try TestStore().store)
        #expect(w.registrations.count == calls + 1 && w.registered == Set(rows.map(\.category.id)))
        try await w.categories.refresh(from: try TestStore().store)
        #expect(w.registrations.count == calls + 1, "installed: no second call")
    }

    /// A process whose clock reads earlier never moves a row's last use back.
    @Test func lastUseNeverMovesBack() async throws {
        let w = World()
        let row = Self.row()
        try await w.categories.register([row])
        let behind = FakeClock(w.clock.now().addingTimeInterval(-3_600))
        try await NotificationCategories(registry: w.registry, center: w.center, wallClock: behind).register([row])
        try await NotificationCategories(registry: w.registry, center: w.center, wallClock: behind)
            .register([row], as: .pushed)
        let (used, pushed) = try await w.registry.writer.read { db in
            let r = try GRDB.Row.fetchOne(db, sql: "SELECT used_at, pushed_at FROM notification_category")!
            return (r["used_at"] as Double, r["pushed_at"] as Double)
        }
        #expect(used == w.clock.now().timeIntervalSince1970)
        #expect(pushed == behind.now().timeIntervalSince1970)
    }

    /// The NSE only adds and evicts: a row the app would delete stays until the app registers.
    @Test func onlyTheAppDeletes() async throws {
        let w = World(cap: 1)
        let s = try TestStore()
        var topic = Make.topic(name: "T")
        topic.questions = [Self.severity(2)]
        try s.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        let first = try await w.categories.refresh(from: s.store)
        topic.currentVersion = 2
        try s.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        w.clock.advance(by: 60)
        try await w.categories.refresh(from: s.store)  // first is no longer current but in its grace...
        w.clock.advance(by: NotificationCategories.deleteGrace + 60)  // ...until now
        let nse = NotificationCategories(
            registry: w.registry, center: w.center, wallClock: w.clock, cap: 1, prunes: false)
        try await nse.register([Self.row()], as: .pushed)
        #expect(try w.table.contains(first[0]))
        try await w.categories.register([])
        #expect(try !w.table.contains(first[0]))
    }
}

extension TimingTests {
    /// The NSE's part of a push (§5.2, §6) over a year's registry, 650 rows: reconcile, then
    /// register its category without deleting. Well inside the 3 s target (and the 22 s budget);
    /// the app's pruning registration over the same table is measured too.
    @Test func registeringOverA650RowRegistryFitsTheNSEBudget() async throws {
        let w = NotificationCategoriesTests.World()
        let year = (0..<650).map { _ in NotificationCategoriesTests.row() }
        try await w.categories.register(year)
        try await w.registry.writer.write { db in
            try db.execute(sql: "UPDATE notification_category SET current = 0, used_at = used_at - 172800")
        }
        let nse = NotificationCategories(registry: w.registry, center: w.center, wallClock: w.clock, prunes: false)
        let clock = ContinuousClock()
        let nseTime = try await clock.measure {
            _ = try await nse.reconcile()
            try await nse.register([NotificationCategoriesTests.row()], as: .pushed)
        }
        #expect(try w.table.count == 651, "the NSE deleted nothing")
        let appTime = try await clock.measure { try await w.categories.register([]) }
        #expect(try w.table.count == NotificationCategories.registrationCap, "the app deleted the rest")
        print("650-row registry: NSE reconcile + register \(nseTime), app register with pruning \(appTime)")
        #expect(nseTime < .seconds(1))
        #expect(appTime < .seconds(2))
    }
}
