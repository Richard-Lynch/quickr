import QuickrCore
import Testing

/// A port of the quick-log half of frontend/src/lib/quickLog.test.ts, plus "same as last time".
@Suite struct QuickLogTests {
    typealias F = AnswerFixtures

    static func enumQ(_ n: Int, multiple: Bool = false) -> Question {
        Question(
            key: "mood", label: "Mood",
            kind: .choice(
                .init(options: (0..<n).map { EnumOption(value: "o\($0)", label: "O\($0)") }, multiple: multiple)))
    }

    static let intQ = Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 30)))
    static let noteQ = Question(key: "note", label: "Note", required: false, kind: .string(.init()))

    @Test func chipsForOneRequiredSingleSelectWithAtMostSixActiveOptions() {
        #expect(QuickLog(questions: [Self.enumQ(4)])?.isChips == true)
        #expect(QuickLog(questions: [Self.enumQ(6)])?.isChips == true)
        #expect(QuickLog(questions: [Self.enumQ(7)]) == nil)
        // Archived options don't count, and aren't offered.
        let q = F.choice(Self.enumQ(7)) { $0.options[0].archived = true }
        guard case .chips(_, let options) = QuickLog(questions: [q]) else {
            Issue.record("expected chips")
            return
        }
        #expect(!options.map(\.value).contains("o0"))
    }

    @Test func aStepperForOneRequiredIntOrDouble() {
        #expect(QuickLog(questions: [Self.intQ]) == .number(question: Self.intQ))
        let double = F.with(Self.intQ) { $0.kind = .double(.init(min: 0, max: 30, decimals: 1)) }
        #expect(QuickLog(questions: [double])?.question == double)
    }

    @Test func ignoresOptionalExtraQuestions() {
        #expect(QuickLog(questions: [Self.enumQ(3), Self.noteQ])?.isChips == true)
    }

    @Test func fallsBackToTheRecordScreenOtherwise() {
        #expect(QuickLog(questions: [Self.enumQ(3), Self.intQ]) == nil)  // two required
        #expect(QuickLog(questions: [F.with(Self.intQ) { $0.required = false }]) == nil)  // only optional
        #expect(QuickLog(questions: [Self.enumQ(3, multiple: true)]) == nil)  // multi-select
        #expect(QuickLog(questions: [F.with(Self.noteQ) { $0.required = true }]) == nil)  // text
        #expect(QuickLog(questions: []) == nil)
    }

    @Test func prefillsNumbersWithTheLastValidValueElseMinAtLeastZero() {
        #expect(QuickLog.initialText(for: Self.intQ, last: .int(7)) == "7")
        #expect(QuickLog.initialText(for: Self.intQ, last: .int(99)) == "0")  // out of range now
        #expect(QuickLog.initialText(for: Self.intQ, last: nil) == "0")
        let negative = F.with(Self.intQ) { $0.kind = .int(.init(min: -5)) }
        #expect(QuickLog.initialText(for: negative, last: nil) == "")
        #expect(QuickLog.parseNumber("31", for: Self.intQ) == .failure("Must be at most 30"))
        #expect(QuickLog.parseNumber("3", for: Self.intQ) == .success(["glasses": .int(3)]))
    }

    @Test func parsesNumbersAsIfRequired() {
        let optional = F.with(Self.intQ) { $0.required = false }
        #expect(QuickLog.parseNumber("", for: optional) == .failure("Required"))
        #expect(QuickLog.parseNumber("abc", for: Self.intQ) == .failure("Enter a whole number"))
        #expect(QuickLog.parseNumber("2,5", for: F.hours) == .success(["hours": .double(2.5)]))
    }

    @Test func aChipTapLogsThatOption() {
        let option = EnumOption(value: "o1", label: "O1")
        #expect(QuickLog.answers(picking: option, for: Self.enumQ(3)) == ["mood": .string("o1")])
    }

    // MARK: same as last time (constraints.test.ts and PLAN §2 Repeat-last)

    @Test func reusableInputsKeepOnlyValuesThatAreStillValid() {
        let hours = Question(key: "hours", label: "Hours", kind: .int(.init(min: 0, max: 10)))
        #expect(
            RepeatLast.reusableInputs(["tags": .strings(["a", "x"]), "hours": .int(12)], questions: [F.tags, hours])
                == ["tags": .selection(["a"]), "hours": .text("")])
        // An old single-select answer becomes a one-option selection.
        #expect(RepeatLast.reusableInputs(["tags": .string("b")], questions: [F.tags]) == ["tags": .selection(["b"])])
        #expect(RepeatLast.reusableInputs(["mood": .string("awful")], questions: [F.mood]) == ["mood": .text("")])
    }

    @Test func repeatLastRelogsAnswersThatStillValidate() {
        let last: [String: AnswerValue] = ["hours": .double(7.5), "wakeups": .int(1), "mood": .string("good")]
        #expect(RepeatLast.answers(last, questions: F.all) == last)
        // A whole number for a double question is what the server accepts too.
        #expect(
            RepeatLast.answers(["hours": .int(7), "mood": .string("good")], questions: F.all)
                == ["hours": .double(7), "mood": .string("good")])
        // The server stores a selection in option order; reordered options are still the same answer.
        #expect(
            RepeatLast.answers(["tags": .strings(["c", "a"])], questions: [F.tags]) == ["tags": .strings(["a", "c"])])
    }

    @Test func repeatLastWithNoAnswersWhenEveryQuestionIsOptional() {
        #expect(RepeatLast.answers([:], questions: [F.wakeups]) == [:])
        #expect(RepeatLast.answers([:], questions: [F.wakeups, F.note]) == [:])
        #expect(RepeatLast.answers([:], questions: F.all) == nil)
    }

    @Test func repeatLastOpensTheRecordScreenOtherwise() {
        // An archived option, a value now out of range, a newly required question.
        #expect(RepeatLast.answers(["hours": .double(7), "mood": .string("awful")], questions: F.all) == nil)
        #expect(RepeatLast.answers(["hours": .double(25), "mood": .string("good")], questions: F.all) == nil)
        #expect(RepeatLast.answers(["hours": .double(7)], questions: F.all) == nil)
        // The selection limits apply to the current version.
        #expect(RepeatLast.answers(["tags": .strings(["a"])], questions: [F.tags]) == nil)
        // An answer to a question the version no longer has.
        #expect(
            RepeatLast.answers(["hours": .double(7), "mood": .string("good"), "gone": .int(1)], questions: F.all) == nil
        )
    }

    @Test func repeatLastNeverReshapesAnAnswer() {
        let single = F.choice(F.tags) {
            $0.multiple = false
            $0.minSelected = nil
            $0.maxSelected = nil
        }
        // A list for what is now a single-select (the prefill would keep "a").
        #expect(RepeatLast.answers(["tags": .strings(["a", "b"])], questions: [single]) == nil)
        #expect(RepeatLast.answers(["tags": .strings(["a"])], questions: [single]) == nil)
        // A single value for what is now a multi-select.
        #expect(RepeatLast.answers(["tags": .string("a")], questions: [F.choice(F.tags) { $0.minSelected = 1 }]) == nil)
        // Text for what is now a number, a number for what is now text, a double for an int.
        let count = Question(key: "n", label: "N", kind: .int(.init()))
        #expect(RepeatLast.answers(["n": .string("12")], questions: [count]) == nil)
        #expect(RepeatLast.answers(["n": .double(12)], questions: [count]) == nil)
        let text = Question(key: "n", label: "N", kind: .string(.init()))
        #expect(RepeatLast.answers(["n": .int(12)], questions: [text]) == nil)
        // A stored value validation would change (the server strips it).
        #expect(RepeatLast.answers(["n": .string(" padded ")], questions: [text]) == nil)
        // Duplicates, which the server rejects rather than collapses.
        let free = F.choice(F.tags) {
            $0.minSelected = nil
            $0.maxSelected = nil
        }
        #expect(RepeatLast.answers(["tags": .strings(["a", "a"])], questions: [free]) == nil)
        // The prefill still converts: the record screen opens with what can be kept.
        #expect(RepeatLast.reusableInputs(["tags": .strings(["a", "b"])], questions: [single]) == ["tags": .text("a")])
        #expect(RepeatLast.reusableInputs(["n": .string("12")], questions: [count]) == ["n": .text("12")])
    }
}

extension QuickLog {
    fileprivate var isChips: Bool {
        if case .chips = self { return true }
        return false
    }
}
