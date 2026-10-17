import Foundation
import QuickrCore
import QuickrUI
import Testing

/// The design loop's Workout topic: a chip question, two numbers (one optional) and a note.
private let workout: [Question] = [
    Question(
        key: "type", label: "Type",
        kind: .choice(
            .init(options: [
                EnumOption(value: "run", label: "Run"), EnumOption(value: "strength", label: "Strength"),
                EnumOption(value: "yoga", label: "Yoga"), EnumOption(value: "old", label: "Old", archived: true),
            ]))),
    Question(key: "duration", label: "Duration", kind: .int(.init(min: 1, max: 600, unit: "min"))),
    Question(
        key: "distance", label: "Distance", required: false, kind: .double(.init(min: 0, decimals: 1, unit: "km"))),
    Question(key: "note", label: "Note", required: false, kind: .string(.init(maxLength: 20))),
]

private let factors = Question(
    key: "factors", label: "Factors",
    kind: .choice(
        .init(
            options: [
                EnumOption(value: "sleep", label: "Sleep"), EnumOption(value: "stress", label: "Stress"),
                EnumOption(value: "food", label: "Food"), EnumOption(value: "gone", label: "Gone", archived: true),
            ], multiple: true, minSelected: 2, maxSelected: 3)))

private let severity = Question(
    key: "severity", label: "Severity",
    kind: .choice(.init(options: [EnumOption(value: "mild", label: "Mild"), EnumOption(value: "bad", label: "Bad")])))

private let monday = Date(timeIntervalSince1970: 1_760_000_000)

@MainActor @Suite struct FormModelTests {
    // MARK: Validation on touch

    @Test func errorsWaitUntilAFieldIsLeftThenFollowEveryChange() {
        let model = FormModel(questions: workout)
        model.focusChanged("duration", isFocused: true)
        model.change("duration", to: .text("0"))
        #expect(model.errors["duration"] == nil)
        model.focusChanged("duration", isFocused: false)
        #expect(model.errors["duration"] == "Must be at least 1 min")
        model.change("duration", to: .text("45"))
        #expect(model.errors["duration"] == nil)
        model.change("duration", to: .text("4x"))
        #expect(model.errors["duration"] == "Enter a whole number")
    }

    @Test func aChoiceIsTouchedWhenAnotherQuestionIsUsed() {
        let model = FormModel(questions: [factors, workout[1]])
        model.change("factors", to: .selection(["sleep"]))
        #expect(model.errors["factors"] == nil)
        model.focusChanged("duration", isFocused: true)
        #expect(model.errors["factors"] == "Pick at least 2 options")
        model.change("factors", to: .selection(["sleep", "food"]))
        #expect(model.errors["factors"] == nil)
    }

    @Test func textCountsCodePointsAndShowsTheCounterNearTheLimit() {
        let model = FormModel(questions: workout)
        model.change("note", to: .text("short"))
        #expect(model.characterCount(for: "note") == nil)
        model.change("note", to: .text(String(repeating: "👍", count: 16)))
        #expect(model.characterCount(for: "note") == CharacterCount(count: 16, max: 20))
        model.change("note", to: .text(String(repeating: "👍", count: 21)))
        model.focusChanged("note", isFocused: false)
        #expect(model.characterCount(for: "note")?.isOver == true)
        #expect(model.errors["note"] == "At most 20 characters (21 entered)")
        #expect(model.characterCount(for: "duration") == nil)
    }

    // MARK: Focus

    @Test func appearFocusesTheFirstEmptyTypedFieldButOnlyScrollsToChips() {
        let typed = FormModel(questions: Array(workout.dropFirst()))
        typed.appear()
        #expect(typed.focus == "duration")
        #expect(typed.scrollRequest?.target == .question("duration"))

        let chipsFirst = FormModel(questions: workout)
        chipsFirst.appear()
        #expect(chipsFirst.focus == nil)
        #expect(chipsFirst.scrollRequest?.target == .question("type"))
    }

    @Test func aPickMovesFocusToTheNextEmptyTypedField() {
        let model = FormModel(questions: workout)
        model.change("duration", to: .text("30"))
        model.change("type", to: .text("run"))
        #expect(model.focus == "distance")

        // Nothing typed is left: the keyboard goes away.
        let done = FormModel(questions: [workout[1], workout[0]])
        done.focusChanged("duration", isFocused: true)
        done.change("type", to: .text("run"))
        #expect(done.focus == nil)
    }

    @Test func aPickInEditModeLeavesFocusAlone() {
        let model = FormModel(questions: workout, mode: .edit(answers: ["type": .string("run"), "duration": .int(5)]))
        model.focusChanged("note", isFocused: true)
        model.change("type", to: .text("yoga"))
        #expect(model.focus == "note")
    }

    @Test func nextSkipsAnsweredFieldsAndChoicesAndNeverSubmits() {
        let model = FormModel(questions: [workout[1], workout[0], workout[2], workout[3]])
        model.change("distance", to: .text("5"))
        #expect(model.nextField(after: "duration") == "note")
        model.advance(from: "duration")
        #expect(model.focus == "note")
        model.advance(from: "note")
        #expect(model.focus == nil)
        #expect(model.touched.isEmpty)
    }

    // MARK: Same as last time

    @Test func sameAsLastFillsAndTogglesBack() throws {
        let last = LastEntry(
            answers: ["type": .string("run"), "duration": .int(45), "distance": .double(5.2)], capturedAt: monday)
        let model = FormModel(questions: workout, mode: .create(last: last))
        let prefill = try #require(model.prefill)
        #expect(prefill.summary == "Run · 45 min · 5.2 km")
        #expect(model.showsSameAsLast)

        model.change("note", to: .text("typed first"))
        model.toggleSameAsLast()
        #expect(model.isSameAsLastApplied)
        #expect(model.input(for: "duration") == .text("45"))
        #expect(model.input(for: "type") == .text("run"))
        #expect(model.input(for: "note") == .text(""))
        #expect(model.submit() == .create(["type": .string("run"), "duration": .int(45), "distance": .double(5.2)]))

        model.toggleSameAsLast()
        #expect(!model.isSameAsLastApplied)
        #expect(model.input(for: "note") == .text("typed first"))
        #expect(model.input(for: "duration") == .text(""))
        #expect(model.errors.isEmpty)
        #expect(model.showsSameAsLast)
    }

    @Test func sameAsLastClearsErrorsOnFieldsItBlanks() {
        let last = LastEntry(answers: ["type": .string("run"), "duration": .int(45)], capturedAt: monday)
        let model = FormModel(questions: workout, mode: .create(last: last))
        model.change("distance", to: .text("far"))
        model.focusChanged("distance", isFocused: false)
        #expect(model.errors["distance"] == "Enter a number")
        model.toggleSameAsLast()
        #expect(model.input(for: "distance") == .text(""))
        #expect(model.errors["distance"] == nil)
        // An untouched blank required field stays quiet until it is left or saved.
        #expect(model.errors["note"] == nil)
        #expect(model.errors["duration"] == nil)
    }

    @Test func sameAsLastDropsWhatIsNoLongerValid() throws {
        let last = LastEntry(answers: ["type": .string("old"), "duration": .int(9999)], capturedAt: monday)
        #expect(FormModel(questions: workout, mode: .create(last: last)).prefill == nil)

        let partly = LastEntry(answers: ["type": .string("old"), "duration": .int(20)], capturedAt: monday)
        let prefill = try #require(FormModel(questions: workout, mode: .create(last: partly)).prefill)
        #expect(prefill.inputs["type"] == .text(""))
        #expect(prefill.summary == "20 min")
    }

    @Test func aSingleNumberTopicStartsFromTheLastValueAndHidesSameAsLast() {
        let glasses = Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20)))
        let last = LastEntry(answers: ["glasses": .int(3)], capturedAt: monday)
        let model = FormModel(questions: [glasses], mode: .create(last: last))
        #expect(model.input(for: "glasses") == .text("3"))
        #expect(model.prefill != nil)
        #expect(!model.showsSameAsLast)
        #expect(model.autoSaveKey == nil)

        // No last entry: the minimum, like the tile.
        #expect(FormModel(questions: [glasses]).input(for: "glasses") == .text("0"))
    }

    // MARK: Auto-save

    @Test func aSingleChipTopicSavesOnPick() {
        let last = LastEntry(answers: ["severity": .string("mild")], capturedAt: monday)
        let model = FormModel(questions: [severity], mode: .create(last: last))
        #expect(model.autoSaveKey == "severity")
        #expect(!model.showsSameAsLast)
        #expect(model.change("severity", to: .text("bad")) == .create(["severity": .string("bad")]))

        // Not in fix mode, and not when the topic has another question.
        let fix = FormModel(questions: [severity], mode: .fix(answers: [:], problem: nil))
        #expect(fix.autoSaveKey == nil)
        #expect(fix.change("severity", to: .text("bad")) == nil)
        #expect(FormModel(questions: [severity, workout[3]]).autoSaveKey == nil)
    }

    @Test func anAutoSaveInFlightIgnoresFurtherTaps() {
        let model = FormModel(questions: [severity])
        #expect(model.change("severity", to: .text("mild")) == .create(["severity": .string("mild")]))
        #expect(model.isAutoSaving)
        // Rapid taps, on the same chip or another, start nothing and change nothing.
        #expect(model.change("severity", to: .text("mild")) == nil)
        #expect(model.change("severity", to: .text("bad")) == nil)
        #expect(model.input(for: "severity") == .text("mild"))

        model.autoSaveFinished(succeeded: true)
        #expect(!model.isAutoSaving)
        // The saved answer again logs nothing; another answer is a new entry.
        #expect(model.change("severity", to: .text("mild")) == nil)
        #expect(!model.isAutoSaving)
        #expect(model.change("severity", to: .text("bad")) == .create(["severity": .string("bad")]))
    }

    @Test func aFailedAutoSaveCanBeRetriedWithTheSameTap() {
        let model = FormModel(questions: [severity])
        #expect(model.change("severity", to: .text("bad")) != nil)
        model.autoSaveFinished(succeeded: false)
        #expect(!model.isAutoSaving)
        #expect(model.input(for: "severity") == .text("bad"))
        #expect(model.change("severity", to: .text("bad")) == .create(["severity": .string("bad")]))
        // A stray completion while idle changes nothing.
        model.autoSaveFinished(succeeded: true)
        model.autoSaveFinished(succeeded: true)
        #expect(!model.isAutoSaving)
    }

    // MARK: Initial focus

    @Test func initialFocusRunsOnceAndNeverAfterTheUserActs() {
        let typed = Array(workout.dropFirst())
        // The user focused a later field before the delayed appear.
        let tapped = FormModel(questions: typed)
        tapped.focusChanged("note", isFocused: true)
        tapped.appear()
        #expect(tapped.focus == "note")
        #expect(tapped.scrollRequest == nil)

        // Typing first (a hardware keyboard, say) also counts.
        let typedFirst = FormModel(questions: typed)
        typedFirst.change("distance", to: .text("3"))
        typedFirst.appear()
        #expect(typedFirst.focus == nil)

        // Disappearing and coming back doesn't redo it.
        let model = FormModel(questions: typed)
        model.appear()
        #expect(model.focus == "duration")
        model.focusChanged("duration", isFocused: true)  // the view applying it isn't the user
        model.dismissKeyboard()
        model.appear()
        #expect(model.focus == nil)
    }

    @Test func fixModeRevealsItsErrorOnlyOnce() {
        let problem = Problem(
            code: .invalidAnswers, detail: "",
            errors: [FieldIssue(location: [.key("answers"), .key("duration")], message: "Too long")])
        let model = FormModel(questions: workout, mode: .fix(answers: [:], problem: problem))
        model.appear()
        let first = model.scrollRequest
        model.appear()
        #expect(model.scrollRequest == first)
    }

    // MARK: Bodies

    @Test func createOmitsBlankOptionalAnswersAndEditClearsThem() {
        let create = FormModel(questions: workout)
        create.change("type", to: .text("yoga"))
        create.change("duration", to: .text(" 30 "))
        #expect(create.submit() == .create(["type": .string("yoga"), "duration": .int(30)]))

        let edit = FormModel(
            questions: workout,
            mode: .edit(answers: ["type": .string("run"), "duration": .int(30), "distance": .int(5)]))
        #expect(edit.input(for: "distance") == .text("5"))
        edit.change("distance", to: .text(""))
        #expect(
            edit.submit()
                == .update(["type": .string("run"), "duration": .int(30), "distance": nil, "note": nil]))
    }

    @Test func aFailedSubmitShowsEveryErrorAndFocusesTheFirstTypedOne() {
        let model = FormModel(questions: [workout[1], workout[0]])
        #expect(model.submit() == nil)
        #expect(model.errors == ["duration": "Required", "type": "Required"])
        #expect(model.focus == "duration")
        #expect(model.scrollRequest?.target == .question("duration"))

        // A choice first: scrolled to, not focused; a second submit scrolls again.
        let chips = FormModel(questions: workout)
        chips.focusChanged("note", isFocused: true)
        _ = chips.submit()
        let first = chips.scrollRequest
        #expect(chips.focus == nil)
        #expect(first?.target == .question("type"))
        _ = chips.submit()
        #expect(chips.scrollRequest?.target == first?.target)
        #expect(chips.scrollRequest != first)
    }

    // MARK: Retired options

    @Test func retiredOptionsShowAndStayValidOnlyWhenEditingAnEntryThatHoldsThem() {
        let create = FormModel(questions: [factors])
        #expect(create.options(for: factors).map(\.value) == ["sleep", "stress", "food"])

        let edit = FormModel(questions: [factors], mode: .edit(answers: ["factors": .strings(["sleep", "gone"])]))
        #expect(edit.options(for: factors).map(\.label) == ["Sleep", "Stress", "Food", "Gone (retired)"])
        #expect(edit.submit() == .update(["factors": .strings(["sleep", "gone"])]))

        let fix = FormModel(
            questions: [factors], mode: .fix(answers: ["factors": .strings(["sleep", "gone"])], problem: nil))
        #expect(fix.options(for: factors).count == 3)
        #expect(fix.submit() == nil)
        #expect(fix.errors["factors"] == "“Gone” has been retired")
    }

    // MARK: Fix mode

    @Test func fixModePutsServerErrorsOnFieldsMetaAndBanner() {
        let problem = Problem(
            code: .invalidAnswers, detail: "Some answers need attention",
            errors: [
                FieldIssue(
                    location: [.key("body"), .key("answers"), .key("duration")], message: "Must be at most 600 min"),
                FieldIssue(location: [.key("body"), .key("source")], message: "Value error, too long"),
                FieldIssue(location: [.key("body"), .key("answers"), .key("ghost")], message: "Unknown question"),
            ])
        let model = FormModel(
            questions: workout,
            mode: .fix(answers: ["type": .string("run"), "duration": .int(601)], problem: problem))
        #expect(model.input(for: "duration") == .text("601"))
        #expect(model.errors == ["duration": "Must be at most 600 min"])
        #expect(model.metaErrors == [.source: "Too long"])
        #expect(model.banner?.message == "Some answers need attention")
        #expect(model.banner?.unplaced.map { ProblemMapping.path($0.location) } == ["answers.ghost"])

        model.appear()
        #expect(model.focus == "duration")
        #expect(model.scrollRequest?.target == .question("duration"))

        // Already touched: fixing the value clears the server's error at once.
        model.change("duration", to: .text("60"))
        #expect(model.errors.isEmpty)
        #expect(model.submit() == .create(["type": .string("run"), "duration": .int(60)]))
        #expect(model.banner == nil)
        #expect(model.metaErrors.isEmpty)
    }

    @Test func aProblemWithoutFieldsScrollsToTheBanner() {
        let model = FormModel(questions: workout)
        model.apply(Problem(code: .topicArchived, detail: ""))
        #expect(model.banner?.message == "This topic is archived")
        #expect(model.scrollRequest?.target == .banner)
        #expect(model.focus == nil)
    }
}
