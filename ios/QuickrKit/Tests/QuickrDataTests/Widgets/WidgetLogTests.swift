import Foundation
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// `WidgetLogIntent`'s rules (`WidgetLogging.perform`), run against real stores: a widget's button
/// logs only into the store it was drawn from, and without a value it says so instead of prompting.
@Suite(.timeLimit(.minutes(2))) struct WidgetLogTests {
    static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "meh", label: "Meh")])))
    static let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 10, unit: "cups")))
    static let notes = Question(key: "notes", label: "Notes", kind: .string(.init()))

    final class Count: Sendable {
        private let value = Mutex(0)
        func add() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    /// Two servers ("a" and "b") whose stores hold the same topics (same ids), "b" active.
    struct World {
        let directory: TempDirectory
        let partitions: StorePartitions
        let a: LocalStore
        let b: LocalStore
        let topic: Topic
        let reloads = Count()

        init(questions: [Question]) async throws {
            directory = try TempDirectory()
            partitions = try StorePartitions.open(at: StoreLocation(root: directory.url), notifier: nil)
            var topic = Make.topic(name: "Mood")
            topic.questions = questions
            self.topic = topic
            a = try await partitions.createStore(serverId: "a", baseURL: "https://a.example")
            b = try await partitions.createStore(serverId: "b", baseURL: "https://b.example")
            for store in [a, b] {
                try await store.writer.write { [topic] db in _ = try ServerLayer.upsert(db, topic: topic) }
            }
            try await partitions.registry.setActive("b")
        }

        var context: IntentWriteContext {
            let partitions = partitions
            return IntentWriteContext(
                origin: .widget,
                openActiveStore: { try await partitions.openActiveStore(role: .extension)?.store },
                wallClock: FakeClock(Make.t0))
        }

        func perform(option: QuestionOptionEntity? = nil, number: Double? = nil, from scope: EntryScope)
            async throws -> String
        {
            let reloads = reloads
            return try await WidgetLogging.perform(
                topicId: topic.id, option: option, number: number, scope: scope, context: context,
                reload: { reloads.add() })
        }

        func option(_ value: String) -> QuestionOptionEntity {
            QuestionOptionEntity(
                topicId: topic.id, key: "mood",
                option: EnumOption(value: value, label: value.capitalized))
        }
    }

    /// A widget drawn from server "a", after a switch to "b" (same topic id): refused, nothing
    /// written anywhere, everything reloads.
    @Test func aStaleWidgetRefusesAndReloads() async throws {
        let w = try await World(questions: [Self.mood])
        defer { w.directory.cleanup() }
        await #expect(throws: WidgetLogging.Failure.stale) {
            try await w.perform(option: w.option("good"), from: w.a.scope)
        }
        #expect(try await w.a.outbox.items().isEmpty)
        #expect(try await w.b.outbox.items().isEmpty)
        #expect(w.reloads.count == 1)
    }

    @Test func aCurrentWidgetsChipLogsIntoItsStore() async throws {
        let w = try await World(questions: [Self.mood])
        defer { w.directory.cleanup() }
        let said = try await w.perform(option: w.option("meh"), from: w.b.scope)
        #expect(said.hasPrefix("Logged Mood"))
        let item = try #require(try await w.b.outbox.items().first)
        #expect(item.origin == .widget && item.topicId == w.topic.id.wireString)
        guard case .entryCreate(_, let body) = try item.payload() else {
            Issue.record("not a create")
            return
        }
        #expect(body.source == "ios.widget")
        let logged = try await w.b.entries.latestEntry(topicId: w.topic.id)
        #expect(logged?.entry.answers == ["mood": .string("meh")])
        #expect(try await w.a.outbox.items().isEmpty)
        #expect(w.reloads.count == 0)
    }

    /// SINGLE: a single topic's "Log it" (no option, no number) logs an entry with no answers.
    @Test func aSingleTopicsLogItLogsWithNoAnswers() async throws {
        let w = try await World(questions: [])
        defer { w.directory.cleanup() }
        let said = try await w.perform(from: w.b.scope)
        #expect(said == "Logged Mood.")
        let logged = try await w.b.entries.latestEntry(topicId: w.topic.id)
        #expect(logged?.entry.answers == [:])
        await #expect(throws: WidgetLogging.Failure.stale) { try await w.perform(from: w.a.scope) }
    }

    @Test func aNumberLogsAsTheQuestionsType() async throws {
        let w = try await World(questions: [Self.cups])
        defer { w.directory.cleanup() }
        _ = try await w.perform(number: 3, from: w.b.scope)
        let logged = try await w.b.entries.latestEntry(topicId: w.topic.id)
        #expect(logged?.entry.answers == ["cups": .int(3)])
    }

    /// The Control for a chip topic never logged, and for a topic that needs the form: it runs,
    /// says why, and writes nothing (it can't prompt).
    @Test func withNothingToLogItSaysSoAndWritesNothing() async throws {
        let chips = try await World(questions: [Self.mood])
        defer { chips.directory.cleanup() }
        #expect(try await chips.perform(from: chips.b.scope).contains("no answer to repeat yet"))
        #expect(try await chips.b.outbox.items().isEmpty)

        let form = try await World(questions: [Self.mood, Self.notes, Self.cups])
        defer { form.directory.cleanup() }
        #expect(try await form.perform(from: form.b.scope).contains("more than one question"))
        #expect(try await form.b.outbox.items().isEmpty)
    }

    /// A timed topic with no questions: the log Control would log it untimed in one press. It
    /// refuses and writes nothing (timers.md §11.1); the Timer Control times it.
    @Test func aTimedTopicIsNeverLoggedUntimed() async throws {
        let w = try await World(questions: [])
        defer { w.directory.cleanup() }
        let version = TopicVersion(
            version: 1, questions: [], timer: TopicTimer(steps: [TopicTimer.Step(key: "wash", label: "Wash")]),
            createdAt: Make.t0)
        let topicId = w.topic.id
        try await w.b.writer.write { db in
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topicId)
        }
        let said = try await w.perform(from: w.b.scope)
        #expect(said == "Mood is timed: use the Timer control.")
        #expect(try await w.b.outbox.items().isEmpty)
    }

    @Test func withoutAContextItIsNotSetUp() async throws {
        await #expect(throws: IntentLogging.Failure.noStore) {
            try await WidgetLogging.perform(
                topicId: UUID(), option: nil, number: 1, scope: EntryScope("x/1"), context: nil, reload: {})
        }
    }
}
