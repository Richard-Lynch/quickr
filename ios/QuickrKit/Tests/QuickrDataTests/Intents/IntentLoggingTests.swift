import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// The intents' one commit (`IntentLogging`): the active store's topic, validation, one durable
/// `entry.create` with the right id and source, and the slot rule (notifications.md §7.4).
@Suite(.timeLimit(.minutes(2))) struct IntentLoggingTests {
    static let size = Question(
        key: "size", label: "Size",
        kind: .choice(
            .init(options: [
                .init(value: "small", label: "Small"), .init(value: "large", label: "Large"),
                .init(value: "old", label: "Old", archived: true),
            ])))
    static let note = Question(key: "note", label: "Note", required: false, kind: .string(.init()))
    static let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 10, unit: "cups")))

    static func topic(_ name: String, _ questions: [Question], status: TopicStatus = .active) -> Topic {
        var topic = Make.topic(name: name, status: status)
        topic.questions = questions
        return topic
    }

    static let coffee = topic("Coffee", [size, note])
    static let water = topic("Water", [cups])
    static let old = topic("Old", [size], status: .archived)

    final class Count: Sendable {
        private let value = Mutex(0)
        func add() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    struct World {
        let s: TestStore
        let commits = Count()
        var origin: OutboxOrigin = .siri
        var opens = true

        init() throws {
            s = try TestStore()
            try s.write { db in
                for topic in [IntentLoggingTests.coffee, IntentLoggingTests.water, IntentLoggingTests.old] {
                    _ = try ServerLayer.upsert(db, topic: topic)
                }
            }
        }

        var context: IntentWriteContext {
            let (store, opens, commits) = (s.store, opens, commits)
            return IntentWriteContext(
                origin: origin, openActiveStore: { opens ? store : nil },
                afterCommit: { _ in commits.add() }, wallClock: FakeClock(Make.t0))
        }

        var items: [OutboxItem] { get throws { try s.read { db in try OutboxStorage.items(db) } } }
    }

    // MARK: - Writes

    @Test func aLogIsOneDurableCreateWithARandomIdAndTheIntentsSource() async throws {
        let w = try World()
        let logged = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("large")], in: w.context)
        #expect(logged.created && logged.answers == ["size": .string("large")])
        let item = try #require(try w.items.first)
        #expect(item.entityId == logged.entryId.wireString && item.origin == .siri)
        guard case .entryCreate(let ref, let body) = try item.payload() else {
            Issue.record("not a create")
            return
        }
        #expect(ref.id == Self.coffee.id.wireString && body.version == Self.coffee.currentVersion)
        #expect(body.source == "ios.siri" && body.capturedAt == Make.t0)
        #expect(w.commits.count == 1, "the flush is asked for after the commit")
    }

    /// Logging the same thing twice on purpose logs twice: plain logs have random ids.
    @Test func plainLogsAreNeverDeduped() async throws {
        let w = try World()
        let first = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("small")], in: w.context)
        let second = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("small")], in: w.context)
        #expect(first.entryId != second.entryId && first.created && second.created)
        #expect(try w.items.count == 2)
    }

    /// A slot-bound log uses the shared action entry id: the slot logs once.
    @Test func aSlotBoundLogUsesTheSharedIdAndLogsOnce() async throws {
        let w = try World()
        let slot = IntentLogging.Slot(serverId: "server-1", dueSince: "2026-03-04T12:00:00Z")
        let first = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("small")], slot: slot, in: w.context)
        let again = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("large")], slot: slot, in: w.context)
        let shared = ActionEntryId.make(
            serverId: "server-1", topicId: Self.coffee.id.wireString, dueSince: slot.dueSince)
        #expect(first.entryId == shared && first.created)
        #expect(again.entryId == shared && !again.created, "the first answer wins")
        #expect(try w.items.count == 1)
    }

    @Test func aWidgetLogSaysSo() async throws {
        var w = try World()
        w.origin = .widget
        _ = try await IntentLogging.log(topicId: Self.water.id, answers: ["cups": .int(2)], in: w.context)
        guard case .entryCreate(_, let body) = try #require(try w.items.first).payload() else { return }
        #expect(body.source == "ios.widget")
    }

    // MARK: - Refusals (nothing written)

    @Test func refusalsWriteNothing() async throws {
        var w = try World()
        func refused(_ topicId: UUID, _ answers: [String: AnswerValue], slot: IntentLogging.Slot? = nil)
            async -> IntentLogging.Failure?
        {
            do {
                _ = try await IntentLogging.log(topicId: topicId, answers: answers, slot: slot, in: w.context)
                return nil
            } catch let failure as IntentLogging.Failure {
                return failure
            } catch {
                return .storeUnavailable
            }
        }
        #expect(await refused(UUID(), ["size": .string("small")]) == .topicNotFound, "another server's topic")
        #expect(await refused(Self.old.id, ["size": .string("small")]) == .topicArchived)
        #expect(await refused(Self.coffee.id, [:]) == .invalid("Size: Required"))
        #expect(await refused(Self.coffee.id, ["size": .string("old")]) != nil, "an archived option")
        #expect(
            await refused(Self.coffee.id, ["size": .string("small"), "x": .int(1)])
                == .invalid("x isn't a question of this topic."))
        #expect(await refused(Self.water.id, ["cups": .int(11)]) != nil, "out of range")
        #expect(
            await refused(
                Self.coffee.id, ["size": .string("small")], slot: .init(serverId: "server-2", dueSince: "x"))
                == .otherServer)
        try w.s.write { db in
            try db.execute(
                sql: "INSERT INTO tombstone (kind, id, topic_id, seq) VALUES ('topic', ?, ?, 2)",
                arguments: [Self.water.id.wireString, Self.water.id.wireString])
        }
        #expect(await refused(Self.water.id, ["cups": .int(1)]) == .topicNotFound, "deleted")
        w.opens = false
        #expect(await refused(Self.coffee.id, ["size": .string("small")]) == .noStore)
        #expect(try w.items.isEmpty && w.commits.count == 0)
    }

    // MARK: - Undo

    /// Undo of an intent's log: a create not sent yet goes; one that may have been sent becomes a
    /// queued delete.
    @Test func undoCancelsTheCreate() async throws {
        let w = try World()
        let logged = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("small")], in: w.context)
        #expect(try await IntentLogging.undo(entryId: logged.entryId, in: w.context) == .removed)
        #expect(try w.items.isEmpty)

        let sent = try await IntentLogging.log(
            topicId: Self.coffee.id, answers: ["size": .string("large")], in: w.context)
        try w.s.write { db in
            try db.execute(
                sql: "UPDATE outbox_item SET state = 'uncertain', maybe_delivered = 1 WHERE entity_id = ?",
                arguments: [sent.entryId.wireString])
        }
        #expect(try await IntentLogging.undo(entryId: sent.entryId, in: w.context) == .deleteQueued)
    }

    // MARK: - Repeat-last

    @Test func repeatLastPlansFromTheLatestEntry() async throws {
        let w = try World()
        // No entry yet: the record screen, empty.
        #expect(
            try await IntentLogging.repeatPlan(topicId: Self.coffee.id, in: w.context).1 == .openRecord(prefill: nil))

        // The latest still validates: log it again (answers to questions gone since are dropped).
        try w.s.write { db in
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: Self.coffee.id, minutes: -2, answers: ["size": .string("small")]))
            _ = try ServerLayer.upsert(
                db,
                entry: Make.entry(
                    topicId: Self.coffee.id, minutes: -1, answers: ["size": .string("large"), "gone": .int(1)]))
        }
        #expect(
            try await IntentLogging.repeatPlan(topicId: Self.coffee.id, in: w.context).1
                == .log(["size": .string("large")]))

        // A queued log (logged now, after those) is the latest one.
        _ = try await IntentLogging.log(topicId: Self.coffee.id, answers: ["size": .string("small")], in: w.context)
        #expect(
            try await IntentLogging.repeatPlan(topicId: Self.coffee.id, in: w.context).1
                == .log(["size": .string("small")]))

        // The latest no longer validates (its option was archived): the record screen, prefilled.
        try w.s.write { db in
            _ = try ServerLayer.upsert(
                db, entry: Make.entry(topicId: Self.coffee.id, minutes: 60, answers: ["size": .string("old")]))
        }
        #expect(
            try await IntentLogging.repeatPlan(topicId: Self.coffee.id, in: w.context).1
                == .openRecord(prefill: ["size": .string("old")]))
        await #expect(throws: IntentLogging.Failure.topicArchived) {
            try await IntentLogging.repeatPlan(topicId: Self.old.id, in: w.context)
        }
    }

    // MARK: - What's due

    @Test func whatsDueListsTheDueTopicsLongestDueFirst() {
        let now = Make.t0
        func topic(_ name: String, every minutes: Int?, last: Double?, status: TopicStatus = .active) -> Topic {
            var topic = Make.topic(
                name: name, status: status,
                schedule: minutes.map { .interval(.init(everyMinutes: $0, timezone: "UTC")) })
            topic.lastCapturedAt = last.map { now.addingTimeInterval(-$0 * 60) }
            topic.createdAt = now.addingTimeInterval(-86_400 * 30)
            topic.scheduleUpdatedAt = now.addingTimeInterval(-86_400 * 30)
            return topic
        }
        let topics = [
            topic("Water", every: 120, last: 130),  // due 10 min ago
            topic("Zinc", every: 240, last: 300),  // due 60 min ago: first, though last by name
            topic("Stretch", every: 180, last: 150),  // in 30 min
            topic("Notes", every: nil, last: nil),
            topic("Old", every: 60, last: 600, status: .archived),
        ]
        #expect(IntentDue.dueNow(topics, now: now).map(\.name) == ["Zinc", "Water"])
        #expect(IntentText.dueSentence([]) == "Nothing is due.")
        #expect(IntentText.dueSentence(["Water"]) == "Water is due.")
        #expect(IntentText.dueSentence(["Meds", "Water", "Stretch"]) == "Meds, Water and Stretch are due.")
    }

    @Test func theRecordPrefillIsTheFormsText() {
        #expect(
            IntentNavigation.prefillTexts(["a": .int(2), "b": .double(7.5), "c": .string("good"), "d": .strings(["x"])])
                == ["a": "2", "b": "7.5", "c": "good"])
    }

    // MARK: - Options and text

    @Test func optionIdsRoundTripAndOnlyActiveOptionsResolve() {
        let id = QuestionOptionEntity.id(topicId: Self.coffee.id, key: "size", value: "large")
        let parts = QuestionOptionEntity.parts(of: id)
        #expect(parts?.topicId == Self.coffee.id && parts?.key == "size" && parts?.value == "large")
        #expect(QuestionOptionEntity.parts(of: "x|y") == nil && QuestionOptionEntity.parts(of: "nope|a|b") == nil)
        #expect(QuestionOptionQuery.option(id, in: Self.coffee)?.label == "Large")
        #expect(
            QuestionOptionQuery.option(
                QuestionOptionEntity.id(topicId: Self.coffee.id, key: "size", value: "old"), in: Self.coffee) == nil)
        #expect(QuestionOptionQuery.quickLogOptions(of: Self.coffee).map(\.label) == ["Small", "Large"])
        #expect(QuestionOptionQuery.quickLogOptions(of: Self.water).isEmpty, "a number quick-log")
    }

    @Test func theDialogSaysWhatWasLogged() {
        #expect(IntentText.summary(["size": .string("large")], topic: Self.coffee) == "Coffee: Large")
        #expect(IntentText.summary(["cups": .int(2)], topic: Self.water) == "Water: 2 cups")
        #expect(IntentText.answer(2, for: Self.cups) == .int(2))
        #expect(IntentText.answer(2.5, for: Self.cups) == .double(2.5), "left for validation to refuse")
        #expect(IntentText.prompt(for: Self.cups) == "How many cups for Cups?")
    }
}
