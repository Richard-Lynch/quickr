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
        // By id, naming the store it was read from (notifications.md §7.5).
        #expect(
            shown.recordURL.absoluteString
                == "quickr://t/\(mood.id.wireString)/record?scope=\(store.store.serverId)/\(store.store.storeGen)")
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
        let dates = WidgetTimeline.entryDates(for: [Self.topic("Plain")], now: now, skew: 0)
        let offsets = dates.map { Int($0.timeIntervalSince(now) / 60) }
        #expect(offsets.prefix(9) == [0, 15, 30, 45, 60, 75, 90, 105, 120])
        #expect(offsets.dropFirst(9).allSatisfy { ($0 - 120) % 60 == 0 })
        #expect(offsets.last == 12 * 60)
        #expect(WidgetTimeline.reloadDate(after: dates, now: now) == dates.last)
    }

    /// A due change gets its own entry, so the widget turns due at the minute it does.
    @Test func aDueChangeIsAnEntry() {
        let now = Make.t0.addingTimeInterval(7 * 60)  // logged at t0, every 50 min: due at t0+50
        let dates = WidgetTimeline.entryDates(for: [Self.topic("Water", schedule: Self.every(50))], now: now, skew: 0)
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
        let dates = WidgetTimeline.entryDates(for: topics, now: now, skew: 0)
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

    // MARK: - Skew (sync-protocol.md §10: due state in server time)

    /// Logged at t0, every 50 min: the server has it due at t0+50. A device clock 5 min behind
    /// the server (skew +5 min) sees that at device t0+45; one 5 min ahead (−5 min), at t0+55.
    static let water = topic("Water", schedule: every(50))
    static let serverDue = Make.t0.addingTimeInterval(50 * 60)

    @Test(arguments: [5.0 * 60, -5.0 * 60])
    func dueStateIsTheServersAroundTheBoundary(skew: TimeInterval) {
        let shown = WidgetTopic(topic: Self.water, quick: nil, lastAnswer: nil, skew: skew)
        let deviceDue = Self.serverDue.addingTimeInterval(-skew)
        #expect(shown.due(at: deviceDue.addingTimeInterval(-60))?.isDue == false)
        #expect(shown.due(at: deviceDue.addingTimeInterval(60))?.isDue == true)
        // Uncorrected, the device clock disagrees within the skew of the boundary.
        let uncorrected = WidgetTopic(topic: Self.water, quick: nil, lastAnswer: nil)
        let between = Self.serverDue.addingTimeInterval(-skew / 2)
        #expect(shown.due(at: between)?.isDue != uncorrected.due(at: between)?.isDue)
        // Its times are the server's ("Next 08:00" is 08:00, not 07:55), and against the server's
        // now the widget at device time d reads exactly what a widget without skew reads at d + skew.
        let before = shown.due(at: deviceDue.addingTimeInterval(-10 * 60))
        #expect(before?.nextDueAt == Self.serverDue)
        #expect(before?.lastEntryAt == Make.t0)
        #expect(shown.due(at: deviceDue.addingTimeInterval(60))?.dueSince == Self.serverDue)
        let utc = TimeZone(identifier: "UTC")!
        for minutes in [-90.0, -10, -1, 1, 10, 90] {
            let device = deviceDue.addingTimeInterval(minutes * 60)
            let label = DueView(due: shown.due(at: device), now: shown.serverTime(device))
                .label(locale: Locale(identifier: "en_GB"), timeZone: utc)
            let unskewed = DueView(due: uncorrected.due(at: device + skew), now: device + skew)
                .label(locale: Locale(identifier: "en_GB"), timeZone: utc)
            #expect(label == unskewed, "\(minutes) min from the device boundary")
        }
    }

    @Test(arguments: [5.0 * 60, -5.0 * 60])
    func theDueChangeEntryIsAtTheDeviceTimeOfTheServersBoundary(skew: TimeInterval) {
        // 2 min before the device time of the boundary: with the clock ahead (−5 min), that's
        // already past the server's boundary in device time, but not in server time.
        let now = Self.serverDue.addingTimeInterval(-skew - 2 * 60)
        let dates = WidgetTimeline.entryDates(for: [Self.water], now: now, skew: skew)
        #expect(dates.contains(Self.serverDue.addingTimeInterval(-skew)))
        #expect(!dates.contains(Self.serverDue))
        #expect(dates.first == now && dates == dates.sorted())
    }

    /// The due-first order is the server's (Codex r2's case): Daily, due at 08:00 and 09:00 and
    /// never logged, against Half, logged at 08:00 every 30 min (due since 08:30). At device 08:58
    /// the device clock has Daily due longest (since 08:00); a server 5 min ahead is at 09:03,
    /// where Daily's latest slot is 09:00, so Half is due longest; 5 min behind, it's still 08:53.
    @Test(
        arguments: [(5.0 * 60, ["Half", "Daily"]), (0, ["Daily", "Half"]), (-5.0 * 60, ["Daily", "Half"])]
            as [(TimeInterval, [String])])
    func theDueOrderIsTheServers(skew: TimeInterval, order: [String]) {
        let midnight = Date(timeIntervalSince1970: 1_772_582_400)  // 2026-03-04T00:00:00Z
        func at(_ hour: Double, _ minute: Double) -> Date { midnight.addingTimeInterval(hour * 3600 + minute * 60) }
        var daily = Self.topic(
            "Daily",
            schedule: .daily(
                .init(times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 9, minute: 0)], timezone: "UTC")),
            lastCapturedAt: nil)
        daily.createdAt = midnight.addingTimeInterval(-86_400)
        daily.scheduleUpdatedAt = daily.createdAt
        var half = Self.topic("Half", schedule: Self.every(30), lastCapturedAt: at(8, 0))
        half.createdAt = daily.createdAt
        half.scheduleUpdatedAt = daily.createdAt
        let topics = [daily, half].map { WidgetTopic(topic: $0, quick: nil, lastAnswer: nil, skew: skew) }
        #expect(WidgetTopic.dueFirst(topics, at: at(8, 58)).map(\.topic.name) == order)
    }

    /// The reader reads the store's measured skew into every topic it returns.
    @Test(arguments: [5.0 * 60, -5.0 * 60])
    func theReaderCarriesTheStoresSkew(skew: TimeInterval) async throws {
        let tea = Self.topic("Tea", schedule: Self.every(30))
        let deviceDue = Self.serverDue.addingTimeInterval(-skew)
        let store = try seeded([Self.water, tea])
        try store.write { db in
            try db.execute(sql: "UPDATE sync_state SET skew_ms = ? WHERE id = 1", arguments: [skew * 1000])
        }
        let reader = WidgetReader(store: store.store)
        let list = try await reader.dueList(now: deviceDue.addingTimeInterval(60))
        #expect(list.map(\.skew) == [skew, skew])
        #expect(list.allSatisfy { $0.due(at: deviceDue.addingTimeInterval(60))?.isDue == true })
        #expect(try await reader.topic(id: Self.water.id)?.skew == skew)
    }

    @Test func aSkewOfAMinuteOrMoreReloads() {
        func print(_ skew: TimeInterval) -> WidgetFingerprint {
            WidgetFingerprint([WidgetTopic(topic: Self.water, quick: nil, lastAnswer: nil, skew: skew)])
        }
        #expect(print(0) == print(20), "the smoothed estimate's drift doesn't spend reloads")
        #expect(print(0) != print(5 * 60))
        #expect(print(5 * 60) != print(-5 * 60))
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
        var gate = WidgetReloadGate<WidgetFingerprint>()
        let answers = [first, first, queued, first].map { gate.shouldReload($0) }
        #expect(answers == [true, false, true, true], "first state, same, changed, back again")
    }

    /// A long offline backlog: counted in SQL, other topics' and other kinds' items left out.
    @Test func aLargeBacklogIsCountedNotLoaded() async throws {
        let mood = Self.topic("Mood")
        let other = Self.topic("Other")
        let store = try seeded([mood, other])
        let good: [String: AnswerValue] = ["mood": .string("good")]
        try store.write { db in
            for n in 0..<2000 {
                try OutboxStorage.append(
                    db,
                    NewOutboxItem(
                        id: UUID(), payload: Make.createPayload(topic: mood, minutes: Double(n), answers: good),
                        baseRevision: nil, origin: .app, hold: nil),
                    now: Make.t0)
            }
        }
        for n in 0..<3 {
            let refused = try store.enqueue(Make.createPayload(topic: mood, minutes: 3000 + Double(n), answers: good))
            try store.setState(refused, .failed, reason: .rejected)
        }
        try store.enqueue(Make.createPayload(topic: other, answers: good))
        let shown = try #require(try await WidgetReader(store: store.store).topic(id: mood.id))
        #expect(shown.queued == 2000 && shown.failed == 3)
        #expect(shown.scope == store.store.scope)
    }

    /// ✓ shows and logs the same value: the last one while it's valid, else the start (the
    /// question's rules changed since: 20 cups is no longer allowed, so 0).
    @Test func checkFollowsTheCurrentRules() {
        let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 10, unit: "cups")))
        let water = Self.topic("Water", questions: [cups])
        #expect(
            WidgetTopic(topic: water, quick: QuickLog(questions: [cups]), lastAnswer: .int(3)).checkAnswer == .int(3))
        #expect(
            WidgetTopic(topic: water, quick: QuickLog(questions: [cups]), lastAnswer: .int(20)).checkAnswer == .int(0))
        #expect(WidgetTopic(topic: water, quick: QuickLog(questions: [cups]), lastAnswer: nil).checkAnswer == .int(0))
        #expect(WidgetTopic(topic: Self.topic("Mood"), quick: nil, lastAnswer: nil).checkAnswer == nil)
    }

    /// A Control shows the name, the last answer and its store: "queued" and the schedule aren't
    /// Control changes.
    @Test func theControlFingerprintIgnoresWhatControlsDontShow() {
        let mood = Self.topic("Mood", schedule: Self.every(60))
        let base = WidgetTopic(
            topic: mood, quick: QuickLog(questions: mood.questions), lastAnswer: .string("good"),
            scope: EntryScope("a/1"))
        func changes(_ change: (inout WidgetTopic) -> Void) -> Bool {
            var copy = base
            change(&copy)
            return ControlFingerprint([copy]) != ControlFingerprint([base])
        }
        #expect(!changes { $0.queued = 3 })
        #expect(!changes { $0.topic.schedule = Self.every(30) })
        #expect(changes { $0.lastAnswer = .string("meh") })
        #expect(changes { $0.topic.currentVersion += 1 })
        #expect(changes { $0.scope = EntryScope("b/1") })
        var other = base
        other.scope = EntryScope("b/1")
        #expect(WidgetFingerprint([other]) != WidgetFingerprint([base]), "a server switch reloads timelines too")
    }
}
