import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// The widgets' reads (`WidgetReader`) over a store, and their reload policy (`WidgetTimeline`,
/// `WidgetFingerprint`).
@Suite struct WidgetDataTests {
    static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "meh", label: "Meh")])))

    static func topic(
        _ name: String, questions: [Question] = [mood], schedule: Schedule? = nil, status: TopicStatus = .active,
        lastCapturedAt: Date? = Make.t0
    ) -> Topic {
        var topic = Make.topic(name: name, status: status, schedule: schedule)
        topic.questions = questions
        topic.lastCapturedAt = lastCapturedAt
        return topic
    }

    static func every(_ minutes: Int) -> Schedule { .interval(.init(everyMinutes: minutes, timezone: "UTC")) }

    func seeded(_ topics: [Topic], entries: [Entry] = []) throws -> TestStore {
        let store = try TestStore()
        try store.write { db in
            for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
            for entry in entries { _ = try ServerLayer.upsert(db, entry: entry) }
        }
        return store
    }

    // MARK: - WidgetReader

    @Test func aTopicCarriesItsQuickLogAndLastAnswer() async throws {
        let mood = Self.topic("Mood")
        let store = try seeded([mood], entries: [Make.entry(topicId: mood.id, answers: ["mood": .string("meh")])])
        let shown = try #require(try await WidgetReader(store: store.store).topic(id: mood.id))
        guard case .chips(_, let options) = shown.quick else {
            Issue.record("a single choice logs with chips: \(String(describing: shown.quick))")
            return
        }
        #expect(options.map(\.value) == ["good", "meh"])
        #expect(shown.lastAnswer == .string("meh"))
        #expect(shown.queued == 0 && shown.failed == 0)
        #expect(shown.recordURL.absoluteString == "quickr://t/mood/record")
    }

    @Test func aTopicThatNeedsTheFormHasNoQuickLog() async throws {
        let notes = Question(key: "notes", label: "Notes", kind: .string(.init()))
        let journal = Self.topic("Journal", questions: [notes])
        let store = try seeded([journal])
        let shown = try #require(try await WidgetReader(store: store.store).topic(id: journal.id))
        #expect(shown.quick == nil && shown.lastAnswer == nil)
    }

    /// "Queued": this device's creates not on the server yet (held for Undo, pending, sending or
    /// uncertain); "failed": refused ones. Edits and other topics' items don't count. The latest
    /// answer includes a queued create.
    @Test func queuedAndFailedCountThisTopicsUnsentLogs() async throws {
        let mood = Self.topic("Mood")
        let other = Self.topic("Other")
        let store = try seeded(
            [mood, other], entries: [Make.entry(topicId: mood.id, answers: ["mood": .string("meh")])])
        let good: [String: AnswerValue] = ["mood": .string("good")]
        try store.enqueue(Make.createPayload(topic: mood, minutes: 1, answers: good))
        let inFlight = try store.enqueue(Make.createPayload(topic: mood, minutes: 2, answers: good))
        try store.setState(inFlight, .uncertain)
        let refused = try store.enqueue(Make.createPayload(topic: mood, minutes: 3, answers: good))
        try store.setState(refused, .failed, reason: .rejected)
        try store.enqueue(Make.createPayload(topic: other, minutes: 4, answers: good))

        let shown = try #require(try await WidgetReader(store: store.store).topic(id: mood.id))
        #expect(shown.queued == 2)
        #expect(shown.failed == 1)
        #expect(shown.lastAnswer == .string("good"))
    }

    @Test func aMissingTopicIsNil() async throws {
        let store = try seeded([Self.topic("Mood")])
        #expect(try await WidgetReader(store: store.store).topic(id: UUID()) == nil)
    }

    /// The home list's order: due first (longest overdue first), then scheduled by next due time,
    /// then the rest; archived topics are left out.
    @Test func theDueListIsDueFirstWithoutArchived() async throws {
        let now = Make.t0.addingTimeInterval(3 * 60 * 60)
        let overdue = Self.topic("Overdue", schedule: Self.every(60))  // due since t0+1h
        let lately = Self.topic("Lately", schedule: Self.every(120))  // due since t0+2h
        let later = Self.topic("Later", schedule: Self.every(600))  // due at t0+10h
        let plain = Self.topic("Plain")
        let archived = Self.topic("Archived", schedule: Self.every(60), status: .archived)
        let store = try seeded([plain, later, lately, overdue, archived])

        let list = try await WidgetReader(store: store.store).dueList(now: now)
        #expect(list.map(\.topic.name) == ["Overdue", "Lately", "Later", "Plain"])
        #expect(list[0].due(at: now)?.isDue == true)
        #expect(list[2].due(at: now)?.isDue == false)
    }

    // MARK: - WidgetTimeline

    @Test func entriesStartNowThenRefreshEvery15MinutesThenHourly() {
        let now = Make.t0
        let dates = WidgetTimeline.entryDates(for: [Self.topic("Plain")], now: now)
        let offsets = dates.map { Int($0.timeIntervalSince(now) / 60) }
        #expect(offsets.prefix(9) == [0, 15, 30, 45, 60, 75, 90, 105, 120])
        #expect(offsets.dropFirst(9).allSatisfy { ($0 - 120) % 60 == 0 })
        #expect(offsets.last == 12 * 60)
        #expect(WidgetTimeline.reloadDate(after: dates, now: now) == dates.last)
    }

    /// A due change gets its own entry, so the widget turns due at the minute it does.
    @Test func aDueChangeIsAnEntry() {
        let now = Make.t0.addingTimeInterval(7 * 60)  // logged at t0, every 50 min: due at t0+50
        let dates = WidgetTimeline.entryDates(for: [Self.topic("Water", schedule: Self.every(50))], now: now)
        let dueAt = Make.t0.addingTimeInterval(50 * 60)
        #expect(dates.contains(dueAt))
        #expect(dates.first == now)
        #expect(dates == dates.sorted() && Set(dates).count == dates.count)
        #expect(dates.allSatisfy { $0 >= now && $0 <= now.addingTimeInterval(WidgetTimeline.horizon) })
    }

    /// Many topics: at most `maxEntries`, and due changes win over refresh points.
    @Test func manyDueChangesAreCappedAndKeptFirst() {
        let now = Make.t0
        let topics = (1...80).map { n in
            Self.topic("T\(n)", schedule: Self.every(n), lastCapturedAt: now.addingTimeInterval(-Double(n) * 0.5))
        }
        let dates = WidgetTimeline.entryDates(for: topics, now: now)
        #expect(dates.count == WidgetTimeline.maxEntries)
        let changes = Set(
            topics.flatMap { topic in
                Due.timeline(
                    of: topic.schedule!, now: now, lastEntryAt: topic.lastCapturedAt,
                    scheduleSince: topic.scheduleUpdatedAt!, count: 24
                ).dropFirst().map(\.date)
            })
        #expect(changes.count > WidgetTimeline.maxEntries)
        #expect(dates.dropFirst().allSatisfy { changes.contains($0) }, "no refresh point while changes are cut")
        #expect(Array(dates.dropFirst()) == Array(changes.sorted().prefix(WidgetTimeline.maxEntries - 1)))
    }

    // MARK: - WidgetFingerprint

    @Test func theFingerprintChangesOnlyWithWhatWidgetsShow() {
        let mood = Self.topic("Mood", schedule: Self.every(60))
        let base = WidgetTopic(topic: mood, quick: QuickLog(questions: mood.questions), lastAnswer: .string("good"))
        let other = WidgetTopic(topic: Self.topic("Other"), quick: nil, lastAnswer: nil)
        #expect(WidgetFingerprint([base, other]) == WidgetFingerprint([other, base]), "order doesn't matter")

        var described = base
        described.topic.description = "Edited"
        #expect(WidgetFingerprint([described]) == WidgetFingerprint([base]), "a description isn't shown")

        func changed(_ change: (inout WidgetTopic) -> Void) -> Bool {
            var copy = base
            change(&copy)
            return WidgetFingerprint([copy]) != WidgetFingerprint([base])
        }
        #expect(changed { $0.lastAnswer = .string("meh") })
        #expect(changed { $0.queued = 1 })
        #expect(changed { $0.failed = 1 })
        #expect(changed { $0.topic.name = "Feelings" })
        #expect(changed { $0.topic.lastCapturedAt = Make.t0.addingTimeInterval(60) })
        #expect(changed { $0.topic.schedule = Self.every(30) })
        #expect(changed { $0.topic.status = .archived })
    }

    @Test func theGateReloadsOnTheFirstStateAndOnChangesOnly() {
        let mood = Self.topic("Mood")
        let first = WidgetFingerprint([WidgetTopic(topic: mood, quick: nil, lastAnswer: nil)])
        let queued = WidgetFingerprint([WidgetTopic(topic: mood, quick: nil, lastAnswer: nil, queued: 1)])
        var gate = WidgetReloadGate()
        let answers = [first, first, queued, first].map { gate.shouldReload($0) }
        #expect(answers == [true, false, true, true], "first state, same, changed, back again")
    }
}
