import Foundation
import QuickrCore
import QuickrUI
import Testing

@Suite(.timeLimit(.minutes(2))) struct TopicTextTests {
    static let text: TopicText = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return TopicText(calendar: calendar, locale: Locale(identifier: "en_US"))
    }()

    /// Times read like `Intl` in a browser: a narrow no-break space (U+202F) before AM/PM.
    /// Wed 2026-10-21 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_584_000)

    static func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    @Test func dueReadsDueNowForHalfAnHourThenOverdue() {
        let fresh = DueStatus(isDue: true, dueSince: Self.at(-29))
        #expect(
            Self.text.dueView(fresh, now: Self.now) == DueView(tone: .due, label: "Due now · since 11:31\u{202F}AM"))
        let old = DueStatus(isDue: true, dueSince: Self.at(-30))
        #expect(
            Self.text.dueView(old, now: Self.now)
                == DueView(tone: .overdue, label: "Overdue · since 11:30\u{202F}AM"))
        #expect(Self.text.dueView(DueStatus(isDue: true), now: Self.now) == DueView(tone: .due, label: "Due now"))
        #expect(Self.text.dueView(old, now: Self.now).isDue)
    }

    @Test func aPassedNextSlotIsDueBeforeTheServerSaysSo() {
        let passed = DueStatus(isDue: false, nextDueAt: Self.at(-5))
        #expect(TopicText.isDueNow(passed, now: Self.now))
        #expect(Self.text.dueView(passed, now: Self.now).label == "Due now · since 11:55\u{202F}AM")
    }

    @Test func upcomingSlotsReadAsSoonNextOrADay() {
        func label(_ minutes: Double) -> DueView {
            Self.text.dueView(DueStatus(isDue: false, nextDueAt: Self.at(minutes)), now: Self.now)
        }
        #expect(label(25) == DueView(tone: .soon, label: "Due in 25 min"))
        #expect(label(0.2) == DueView(tone: .soon, label: "Due in 1 min"))
        #expect(label(60) == DueView(tone: .soon, label: "Due in 1 h"))
        #expect(label(9 * 60) == DueView(tone: .later, label: "Next 9:00\u{202F}PM"))
        #expect(label(20 * 60) == DueView(tone: .later, label: "Tomorrow 8:00\u{202F}AM"))
        #expect(label(5 * 24 * 60) == DueView(tone: .later, label: "Mon 12:00\u{202F}PM"))
        #expect(label(30 * 24 * 60) == DueView(tone: .later, label: "Nov 20"))
        #expect(Self.text.dueView(nil, now: Self.now) == DueView(tone: .none, label: ""))
        #expect(Self.text.dueView(DueStatus(isDue: false), now: Self.now).tone == .none)
    }

    @Test func relativeTimesUseTheLargestUnitAndNamedDays() {
        #expect(Self.text.relative(nil, now: Self.now) == "never")
        #expect(Self.text.relative(Self.at(-0.5), now: Self.now) == "just now")
        #expect(Self.text.relative(Self.at(-5), now: Self.now) == "5 minutes ago")
        #expect(Self.text.relative(Self.at(-4 * 60), now: Self.now) == "4 hours ago")
        #expect(Self.text.relative(Self.at(-26 * 60), now: Self.now) == "yesterday")
        #expect(Self.text.relative(Self.at(-15 * 24 * 60), now: Self.now) == "2 weeks ago")
    }

    @Test func answersReadWithLabelsUnitsAndDecimals() {
        let severity = Question(
            key: "s", label: "Severity", required: true,
            kind: .choice(.init(options: [EnumOption(value: "mild", label: "Mild")], multiple: false)))
        #expect(Self.text.answer(.string("mild"), for: severity) == "Mild")
        #expect(Self.text.answer(.string("gone"), for: severity) == "gone")  // an option since removed
        #expect(Self.text.answer(.strings(["mild", "x"]), for: severity) == "Mild, x")
        #expect(Self.text.answer(.int(3), for: severity) == nil)

        let glasses = Question(key: "g", label: "Glasses", required: true, kind: .int(.init(unit: "glasses")))
        #expect(Self.text.answer(.int(1500), for: glasses) == "1,500 glasses")
        let km = Question(key: "k", label: "Distance", required: true, kind: .double(.init(decimals: 1, unit: "km")))
        #expect(Self.text.answer(.double(5.25), for: km) == "5.2 km")
        let free = Question(key: "w", label: "Weight", required: true, kind: .double(.init()))
        #expect(Self.text.answer(.double(70.1234), for: free) == "70.123")
        #expect(Self.text.answer(.string("70"), for: free) == nil)
    }

    @Test func dueIsRecomputedFromTheLastEntrySoALogClearsIt() throws {
        func topic(last: Date?, status: TopicStatus = .active) -> Topic {
            Topic(
                id: UUID(), slug: "water", name: "Water", status: status, currentVersion: 1, revision: 1,
                questionCount: 1, lastCapturedAt: last, createdAt: Self.at(-24 * 60), updatedAt: Self.at(-24 * 60),
                schedule: .interval(.init(everyMinutes: 120, timezone: "UTC")), scheduleUpdatedAt: Self.at(-5 * 60),
                questions: [])
        }
        let stale = try #require(TopicText.dueStatus(topic(last: Self.at(-3 * 60)), now: Self.now))
        #expect(stale.isDue)
        let logged = try #require(TopicText.dueStatus(topic(last: Self.at(-1)), now: Self.now))
        #expect(!logged.isDue && logged.nextDueAt == Self.at(119))
        #expect(TopicText.dueStatus(topic(last: nil, status: .archived), now: Self.now)?.isDue == false)
        var unscheduled = topic(last: nil)
        unscheduled.schedule = nil
        #expect(TopicText.dueStatus(unscheduled, now: Self.now) == nil)
    }

    @Test func countsUsePlurals() {
        #expect(Self.text.count(1, "entry", "entries") == "1 entry")
        #expect(Self.text.count(1234, "entry", "entries") == "1,234 entries")
        #expect(Self.text.count(2, "glass", "glasses") == "2 glasses")
    }
}
