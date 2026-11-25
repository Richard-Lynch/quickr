import Foundation
import QuickrData
import QuickrTestSupport
import Testing

@testable import QuickrCore

/// content-display.md §1 (I4-SUMMARYLINE): `EntrySummary` against every case in
/// shared/fixtures/entry-summary-vectors.json (from `services/summary.py`; the PWA asserts the
/// same cases). The wire answers, timing and questions go through the app's own DTOs, so the
/// cases also pin the mapping the store and the API use.
@Suite(.timeLimit(.minutes(2))) struct EntrySummaryVectorTests {
    @Test func metaMatchesThePort() {
        let meta = EntrySummaryVectors.shared.meta
        #expect(meta.generatorVersion == 1)
        #expect(meta.maxLength == EntrySummary.maxLength)
        #expect(meta.separator == EntrySummary.separator)
    }

    @Test func hasTheSpecsCases() {
        let names = EntrySummaryVectors.shared.cases.map(\.name)
        #expect(names.count >= 20)
        #expect(Set(names).count == names.count)
        // content-display.md §1.3, without the typed-lap cases M4-STATS adds with M1's lap types.
        let required = [
            "timing_only_no_laps", "timing_one_lap", "timing_three_laps", "timing_hour_plus", "timing_paused_ignored",
            "answers_int_unit", "answers_double_decimals", "answers_double_trailing_zeros", "answers_enum_single",
            "answers_enum_multi", "answers_enum_unknown_option", "answers_str_collapsed_whitespace",
            "answers_str_empty_skipped", "answers_missing_optional_skipped", "both_timing_then_answers",
            "order_follows_questions_not_answers", "question_without_answer_skipped", "long_truncated",
            "long_truncation_flag_pair", "long_truncation_keycap", "long_truncation_zwj_family",
            "long_truncation_combining_marks", "empty", "untimed_entry_of_timed_topic",
        ]
        for name in required { #expect(names.contains(name), "\(name)") }
    }

    /// `answerText` collapses exactly Unicode `White_Space` (`meta.whitespace`), which is what
    /// `Unicode.Scalar.Properties.isWhitespace` is: not U+FEFF, U+200B, U+180E or U+001C…U+001F.
    @Test func whitespaceIsUnicodeWhiteSpace() {
        let expected = Set(EntrySummaryVectors.shared.meta.whitespace)
        var found: Set<UInt32> = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isWhitespace else { continue }
            found.insert(value)
        }
        #expect(found == expected)
    }

    @Test(arguments: EntrySummaryVectors.shared.cases)
    func line(_ vector: EntrySummaryVectors.Case) throws {
        let vectors = EntrySummaryVectors.shared
        let questions = try #require(vectors.questionSets[vector.questions], "question set \(vector.questions)")
        let timer = try #require(vectors.timerSets[vector.timer], "timer set \(vector.timer)")
        let answers = vector.answers.reduce(into: [String: AnswerValue]()) { $0[$1.key] = $1.value }
        let line = EntrySummary.line(
            answers: answers, timing: try vector.timing?.toDomain(), questions: questions, timer: timer)
        // Scalars, not `==`: Swift's String equality is canonical equivalence, so "e\u{301}" would
        // pass for "é". The vectors are not normalised and neither is the port.
        #expect(Array(line.unicodeScalars) == Array(vector.expected.unicodeScalars), "\(line.debugDescription)")
        #expect(line.count <= EntrySummary.maxLength)
    }

    /// The `Entry` convenience the tile line uses is the same line; no entry is `""`.
    @Test func lineOfAnEntry() throws {
        let vector = try #require(EntrySummaryVectors.shared.cases.first { $0.name == "both_timing_then_answers" })
        let vectors = EntrySummaryVectors.shared
        let entry = Entry(
            id: UUID(), topicId: UUID(), version: 1, revision: 1, source: "ios", channel: .ios, capturedAt: .now,
            createdAt: .now, updatedAt: .now,
            answers: vector.answers.reduce(into: [:]) { $0[$1.key] = $1.value }, timing: try vector.timing?.toDomain())
        let questions = try #require(vectors.questionSets[vector.questions])
        let timer = try #require(vectors.timerSets[vector.timer])
        #expect(EntrySummary.line(entry: entry, questions: questions, timer: timer) == vector.expected)
        #expect(EntrySummary.line(entry: nil, questions: questions, timer: timer) == "")
    }

    /// An answer whose text is empty is skipped like a missing one (the reference's `if text`):
    /// a single-select whose value is "" with no option, and a multi-select of just that.
    @Test func emptyChoiceTextIsSkipped() {
        let mood = Question(key: "mood", label: "Mood", kind: .choice(.init(options: [.init(value: "a", label: "A")])))
        let weight = Question(key: "weight", label: "Weight", kind: .int(.init(unit: "kg")))
        for value in [AnswerValue.string(""), .strings([""]), .strings([])] {
            let line = EntrySummary.line(
                answers: ["mood": value, "weight": .int(72)], timing: nil, questions: [mood, weight], timer: nil)
            #expect(line == "Weight: 72 kg", "\(value)")
        }
        #expect(EntrySummary.answerText(.strings([""]), for: mood) == nil)
        #expect(EntrySummary.answerText(.strings(["", "a"]), for: mood) == ", A")
    }

    /// The typed-lap branch, until M4-STATS adds its vectors with M1's lap types: the reference's
    /// rule on the lap types directly (timing_tiktok, timing_renamed, timing_mixed_typed_untyped,
    /// timing_lap_type_not_in_timer of §1.3).
    @Test func typedLaps() {
        let tiktok = [(key: "run", label: "Run"), (key: "rest", label: "Rest")]
        func line(_ types: [String?], _ declared: [(key: String, label: String)] = tiktok) -> String {
            EntrySummary.timingLine(activeMs: 760_000, lapTypes: types, declared: declared)
        }
        #expect(line(["rest", "run", "rest", "run", "rest", "run"]) == "12:40 · Run 3 · Rest 3")
        #expect(line(["cig", "cig"], [(key: "cig", label: "Cig")]) == "12:40 · Cig 2")
        #expect(line([nil, "run", nil]) == "12:40 · Run 1 · 2 laps")
        #expect(line(["run", "", nil]) == "12:40 · Run 1 · 2 laps")
        #expect(line(["walk", "run", "walk", nil]) == "12:40 · Run 1 · walk 2 · 1 lap")
        #expect(line(["b", "a", "b"], []) == "12:40 · b 2 · a 1")
        #expect(line([nil, nil]) == "12:40 · 2 laps")
        #expect(line([]) == "12:40")
        #expect(line(["run"], [(key: "run", label: "Jog"), (key: "run", label: "Run")]) == "12:40 · Run 1")
    }

    /// `_number`'s rounding beyond the vectors (outputs copied from `summary._number`): half away
    /// from zero on the shortest decimal, exponent forms, carries and the reference's "-0".
    @Test(arguments: [
        (1.005, 2, "1.01"), (-1.5, 0, "-2"), (1e16, 3, "10000000000000000"), (1e-5, 3, "0"), (0.0005, 3, "0.001"),
        (9.9996, 3, "10"), (-0.0001, 3, "-0"), (-0.0, 3, "-0"), (0.5, 0, "1"), (2.5, 0, "3"),
        (123456789.123456789, 5, "123456789.12346"), (5e-324, 3, "0"), (0.15, 1, "0.2"), (99.95, 1, "100"),
        (36.65, 1, "36.7"), (1234.5, 3, "1234.5"),
    ])
    func number(_ value: Double, _ decimals: Int, _ expected: String) {
        #expect(EntrySummary.number(value, decimals: decimals) == expected)
    }

    @Test func largestDouble() {
        let text = EntrySummary.number(.greatestFiniteMagnitude, decimals: 0)
        #expect(text == "17976931348623157" + String(repeating: "0", count: 292))
    }
}

struct EntrySummaryVectors: Decodable, Sendable {
    static let shared: EntrySummaryVectors = {
        do {
            return try JSONDecoder().decode(
                EntrySummaryVectors.self, from: Fixtures.data("entry-summary-vectors.json"))
        } catch {
            fatalError("entry-summary-vectors.json: \(error)")
        }
    }()

    struct Meta: Decodable, Sendable {
        var generatorVersion: Int
        var maxLength: Int
        var separator: String
        var whitespace: [UInt32]

        enum CodingKeys: String, CodingKey {
            case separator, whitespace
            case generatorVersion = "generator_version"
            case maxLength = "max_length"
        }
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var questions: String
        var timer: String
        var answers: [AnswerDTO]
        var timing: TimingDTO?
        var expected: String

        var testDescription: String { name }
    }

    var meta: Meta
    /// The entry's version's questions, in the API's shape with its defaults
    /// (`QuestionInputDTO` accepts the omitted keys).
    var questionSets: [String: [Question]]
    /// The topic's current timer; `.some(nil)` for an untimed topic.
    var timerSets: [String: TopicTimer?]
    var cases: [Case]

    enum CodingKeys: String, CodingKey {
        case meta, cases
        case questionSets = "question_sets"
        case timerSets = "timer_sets"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(Meta.self, forKey: .meta)
        cases = try c.decode([Case].self, forKey: .cases)
        questionSets = try c.decode([String: [QuestionInputDTO]].self, forKey: .questionSets)
            .mapValues { $0.map { $0.toDomain() } }
        timerSets = try c.decode([String: TopicTimer?].self, forKey: .timerSets)
    }
}
