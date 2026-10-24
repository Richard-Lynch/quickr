import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/home-due-vectors.json`, from the PWA's own `dueParts`, `splitByDue` and
/// `dueCount`: the tile's due pill, the home sections and the due count with the open-run rule
/// (timers.md §11.1, R11). Day offsets are in the file's timezone.
@Suite struct DueViewTests {
    struct Vectors: Decodable {
        struct Meta: Decodable {
            var timezone: String
            var freshDueMs: Double
            var soonMs: Double

            enum CodingKeys: String, CodingKey {
                case timezone
                case freshDueMs = "fresh_due_ms"
                case soonMs = "soon_ms"
            }
        }

        struct Due: Decodable, Sendable {
            var isDue: Bool
            var dueSince: Date?
            var nextDueAt: Date?
            var lastEntryAt: Date?

            enum CodingKeys: String, CodingKey {
                case isDue = "is_due"
                case dueSince = "due_since"
                case nextDueAt = "next_due_at"
                case lastEntryAt = "last_entry_at"
            }

            var status: DueStatus {
                DueStatus(isDue: isDue, dueSince: dueSince, nextDueAt: nextDueAt, lastEntryAt: lastEntryAt)
            }
        }

        struct Parts: Decodable, Sendable {
            struct When: Decodable, Sendable {
                var at: Date
                var dayOffset: Int

                enum CodingKeys: String, CodingKey {
                    case at
                    case dayOffset = "day_offset"
                }
            }

            var tone: String
            var kind: String
            var when: When?
            var minutes: Int?
        }

        struct DueViewCase: Decodable, Sendable, CustomTestStringConvertible {
            var name: String
            var now: Date
            var due: Due?
            var expected: Parts
            var testDescription: String { name }
        }

        struct SplitCase: Decodable, Sendable, CustomTestStringConvertible {
            struct Item: Decodable, Sendable {
                var id: String
                var status: String
                var scheduled: Bool
                var due: Due?
            }

            struct Expected: Decodable, Sendable {
                var due: [String]
                var upcoming: [String]
                var other: [String]
                var dueCount: Int

                enum CodingKeys: String, CodingKey {
                    case due, upcoming, other
                    case dueCount = "due_count"
                }
            }

            var name: String
            var now: Date
            var topics: [Item]
            /// Ids of the topics with an open run.
            var openRuns: [String]
            var expected: Expected

            enum CodingKeys: String, CodingKey {
                case name, now, topics, expected
                case openRuns = "open_runs"
            }
            var testDescription: String { name }
        }

        var meta: Meta
        var dueView: [DueViewCase]
        var split: [SplitCase]

        enum CodingKeys: String, CodingKey {
            case meta
            case dueView = "due_view"
            case split
        }
    }

    static let vectors: Vectors = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Vectors.self, from: Fixtures.data("home-due-vectors.json"))
        } catch {
            fatalError("home-due-vectors.json: \(error)")
        }
    }()

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: vectors.meta.timezone)!
        return calendar
    }

    @Test func constantsMatchThePWA() {
        #expect(DueView.freshFor * 1000 == Self.vectors.meta.freshDueMs)
        #expect(DueView.soonWithin * 1000 == Self.vectors.meta.soonMs)
    }

    @Test(arguments: vectors.dueView)
    func dueParts(_ vector: Vectors.DueViewCase) {
        let view = DueView(due: vector.due?.status, now: vector.now, calendar: Self.calendar)
        #expect(view.tone.rawValue == vector.expected.tone)
        #expect(Self.parts(view.kind) == Self.expected(vector.expected))
    }

    @Test(arguments: vectors.split)
    func sections(_ vector: Vectors.SplitCase) {
        let items = vector.topics.map { item in
            TopicListing.Item(
                value: item.id, topic: Self.topic(item), due: item.due?.status)
        }
        // An id with no topic in the case stands for a run of a topic that isn't listed.
        let openRuns = Set(vector.openRuns.map { id in items.first { $0.value == id }?.topic.id ?? UUID() })
        let sections = TopicListing.sections(items, now: vector.now, openRuns: openRuns)
        #expect(sections.due.map(\.value) == vector.expected.due)
        #expect(sections.upcoming.map(\.value) == vector.expected.upcoming)
        #expect(sections.other.map(\.value) == vector.expected.other)
        #expect(TopicListing.dueCount(items, now: vector.now, openRuns: openRuns) == vector.expected.dueCount)
        #expect(sections.due.count == vector.expected.dueCount, "the due section and the count agree")
    }

    /// Every split case ran (a parameterized case can be filtered out), and the open-run rule has
    /// cases.
    @Test func splitCasesAreAllPresent() {
        #expect(Self.vectors.split.count >= 11)
        #expect(Set(Self.vectors.split.map(\.name)).count == Self.vectors.split.count)
        #expect(Self.vectors.split.contains { !$0.openRuns.isEmpty && $0.expected.dueCount == 0 })
    }

    /// The overload over topics computes each one's due status, then applies the same rule.
    @Test func dueCountOverTopicsLeavesOutOpenRuns() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = Vectors.SplitCase.Item(id: "a", status: "active", scheduled: true, due: nil)
        let topics = [
            Self.topic(due), Self.topic(due), Self.topic(.init(id: "b", status: "archived", scheduled: true)),
        ]
        #expect(TopicListing.dueCount(topics, now: now, openRuns: TopicListing.noOpenRuns) == 2)
        #expect(TopicListing.dueCount(topics, now: now, openRuns: [topics[0].id]) == 1)
        #expect(TopicListing.dueCount(topics, now: now, openRuns: [topics[0].id, topics[1].id]) == 0)
    }

    // MARK: - Labels (the device's formats)

    /// The sentences around the device's time, weekday and date formats (which vary by OS release,
    /// so the times are formatted here the same way).
    @Test func labelsReadLikeThePWA() throws {
        let london = TimeZone(identifier: "Europe/London")!
        let gb = Locale(identifier: "en_GB")
        func label(_ kind: DueView.Kind) -> String {
            DueView(tone: .later, kind: kind).label(locale: gb, timeZone: london)
        }
        func at(_ iso: String) throws -> Date { try Date(iso, strategy: .iso8601) }
        func time(_ iso: String) throws -> String {
            var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: gb)
            style.timeZone = london
            return try at(iso).formatted(style)
        }
        #expect(label(.none) == "")
        #expect(label(.dueNow) == "Due now")
        let a = "2026-10-20T11:45:00Z"
        let b = "2026-10-19T20:00:00Z"
        let c = "2026-10-20T20:00:00Z"
        let d = "2026-10-21T07:00:00Z"
        let e = "2026-10-23T07:00:00Z"
        let f = "2026-11-12T08:00:00Z"
        #expect(try label(.dueSince(.init(at: at(a), dayOffset: 0))) == "Due now · since \(time(a))")
        #expect(try label(.overdueSince(.init(at: at(b), dayOffset: -1))) == "Overdue · since yesterday \(time(b))")
        #expect(label(.dueIn(minutes: 1)) == "Due in 1 min")
        #expect(label(.dueIn(minutes: 59)) == "Due in 59 min")
        #expect(label(.dueIn(minutes: 60)) == "Due in 1 h")
        #expect(label(.dueIn(minutes: 90)) == "Due in 2 h")  // Math.round(1.5) = 2
        #expect(try label(.next(.init(at: at(c), dayOffset: 0))) == "Next \(time(c))")
        #expect(try label(.when(.init(at: at(d), dayOffset: 1))) == "Tomorrow \(time(d))")
        #expect(try label(.when(.init(at: at(e), dayOffset: 3))) == "Fri \(time(e))")
        #expect(try label(.when(.init(at: at(f), dayOffset: 23))) == "12 Nov")
        #expect(try time(c).contains("21"), "a 24-hour clock in en_GB")
    }

    @Test func minutesRoundLikeMathRound() {
        #expect(DueView.minutes(0) == 1)
        #expect(DueView.minutes(29.9) == 1)
        #expect(DueView.minutes(89.9) == 1)
        #expect(DueView.minutes(90) == 2)  // 1.5 rounds up
        #expect(DueView.minutes(59.5 * 60) == 60)
    }

    // MARK: - Helpers

    struct Flat: Equatable {
        var kind: String
        var at: Date?
        var dayOffset: Int?
        var minutes: Int?
    }

    static func parts(_ kind: DueView.Kind) -> Flat {
        switch kind {
        case .none: Flat(kind: "none")
        case .dueNow: Flat(kind: "due_now")
        case .dueSince(let w): Flat(kind: "due_since", at: w.at, dayOffset: w.dayOffset)
        case .overdueSince(let w): Flat(kind: "overdue_since", at: w.at, dayOffset: w.dayOffset)
        case .dueIn(let minutes): Flat(kind: "due_in", minutes: minutes)
        case .next(let w): Flat(kind: "next", at: w.at, dayOffset: w.dayOffset)
        case .when(let w): Flat(kind: "when", at: w.at, dayOffset: w.dayOffset)
        }
    }

    static func expected(_ parts: Vectors.Parts) -> Flat {
        Flat(kind: parts.kind, at: parts.when?.at, dayOffset: parts.when?.dayOffset, minutes: parts.minutes)
    }

    static func topic(_ item: Vectors.SplitCase.Item) -> Topic {
        let epoch = Date(timeIntervalSince1970: 0)
        return Topic(
            id: UUID(), slug: item.id, name: item.id, status: item.status == "archived" ? .archived : .active,
            currentVersion: 1, revision: 1, questionCount: 0, createdAt: epoch, updatedAt: epoch,
            schedule: item.scheduled ? .interval(.init(everyMinutes: 60, timezone: "UTC")) : nil, questions: [])
    }
}
