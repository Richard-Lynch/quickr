import QuickrCore
import Testing

/// A port of frontend/src/lib/answerSchema.test.ts and the answer half of constraints.test.ts,
/// with every user-facing message asserted.
enum AnswerFixtures {
    static let hours = Question(
        key: "hours", label: "Hours slept", kind: .double(.init(min: 0, max: 24, decimals: 1, unit: "h")))
    static let wakeups = Question(
        key: "wakeups", label: "Wake-ups", required: false, kind: .int(.init(min: 0, max: 20)))
    static let note = Question(
        key: "note", label: "Note", required: false, kind: .string(.init(minLength: 3, maxLength: 10, multiline: true)))
    static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(
            .init(options: [
                .init(value: "good", label: "Good"), .init(value: "meh", label: "Meh"),
                .init(value: "awful", label: "Awful", archived: true),
            ])))
    static let all = [hours, wakeups, note, mood]

    /// Multi-select, exactly two of a, b, c (x is archived).
    static let tags = Question(
        key: "tags", label: "Tags",
        kind: .choice(
            .init(
                options: [
                    .init(value: "a", label: "A"), .init(value: "b", label: "B"), .init(value: "c", label: "C"),
                    .init(value: "x", label: "X", archived: true),
                ], multiple: true, minSelected: 2, maxSelected: 2)))

    static func with(_ question: Question, _ change: (inout Question) -> Void) -> Question {
        var copy = question
        change(&copy)
        return copy
    }

    static func choice(_ question: Question, _ change: (inout Question.ChoiceRules) -> Void) -> Question {
        guard case .choice(var rules) = question.kind else { return question }
        change(&rules)
        return with(question) { $0.kind = .choice(rules) }
    }
}

@Suite struct AnswerValidatorTests {
    typealias F = AnswerFixtures

    private func errors(
        _ questions: [Question], _ inputs: [String: AnswerInput], allow: [String: Set<String>] = [:]
    ) -> [String: String] {
        switch AnswerValidator(questions: questions, allowArchived: allow).validate(inputs) {
        case .success: [:]
        case .failure(let errors): errors.byKey
        }
    }

    private func values(
        _ questions: [Question], _ inputs: [String: AnswerInput], allow: [String: Set<String>] = [:]
    ) -> [String: AnswerValue?]? {
        try? AnswerValidator(questions: questions, allowArchived: allow).validate(inputs).get().all
    }

    private func message(_ question: Question, _ input: AnswerInput, allow: Set<String> = []) -> String? {
        guard case .failure(let m) = AnswerValidator.validate(question, input, allowArchived: allow) else { return nil }
        return m.message
    }

    /// nil when invalid, `.some(nil)` when validly blank.
    private func value(_ question: Question, _ input: AnswerInput, allow: Set<String> = []) -> AnswerValue?? {
        switch AnswerValidator.validate(question, input, allowArchived: allow) {
        case .success(let value): .some(value)
        case .failure: nil
        }
    }

    // MARK: answerSchema.test.ts

    @Test func parsesAValidFormIntoAnAPIAnswerMap() throws {
        let result = try AnswerValidator(questions: F.all).validate([
            "hours": .text("7,5"), "wakeups": .text("2"), "note": .text("  fine  "), "mood": .text("good"),
        ]).get()
        #expect(
            result.answered == [
                "hours": .double(7.5), "wakeups": .int(2), "note": .string("fine"), "mood": .string("good"),
            ])
    }

    @Test func blankOptionalFieldsAreNilAndBlankRequiredOnesAreFlagged() throws {
        #expect(
            errors(F.all, ["hours": .text(""), "wakeups": .text(""), "note": .text(" "), "mood": .text("")])
                == ["hours": "Required", "mood": "Required"])
        let ok = try AnswerValidator(questions: F.all).validate(["hours": .text("8"), "mood": .text("meh")]).get()
        let all: [String: AnswerValue?] = ["hours": .double(8), "wakeups": nil, "note": nil, "mood": .string("meh")]
        #expect(ok.all == all)
        // Blank optional answers are omitted from a create.
        #expect(ok.answered == ["hours": .double(8), "mood": .string("meh")])
    }

    @Test func enforcesIntegerAndRangeRules() {
        #expect(
            errors(F.all, ["hours": .text("25"), "wakeups": .text("1.5"), "mood": .text("good")])
                == ["hours": "Must be at most 24 h", "wakeups": "Enter a whole number"])
        #expect(errors([F.wakeups], ["wakeups": .text("-1")]) == ["wakeups": "Must be at least 0"])
    }

    @Test func rejectsNonNumbersForDoubles() {
        #expect(errors([F.hours], ["hours": .text("abc")]) == ["hours": "Enter a number"])
    }

    @Test func enforcesStringLengthLimits() {
        #expect(errors([F.note], ["note": .text("ab")]) == ["note": "At least 3 characters (2 so far)"])
        #expect(errors([F.note], ["note": .text("abcdefghijk")]) == ["note": "At most 10 characters (11 entered)"])
    }

    @Test func countsCharactersAsCodePointsLikeTheServer() {
        // The same cases as answerSchema.test.ts.
        #expect(errors([F.note], ["note": .text("😀😀")]) == ["note": "At least 3 characters (2 so far)"])
        #expect(values([F.note], ["note": .text("😀😀😀")]) == ["note": .string("😀😀😀")])
        #expect(
            errors([F.note], ["note": .text(String(repeating: "😀", count: 11))])
                == ["note": "At most 10 characters (11 entered)"])
        #expect(errors([F.note], ["note": .text("ab\u{0}c")]) == ["note": "Remove the invalid character"])
        #expect(errors([F.note], ["note": .text("\u{0}")]) == ["note": "Remove the invalid character"])
    }

    @Test func stripsTextLikeTheServer() {
        // Python's strip, not JS trim: U+0085 goes, U+FEFF stays.
        #expect(values([F.note], ["note": .text("\u{85}abc\u{1F}")]) == ["note": .string("abc")])
        #expect(values([F.note], ["note": .text("\u{FEFF}ab")]) == ["note": .string("\u{FEFF}ab")])
        #expect(errors([F.mood], ["mood": .text("\u{85}")]) == ["mood": "Required"])
        #expect(values([F.mood], ["mood": .text("\u{1C}good\u{85}")]) == ["mood": .string("good")])
        // Numbers keep the PWA's JS trim.
        #expect(errors([F.hours], ["hours": .text("\u{85}7")]) == ["hours": "Enter a number"])
        #expect(values([F.hours], ["hours": .text("\u{FEFF}7")]) == ["hours": .double(7)])
    }

    @Test func rejectsArchivedAndUnknownOptionsUnlessExplicitlyAllowed() {
        #expect(errors([F.mood], ["mood": .text("awful")]) == ["mood": "That option has been retired"])
        #expect(errors([F.mood], ["mood": .text("nope")]) == ["mood": "Pick one of the options"])
        #expect(values([F.mood], ["mood": .text("awful")], allow: ["mood": ["awful"]]) == ["mood": .string("awful")])
    }

    @Test func parseNumberInputAcceptsCommaDecimalsAndRejectsJunk() {
        #expect(NumberInput.parse("3,25") == 3.25)
        #expect(NumberInput.parse("-.5") == -0.5)
        #expect(NumberInput.parse("1e3") == 1000)
        #expect(NumberInput.parse("1.2.3") == nil)
        #expect(NumberInput.parse("") == nil)
    }

    @Test func roundTripsEntryAnswersIntoFormValues() {
        let answers: [String: AnswerValue] = ["hours": .double(6.5), "mood": .string("awful")]
        #expect(
            AnswerInput.inputs(for: F.all, from: answers)
                == ["hours": .text("6.5"), "wakeups": .text(""), "note": .text(""), "mood": .text("awful")])
        #expect(AnswerInput.archivedValues(in: ["mood": .string("awful")], for: F.all) == ["mood": ["awful"]])
    }

    @Test func choosesChipsForFewOptionsAndAPickerForMany() {
        #expect(!F.mood.usesChoicePicker)
        let many = F.choice(F.mood) { rules in
            rules.options = (0..<7).map { EnumOption(value: "o\($0)", label: "O\($0)") }
        }
        #expect(many.usesChoicePicker)
        // Multi-selects are always chips.
        #expect(!F.choice(many) { $0.multiple = true }.usesChoicePicker)
    }

    @Test func hidesArchivedOptionsExceptTheValueBeingKept() {
        #expect(F.mood.visibleOptions().map(\.value) == ["good", "meh"])
        let kept = F.mood.visibleOptions(keeping: ["awful"])
        #expect(kept.map(\.value) == ["good", "meh", "awful"])
        #expect(kept.last?.label == "Awful (retired)")
    }

    @Test func derivesNumericRules() {
        let hours = F.hours.numericRules
        #expect(hours == NumericRules(isInteger: false, min: 0, max: 24, decimals: 1, unit: "h"))
        #expect(hours?.allowsNegative == false)
        let unbounded = F.with(F.wakeups) { $0.kind = .int(.init()) }.numericRules
        #expect(unbounded?.allowsNegative == true && unbounded?.decimals == 0)
        #expect(F.note.numericRules == nil)
    }

    // MARK: constraints.test.ts, "answer constraints"

    @Test func multiSelectProducesValuesInOptionOrder() {
        #expect(value(F.tags, .selection(["c", "a"])) == .some(.strings(["a", "c"])))
    }

    @Test func multiSelectEnforcesRequiredMinMaxAndArchived() {
        #expect(message(F.tags, .selection([])) == "Pick at least one")
        #expect(message(F.tags, .selection(["a"])) == "Pick at least 2 options")
        #expect(message(F.tags, .selection(["a", "b", "c"])) == "Pick at most 2 options")
        #expect(message(F.tags, .selection(["a", "x"])) == "“X” has been retired")
        #expect(value(F.tags, .selection(["a", "x"]), allow: ["x"]) == .some(.strings(["a", "x"])))
        #expect(message(F.tags, .selection(["a", "zzz"])) == "Pick from the options")
    }

    @Test func emptyOptionalSelectionIsUnanswered() {
        let optional = F.choice(F.with(F.tags) { $0.required = false }) { $0.minSelected = nil }
        #expect(value(optional, .selection([])) == .some(nil))
    }

    @Test func hintsTheSelectionLimits() {
        let tags = F.tags
        #expect(SelectionBounds(tags)?.hint == "Pick 2")
        let upTo3 = F.choice(tags) {
            $0.minSelected = nil
            $0.maxSelected = 3
        }
        #expect(SelectionBounds(upTo3)?.hint == "Pick 1–3")
        #expect(SelectionBounds(F.with(upTo3) { $0.required = false })?.hint == "Pick up to 3")
        let any = F.choice(F.with(upTo3) { $0.required = false }) { $0.maxSelected = nil }
        #expect(SelectionBounds(any)?.hint == "Pick any")
        let atLeast2 = F.choice(tags) { $0.maxSelected = nil }
        #expect(SelectionBounds(atLeast2)?.hint == "Pick at least 2")
        #expect(SelectionBounds(F.mood) == nil)
    }

    // MARK: the rest of the rules, one row per message

    struct Row: Sendable, CustomTestStringConvertible {
        var question: Question
        var input: String
        /// The message, or nil when the input is valid.
        var expected: String?
        var testDescription: String { "\(question.key) \"\(input)\" → \(expected ?? "ok")" }
    }

    static let intQ = Question(key: "n", label: "N", kind: .int(.init(min: 1, max: 600, unit: "min")))
    static let negQ = Question(key: "t", label: "T", kind: .double(.init(min: -10.5, max: 10)))
    static let freeInt = Question(key: "i", label: "I", kind: .int(.init()))
    static let freeDouble = Question(key: "d", label: "D", kind: .double(.init()))
    static let emptyUnit = Question(key: "u", label: "U", kind: .int(.init(min: 0, unit: "")))
    static let text = Question(key: "s", label: "S", kind: .string(.init(minLength: 2, maxLength: 4)))

    static let rows: [Row] = [
        Row(question: intQ, input: "", expected: "Required"),
        Row(question: intQ, input: "   ", expected: "Required"),
        Row(question: intQ, input: "0", expected: "Must be at least 1 min"),
        Row(question: intQ, input: "601", expected: "Must be at most 600 min"),
        Row(question: intQ, input: "1", expected: nil),
        Row(question: intQ, input: " +600 ", expected: nil),
        Row(question: intQ, input: "007", expected: nil),
        Row(question: intQ, input: "1,0", expected: "Enter a whole number"),
        Row(question: intQ, input: "1e2", expected: "Enter a whole number"),
        Row(question: intQ, input: "١٢", expected: "Enter a whole number"),
        Row(question: intQ, input: "--1", expected: "Enter a whole number"),
        Row(question: freeInt, input: "9007199254740991", expected: nil),
        Row(question: freeInt, input: "-9007199254740991", expected: nil),
        Row(question: freeInt, input: "9007199254740992", expected: "Number is too large"),
        Row(question: freeInt, input: "99999999999999999999", expected: "Number is too large"),
        Row(question: freeInt, input: "-5", expected: nil),
        Row(question: emptyUnit, input: "-1", expected: "Must be at least 0"),
        Row(question: negQ, input: "-10,5", expected: nil),
        Row(question: negQ, input: "-10.51", expected: "Must be at least -10.5"),
        Row(question: negQ, input: "10.000001", expected: "Must be at most 10"),
        Row(question: negQ, input: "-.5", expected: nil),
        Row(question: negQ, input: "5.", expected: nil),
        Row(question: negQ, input: ",5", expected: nil),
        Row(question: negQ, input: "1e1", expected: nil),
        Row(question: negQ, input: "1E+1", expected: nil),
        Row(question: negQ, input: "1e", expected: "Enter a number"),
        Row(question: negQ, input: ".", expected: "Enter a number"),
        Row(question: negQ, input: "1.5.", expected: "Enter a number"),
        Row(question: negQ, input: "1 000", expected: "Enter a number"),
        Row(question: negQ, input: "inf", expected: "Enter a number"),
        Row(question: negQ, input: "0x10", expected: "Enter a number"),
        Row(question: freeDouble, input: "1e999", expected: "Enter a number"),
        Row(question: freeDouble, input: "-1e308", expected: nil),
        Row(question: text, input: "a", expected: "At least 2 characters (1 so far)"),
        Row(question: text, input: " ab ", expected: nil),
        Row(question: text, input: "abcde", expected: "At most 4 characters (5 entered)"),
        // Code points, like the server: one emoji is one character (two UTF-16 units in the PWA).
        Row(question: text, input: "😀😀", expected: nil),
        Row(question: text, input: "😀", expected: "At least 2 characters (1 so far)"),
        Row(question: text, input: "a\u{0}b", expected: "Remove the invalid character"),
    ]

    @Test(arguments: rows) func rule(_ row: Row) {
        #expect(message(row.question, .text(row.input)) == row.expected)
    }

    @Test func numbersComeOutTyped() {
        #expect(value(Self.intQ, .text(" +600 ")) == .some(.int(600)))
        #expect(value(Self.negQ, .text("-10,5")) == .some(.double(-10.5)))
        #expect(value(Self.freeInt, .text("-0")) == .some(.int(0)))
        #expect(value(Self.text, .text(" ab ")) == .some(.string("ab")))
    }

    @Test func boundsBeyondDoublePrecisionCompareAsDoubles() {
        // 2^53 + 1 rounds to 2^53 in JS, so 2^53 - 1 is below it and nothing whole is above it.
        let huge = Question(key: "h", label: "H", kind: .int(.init(min: 9_007_199_254_740_993)))
        #expect(message(huge, .text("9007199254740991")) == "Must be at least 9007199254740992")
    }

    @Test func choiceInputsOfTheOtherShape() {
        // A single-select reads the first picked value; a multi-select takes typed text as one pick.
        #expect(value(F.mood, .selection(["meh", "good"])) == .some(.string("meh")))
        #expect(value(F.mood, .selection([])) == nil)
        #expect(value(F.tags, .text("a")) == nil)
        #expect(message(F.tags, .text("a")) == "Pick at least 2 options")
        // Duplicates and blanks are dropped before the limits apply.
        #expect(value(F.tags, .selection(["b", " a ", "b", ""])) == .some(.strings(["a", "b"])))
        #expect(message(F.mood, .text(" ")) == "Required")
        #expect(message(F.with(F.mood) { $0.required = false }, .text(" ")) == nil)
    }

    @Test func missingInputsCountAsBlank() {
        #expect(errors(F.all, [:]) == ["hours": "Required", "mood": "Required"])
        let failure = AnswerValidator(questions: F.all).validate([:])
        guard case .failure(let errors) = failure else {
            Issue.record("expected errors")
            return
        }
        #expect(errors.first?.key == "hours")
        #expect(
            errors.errors.map(\.issue.location) == [
                [.key("answers"), .key("hours")], [.key("answers"), .key("mood")],
            ])
    }

    @Test func blankAndHasValue() {
        #expect(AnswerInput.empty(for: F.tags) == .selection([]))
        #expect(AnswerInput.empty(for: F.hours) == .text(""))
        #expect(!AnswerInput.text(" \u{FEFF}\u{3000}").hasValue)
        #expect(AnswerInput.text("0").hasValue)
        #expect(AnswerInput.selection(["a"]).hasValue)
    }

    @Test func inputsFromStoredValues() {
        #expect(AnswerInput(.string("b"), for: F.tags) == .selection(["b"]))
        #expect(AnswerInput(.string(""), for: F.tags) == .selection([]))
        #expect(AnswerInput(.int(3), for: F.tags) == .selection([]))
        #expect(AnswerInput(.strings(["a", "b"]), for: F.mood) == .text("a"))
        #expect(AnswerInput(.double(1e21), for: F.hours) == .text("1e+21"))
        #expect(AnswerInput(.double(7), for: F.hours) == .text("7"))
        #expect(AnswerInput(nil, for: F.hours) == .text(""))
        #expect(
            AnswerInput.archivedValues(
                in: ["tags": .strings(["a", "x"]), "hours": .double(1)], for: [F.tags, F.hours])
                == ["tags": ["x"]])
    }
}
