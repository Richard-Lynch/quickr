import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// How many notification categories a typical user generates (notifications.md §5.1, D1): a
/// seeded year of one person's logging over twelve topics, counting the distinct category ids
/// the app's refresh would register after each day. The numbers are recorded in §5.1.
@Suite struct CategoryGrowthTests {
    static let server = "00000000-0000-4000-8000-0000000000a1"

    /// One topic: its quick-log question and what a day's logging answers (nil: not logged).
    struct Habit {
        let name: String
        let questions: [Question]
        let answer: (inout Seeded, Int) -> AnswerValue?
        let id = UUID()
    }

    static func choice(_ key: String, _ n: Int) -> Question {
        Question(
            key: key, label: key,
            kind: .choice(.init(options: (0..<n).map { EnumOption(value: "o\($0)", label: "O\($0)") })))
    }

    static var habits: [Habit] {
        var weight = 72.0
        return [
            Habit(
                name: "Water",
                questions: [Question(key: "n", label: "Glasses", kind: .int(.init(min: 0, max: 20, unit: "glasses")))]
            ) {
                r, _ in .int(r.int(4...10))
            },
            Habit(
                name: "Weight",
                questions: [Question(key: "kg", label: "Weight", kind: .double(.init(decimals: 1, unit: "kg")))]
            ) {
                r, _ in
                weight = ((weight + Double(r.int(-3...3)) / 10) * 10).rounded() / 10
                return .double(weight)
            },
            Habit(
                name: "Sleep",
                questions: [
                    Question(key: "h", label: "Sleep", kind: .double(.init(min: 0, max: 24, decimals: 1, unit: "h")))
                ]
            ) {
                r, _ in .double(Double(r.int(50...90)) / 10)
            },
            Habit(name: "Coffee", questions: [Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 10)))])
            {
                r, _ in .int(r.int(0...4))
            },
            Habit(name: "Steps", questions: [Question(key: "steps", label: "Steps", kind: .int(.init(min: 0)))]) {
                r, _ in .int(r.int(2000...15000))
            },
            Habit(name: "Pain", questions: [Question(key: "pain", label: "Pain", kind: .int(.init(min: 0, max: 10)))]) {
                r, day in day % 3 == 0 ? .int(r.int(0...6)) : nil
            },
            Habit(name: "Mood", questions: [choice("mood", 5)]) { r, _ in .string("o\(r.weighted([5, 4, 3, 1, 1]))") },
            Habit(name: "Energy", questions: [choice("energy", 6)]) { r, _ in
                .string("o\(r.weighted([3, 3, 2, 2, 1, 1]))")
            },
            Habit(name: "Headache", questions: [choice("headache", 3)]) { r, day in
                day % 4 == 0 ? .string("o\(r.int(0...2))") : nil
            },
            Habit(name: "Meds", questions: [choice("meds", 2)]) { _, _ in .string("o0") },
            // No category: free text, and a two-question form.
            Habit(name: "Journal", questions: [Question(key: "text", label: "Text", kind: .string(.init()))]) { _, _ in
                .string("…")
            },
            Habit(
                name: "Workout",
                questions: [choice("kind", 3), Question(key: "min", label: "Minutes", kind: .int(.init()))]
            ) {
                _, _ in .string("o0")
            },
        ]
    }

    struct Year {
        /// Distinct ids registered by the end of each day (index 0 = day 1).
        var union: [Int] = []
        /// The categories current at the end of the year: one per quick-loggable topic.
        var current = 0
        /// Number-topic rows that also exist with the pre-N1 "✓" title after an upgrade on day 1.
        var preN1 = 0
    }

    /// Two edits a year per topic (a new version each, days 90 and 240), the app's refresh at the
    /// end of each day.
    static func year(seed: UInt64 = 7) -> Year {
        var random = Seeded(seed)
        let habits = habits
        var counts: [UUID: [String: Int]] = [:]
        var last: [UUID: AnswerValue] = [:]
        var ids = Set<String>()
        var year = Year()
        var currentIds: [String] = []
        for day in 1...365 {
            let version = day < 90 ? 1 : day < 240 ? 2 : 3
            currentIds = []
            for habit in habits {
                if let answer = habit.answer(&random, day) {
                    last[habit.id] = answer
                    if case .string(let value) = answer { counts[habit.id, default: [:]][value, default: 0] += 1 }
                }
                guard
                    let category = NotificationCategory(
                        serverId: server, topicId: habit.id.uuidString.lowercased(), version: version,
                        questions: habit.questions, counts: counts[habit.id] ?? [:], last: last[habit.id])
                else { continue }
                ids.insert(category.id)
                currentIds.append(category.id)
                if day == 1, case .number = category.descriptor { year.preN1 += 1 }
            }
            year.union.append(ids.count)
        }
        year.current = currentIds.count
        return year
    }

    @Test func aYearOfTypicalUseOutgrowsTheSystemsHundred() {
        let year = Self.year()
        let at = { (day: Int) in year.union[day - 1] }
        print(
            "category growth: day 7 \(at(7)), day 30 \(at(30)), day 90 \(at(90)), day 365 \(at(365)); current \(year.current); pre-N1 rows \(year.preN1)"
        )
        // Ten quick-loggable topics: the current set is small, far under the cap...
        #expect(year.current == 10)
        #expect(year.current + year.preN1 <= NotificationCategories.registrationCap)
        // ...but every new last value of a number topic is a new category, so the never-pruned
        // union passes the system's 100 within days (checkpoint D: notificationCategories()
        // reads back at most 100).
        #expect(at(30) > 100)
        #expect(at(365) > 500)
    }
}

/// SplitMix64: the same year on every run.
struct Seeded {
    var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func weighted(_ weights: [Int]) -> Int {
        var pick = int(0...(weights.reduce(0, +) - 1))
        for (index, weight) in weights.enumerated() {
            if pick < weight { return index }
            pick -= weight
        }
        return weights.count - 1
    }
}
