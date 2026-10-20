import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// The notification action handler (notifications.md §7; N7, N8, N10, N14, N15, N16's Swift side),
/// against file-backed stores, a fake notification center and the fake server through the real
/// `APIClient`.
@Suite(.timeLimit(.minutes(2))) struct NotificationActionHandlerTests {
    static let serverA = "0b9e0000-0000-4000-8000-0000000000aa"
    static let serverB = "0b9e0000-0000-4000-8000-0000000000bb"
    static let dueSince = "2026-03-04T11:00:00Z"  // an hour before Make.t0

    static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(.init(options: ["good", "ok", "bad"].map { EnumOption(value: $0, label: $0.capitalized) })))
    static let glasses = Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20, unit: "glasses")))
    static let sleep = Question(
        key: "hours", label: "Sleep", kind: .double(.init(min: 0, max: 24, decimals: 1, unit: "h")))

    final class World: Sendable {
        let dir: TempDirectory
        let partitions: StorePartitions
        let center = FakeNotificationCenter()
        let server = FakeServer()
        let clock = FakeLeaseClock()
        let wall = FakeClock(Make.t0)
        let reloads = Mutex(0)
        let unlocked = Mutex(true)
        let moodTopic: Topic
        let water: Topic
        let sleep: Topic
        let stores: [String: LocalStore]

        init(waterVersion: Int = 1) async throws {
            dir = try TempDirectory()
            partitions = try StorePartitions.open(
                at: StoreLocation(root: dir.url), leaseClock: clock, wallClock: wall, notifier: RecordingNotifier())
            var moodTopic = Make.topic(name: "Mood")
            moodTopic.questions = [NotificationActionHandlerTests.mood]
            var water = Make.topic(name: "Water")
            water.questions = [NotificationActionHandlerTests.glasses]
            water.currentVersion = waterVersion
            var sleep = Make.topic(name: "Sleep")
            sleep.questions = [NotificationActionHandlerTests.sleep]
            (self.moodTopic, self.water, self.sleep) = (moodTopic, water, sleep)
            let topics = [moodTopic, water, sleep]
            var stores: [String: LocalStore] = [:]
            for serverId in [NotificationActionHandlerTests.serverA, NotificationActionHandlerTests.serverB] {
                let store = try await partitions.createStore(
                    serverId: serverId, baseURL: FakeServer.base.absoluteString)
                try await store.writer.write { db in
                    try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
                    for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
                }
                stores[serverId] = store
            }
            self.stores = stores
            try await partitions.registry.setActive(NotificationActionHandlerTests.serverA)
            server.with { $0.serverId = NotificationActionHandlerTests.serverA }
            for topic in topics { server.put(topic) }
            wall.set(Make.t0.addingTimeInterval(60))
        }

        deinit { dir.cleanup() }

        var handler: NotificationActionHandler {
            NotificationActionHandler(
                partitions: partitions, center: center,
                sender: { [server] _ in
                    APIClient(baseURL: FakeServer.base, transport: server, identity: StaticServerIdentity(nil))
                },
                owner: "app:test", wallClock: wall,
                isProtectedDataAvailable: { [self] in self.unlocked.withLock { $0 } },
                reloadWidgets: { [self] in self.reloads.withLock { $0 += 1 } }, flushBudget: .seconds(5))
        }

        func items(_ serverId: String = NotificationActionHandlerTests.serverA) async throws -> [OutboxItem] {
            try await stores[serverId]!.writer.read { db in try OutboxStorage.items(db) }
        }

        /// A reminder for `topic`, as the server builds it, from `serverId`.
        func reminder(
            _ topic: Topic, serverId: String = NotificationActionHandlerTests.serverA, version: Int = 1,
            last: AnswerValue? = nil, dueSince: String = NotificationActionHandlerTests.dueSince
        ) -> (info: QuickrNotificationInfo, category: NotificationCategory) {
            let descriptor = NotificationCategory.descriptor(questions: topic.questions, counts: [:], last: last)!
            let category = NotificationCategory(
                serverId: serverId, topicId: topic.id.wireString, version: version, descriptor: descriptor)
            let info = QuickrNotificationInfo(
                kind: "due", serverId: serverId, topicId: topic.id.wireString, topicSlug: topic.slug, version: version,
                dueSince: dueSince, url: "/t/\(topic.slug)/record", quickLog: descriptor)
            return (info, category)
        }

        func tap(
            _ reminder: (info: QuickrNotificationInfo, category: NotificationCategory), _ index: Int,
            text: String? = nil, title: String? = nil
        ) async -> NotificationActionOutcome {
            await handler.handle(
                NotificationActionResponse(
                    action: .custom(reminder.category.actions[index].identifier), userText: text,
                    title: title ?? "Topic", quickr: reminder.info))
        }

        func entryId(_ topic: Topic, serverId: String = NotificationActionHandlerTests.serverA) -> UUID {
            ActionEntryId.make(
                serverId: serverId, topicId: topic.id.wireString, dueSince: NotificationActionHandlerTests.dueSince)
        }
    }

    // MARK: - §7.4 action entry id (N16, Swift side)

    struct IdVectors: Decodable {
        struct Case: Decodable {
            var name: String
            var serverId: String
            var topicId: String
            var dueSince: String
            var expected: String

            enum CodingKeys: String, CodingKey {
                case name, expected
                case serverId = "server_id"
                case topicId = "topic_id"
                case dueSince = "due_since"
            }
        }
        var cases: [Case]
    }

    @Test func actionEntryIdsMatchTheSharedVectors() throws {
        let vectors = try JSONDecoder().decode(IdVectors.self, from: Fixtures.data("action-entry-id-vectors.json"))
        #expect(vectors.cases.count >= 11)
        for c in vectors.cases {
            let id = ActionEntryId.make(serverId: c.serverId, topicId: c.topicId, dueSince: c.dueSince)
            #expect(id.wireString == c.expected, "\(c.name)")
        }
    }

    // MARK: - §7.1: a chip logs once, flushes, clears the reminder

    @Test func aChipActionLogsOnceIntoTheActiveStoreAndFlushesIt() async throws {
        let w = try await World()
        let r = w.reminder(w.moodTopic)
        let other = w.reminder(w.water)
        w.center.withState {
            $0.delivered = [
                NotificationSnapshot(id: "a", quickr: r.info), NotificationSnapshot(id: "b", quickr: other.info),
            ]
            $0.badge = 99
        }
        let outcome = await w.tap(r, 1)
        let id = w.entryId(w.moodTopic)
        #expect(outcome == .logged(entryId: id, serverId: Self.serverA, flush: .drained))
        let sent = try #require(w.server.entry(id), "flushed within the budget")
        #expect(sent.answers == ["mood": .string("ok")])
        #expect(sent.source == "ios.notification" && sent.notes.isEmpty && sent.version == 1)
        #expect(try await w.items().isEmpty, "acked")
        #expect(w.center.withState { $0.delivered.map(\.id) } == ["b"], "only this topic's reminders go")
        #expect(w.center.withState { $0.badge } == 0, "the active store's due count")
        #expect(w.reloads.withLock { $0 } == 1)
        #expect(w.center.withState { $0.added }.isEmpty, "no failure notification")
    }

    @Test func theFirstAnswerWinsWhileQueuedOnTheServerAndAfterADelete() async throws {
        let w = try await World()
        w.server.inject(nil, .respond(FakeServer.problem(503, "unavailable")))  // the first stays queued
        let r = w.reminder(w.moodTopic)
        let id = w.entryId(w.moodTopic)
        guard case .logged = await w.tap(r, 0) else { throw Failure("first tap logs") }
        #expect(try await w.items().count == 1)
        #expect(await w.tap(r, 2) == .alreadyLogged(entryId: id, .queued), "another option: nothing written")
        #expect(try await w.items().count == 1)
        #expect(w.reloads.withLock { $0 } == 1)

        // Once it is on the server, a replay (another device's push) still writes nothing.
        let store = w.stores[Self.serverA]!
        try await store.writer.write { db in
            try db.execute(sql: "DELETE FROM outbox_item")
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(id: id, topicId: w.moodTopic.id, answers: ["mood": .string("good")]))
        }
        #expect(await w.tap(r, 1) == .alreadyLogged(entryId: id, .onServer))
        try await store.writer.write { db in
            try ServerLayer.applyDeletion(db, kind: .entry, id: id, topicId: w.moodTopic.id, seq: nil)
        }
        #expect(await w.tap(r, 1) == .alreadyLogged(entryId: id, .deleted))
        #expect(try await w.items().isEmpty)
    }

    @Test func racingActionsOnOneReminderLogOnce() async throws {
        let w = try await World()
        w.server.inject(nil, once: false, .respond(FakeServer.problem(503, "unavailable")))
        let r = w.reminder(w.moodTopic)
        let outcomes = await withTaskGroup(of: NotificationActionOutcome.self) { group in
            for index in 0..<3 { group.addTask { await w.tap(r, index) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.count { if case .logged = $0 { true } else { false } } == 1)
        #expect(outcomes.count { if case .alreadyLogged(_, .queued) = $0 { true } else { false } } == 2)
        #expect(try await w.items().count == 1)
    }

    // MARK: - N14: the payload's version

    @Test func n14LogsAgainstThePayloadsVersionAfterANewerOneWasPublished() async throws {
        let w = try await World(waterVersion: 4)
        let r = w.reminder(w.water, version: 3, last: .int(5))
        #expect(r.category.actions.map(\.title) == ["✓ 5 glasses", "Other value…"])
        guard case .logged = await w.tap(r, 0) else { throw Failure("logs") }
        let sent = try #require(w.server.entry(w.entryId(w.water)))
        #expect(sent.version == 3 && sent.answers == ["glasses": .int(5)])
    }

    // MARK: - N7: an unknown server

    @Test func n7AnActionFromARemovedServerIsDroppedWithAnExplanation() async throws {
        let w = try await World()
        let gone = "0b9e0000-0000-4000-8000-0000000000cc"
        let r = w.reminder(w.moodTopic, serverId: gone)
        #expect(await w.tap(r, 0, title: "Mood") == .refused(.unknownServer))
        let posted = try #require(w.center.withState { $0.added }.first)
        #expect(posted.id == "quickr.err.\(w.moodTopic.id.wireString)")
        #expect(posted.body == "This reminder came from a server you've removed from quickR")
        #expect(posted.threadIdentifier == "topic-\(w.moodTopic.id.wireString)" && posted.categoryIdentifier == nil)
        #expect(posted.quickr?.url == "/t/mood/record", "tapping it opens the record screen")
        #expect(try await w.items().isEmpty)
        #expect(try await w.items(Self.serverB).isEmpty)
        #expect(w.server.handled.isEmpty)
    }

    // MARK: - N8: an inactive store

    @Test func n8AnInactiveStoresReminderLogsThereWithoutTheBadgeOrAFlush() async throws {
        let w = try await World()
        w.center.withState { $0.badge = 7 }
        let r = w.reminder(w.moodTopic, serverId: Self.serverB)
        let id = w.entryId(w.moodTopic, serverId: Self.serverB)
        #expect(await w.tap(r, 0) == .logged(entryId: id, serverId: Self.serverB, flush: nil))
        #expect(try await w.items(Self.serverB).map(\.id) == [id.wireString])
        #expect(try await w.items().isEmpty, "never into the active store")
        #expect(w.center.withState { $0.badge } == 7, "the badge does not change")
        #expect(w.server.handled.isEmpty, "the inactive store is not flushed")
    }

    // MARK: - N10: number text input

    @Test func n10TypedNumbersLogAndInvalidTextAsksToFix() async throws {
        let w = try await World()
        let r = w.reminder(w.sleep)
        #expect(r.category.actions.map(\.kind) == ["input"])
        guard case .logged = await w.tap(r, 0, text: " 7,5 h ") else { throw Failure("7,5 h logs") }
        #expect(w.server.entry(w.entryId(w.sleep))?.answers == ["hours": .double(7.5)])

        let w2 = try await World()
        let r2 = w2.reminder(w2.sleep)
        let outcome = await w2.tap(r2, 0, text: "abc", title: "Sleep")
        guard case .needsFix(raw: "abc", _) = outcome else { throw Failure("abc asks to fix: \(outcome)") }
        #expect(try await w2.items().isEmpty, "nothing written")
        let fix = try #require(w2.center.withState { $0.added }.first)
        #expect(fix.id == "quickr.fix.\(w2.sleep.id.wireString)")
        #expect(fix.title == "Couldn't log Sleep" && fix.body == "“abc” isn't a valid value — tap to fix")
        #expect(fix.quickr?.kind == "fix" && fix.quickr?.prefill == ["hours": "abc"])
        #expect(fix.quickr?.serverId == Self.serverA && fix.quickr?.topicId == w2.sleep.id.wireString)
        // Tapping it opens the record screen with the text.
        let tap = await w2.handler.handle(.init(action: .open, quickr: fix.quickr))
        #expect(
            tap
                == .open(
                    path: "/t/sleep/record", prefill: .init(topicId: w2.sleep.id.wireString, texts: ["hours": "abc"])))
    }

    @Test(arguments: [
        ("7,5 h", 7.5), ("7.5", 7.5), ("7,5H", 7.5), ("  24 ", 24), ("0", 0), ("7.5h", 7.5),
        // `decimals` is a display hint (§4.4; the server and `parseQuickNumber` accept more digits).
        ("7.55", 7.55),
    ])
    func numberInputAccepts(_ raw: String, _ value: Double) throws {
        let number = try Self.descriptor(Self.sleep)
        #expect(try NotificationNumberInput.parse(raw, for: number).get() == .double(value))
    }

    @Test(arguments: ["abc", "", "1,000.5", "7,5,0", "25", "-1", "1 000", "inf", "nan", "7 5", "h"])
    func numberInputRejects(_ raw: String) throws {
        let number = try Self.descriptor(Self.sleep)
        #expect(throws: AnswerMessage.self) { try NotificationNumberInput.parse(raw, for: number).get() }
    }

    @Test func intInputNeedsAWholeNumberWithinItsBounds() throws {
        let number = try Self.descriptor(Self.glasses)
        #expect(try NotificationNumberInput.parse("8 glasses", for: number).get() == .int(8))
        #expect(try NotificationNumberInput.parse("8", for: number).get() == .int(8))
        for raw in ["8.5", "8,5", "21", "-1"] {
            #expect(throws: AnswerMessage.self, "\(raw)") { try NotificationNumberInput.parse(raw, for: number).get() }
        }
    }

    static func descriptor(_ question: Question) throws -> QuickLogDescriptor.Number {
        guard case .number(let number) = NotificationCategory.descriptor(questions: [question], counts: [:], last: nil)
        else { throw Failure("a number") }
        return number
    }

    // MARK: - §7.1 step 1: validation against userInfo (N3 at the handler)

    @Test func actionsThatDontMatchTheirReminderWriteNothing() async throws {
        let w = try await World()
        let r = w.reminder(w.moodTopic)
        let topic = w.moodTopic.id.wireString
        func id(server: String = Self.serverA, version: Int = 1, key: String = "mood", value: String) -> String {
            ActionIdentifier(serverId: server, topicId: topic, version: version, key: key, kind: .option, value: value)
                .description
        }
        let tampered = [
            id(value: "terrible"),  // not an offered option
            id(server: Self.serverB, value: "ok"),  // another server than the payload's
            id(version: 2, value: "ok"),  // another version
            id(key: "other", value: "ok"),
            "q1|garbage",
            "",
        ]
        for action in tampered {
            let outcome = await w.handler.handle(.init(action: .custom(action), title: "Mood", quickr: r.info))
            #expect(outcome == .refused(.invalid), "\(action)")
        }
        // A "✓ last" whose value isn't the payload's last value.
        let water = w.reminder(w.water, last: .int(5))
        let wrong = ActionIdentifier(
            serverId: Self.serverA, topicId: w.water.id.wireString, version: 1, key: "glasses", kind: .number,
            value: "6")
        #expect(
            await w.handler.handle(.init(action: .custom(wrong.description), quickr: water.info)) == .refused(.invalid))
        // A reminder without its slot can't derive the entry id.
        var noSlot = r.info
        noSlot.dueSince = nil
        #expect(
            await w.handler.handle(.init(action: .custom(r.category.actions[0].identifier), quickr: noSlot))
                == .refused(.invalid))
        #expect(try await w.items().isEmpty)
        let posted = w.center.withState { $0.added }
        #expect(posted.allSatisfy { $0.body == "Couldn't log — open quickR to log" })
        #expect(Set(posted.map(\.id)).count == 2, "one replaceable message per topic")
    }

    // MARK: - §7.1 steps 3–4: lock and preconditions

    @Test func beforeFirstUnlockItAsksToUnlock() async throws {
        let w = try await World()
        w.unlocked.withLock { $0 = false }
        #expect(await w.tap(w.reminder(w.moodTopic), 0) == .refused(.locked))
        #expect(w.center.withState { $0.added.first?.body } == "Unlock your iPhone, then tap to log")
        #expect(try await w.items().isEmpty)
    }

    @Test func anArchivedOrDeletedTopicIsRefused() async throws {
        let w = try await World()
        let store = w.stores[Self.serverA]!
        var topic = w.moodTopic
        topic.status = .archived
        let archived = topic
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, topic: archived) }
        #expect(await w.tap(w.reminder(w.moodTopic), 0) == .refused(.topicArchived))
        #expect(w.center.withState { $0.added.last?.body } == "Mood is archived")

        try await store.writer.write { db in
            try ServerLayer.applyDeletion(db, kind: .topic, id: w.water.id, topicId: w.water.id, seq: nil)
        }
        #expect(await w.tap(w.reminder(w.water, last: .int(5)), 0, title: "Water") == .refused(.topicDeleted))
        #expect(w.center.withState { $0.added.last?.body } == "Water was deleted")
        #expect(try await w.items().isEmpty)
    }

    // MARK: - Body, dismiss and More…

    @Test func theBodyOpensTheRecordScreenAndMoreDoesTooWithoutLogging() async throws {
        let w = try await World()
        let r = w.reminder(w.moodTopic)
        #expect(
            await w.handler.handle(.init(action: .open, quickr: r.info)) == .open(path: "/t/mood/record", prefill: nil))
        #expect(await w.handler.handle(.init(action: .dismiss, quickr: r.info)) == .none)
        #expect(await w.handler.handle(.init(action: .custom("q1|x"), quickr: nil)) == .none, "not quickR's")

        var six = Self.mood
        six.kind = .choice(.init(options: (0..<6).map { EnumOption(value: "o\($0)", label: "O\($0)") }))
        var topic = w.moodTopic
        topic.questions = [six]
        let more = w.reminder(topic)
        #expect(more.category.actions.last?.kind == "open")
        #expect(await w.tap(more, 3) == .open(path: "/t/mood/record", prefill: nil))
        #expect(try await w.items().isEmpty)
    }

    // MARK: - N15 / L4: logging clears delivered and satisfied pending reminders

    @Test func n15LoggingClearsTheTopicsRemindersAndSatisfiedLocalOnes() async throws {
        let w = try await World()
        let r = w.reminder(w.moodTopic)
        func local(_ dueSince: String, topic: Topic? = nil) -> NotificationSnapshot {
            var info = w.reminder(topic ?? w.moodTopic, dueSince: dueSince).info
            info.origin = .local
            return NotificationSnapshot(id: info.slot!.localRequestIdentifier, quickr: info)
        }
        let past = local(Self.dueSince)
        let future = local("2026-03-04T23:00:00Z")
        let otherTopic = local(Self.dueSince, topic: w.water)
        w.center.withState {
            $0.delivered = [
                NotificationSnapshot(id: "remote", quickr: r.info), local("2026-03-04T10:00:00Z"),
                NotificationSnapshot(id: "water", quickr: w.reminder(w.water).info),
            ]
            $0.pending = [past, future, otherTopic]
        }
        guard case .logged = await w.tap(r, 0) else { throw Failure("logs") }
        #expect(w.center.withState { $0.delivered.map(\.id) } == ["water"])
        #expect(w.center.withState { $0.pending.map(\.id) } == [future.id, otherTopic.id], "only satisfied slots")

        // A duplicate still clears a reminder delivered again.
        w.center.withState { $0.delivered = [NotificationSnapshot(id: "again", quickr: r.info)] }
        #expect(await w.tap(r, 1) == .alreadyLogged(entryId: w.entryId(w.moodTopic), .onServer))
        #expect(w.center.withState { $0.delivered }.isEmpty)
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
