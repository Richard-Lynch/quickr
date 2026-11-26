import Foundation
import QuickrCore
import Testing

/// The editing behaviour the PWA keeps in its builder components (QuestionsEditor, QuestionCard,
/// OptionsEditor, TopicMetaFields), plus what iOS adds (duplicate, change type).
@Suite struct TopicDraftEditingTests {
    /// A draft with one number question, as a new topic used to start (most editing tests).
    static func oneNumber() -> TopicDraft { TopicDraft(questions: [DraftQuestion(type: .int)]) }

    static let published = Question(
        key: "mood", label: "Mood",
        kind: .choice(
            .init(options: [EnumOption(value: "good", label: "Good"), EnumOption(value: "bad", label: "Bad")])))

    /// SINGLE: a new topic starts with no questions (it would log in one tap), and every question
    /// can be removed, the last one too.
    @Test func aNewTopicStartsWithNoQuestionsAndTheLastCanBeRemoved() throws {
        var t = TopicDraft.empty()
        #expect(t.questions.isEmpty)
        #expect(!t.canRemoveQuestion)
        #expect(try t.validatedQuestions().get().isEmpty)
        let q = t.addQuestion(.int)
        #expect(t.canRemoveQuestion)
        let removed = t.removeQuestion(q)
        #expect(removed)
        #expect(t.questions.isEmpty)
        let again = t.removeQuestion(q)
        #expect(!again, "already gone")
    }

    @Test func newQuestionDefaults() {
        let e = DraftQuestion(type: .enum)
        #expect(e.options.map(\.value) == ["yes", "no"])
        #expect(e.required)
        #expect(DraftQuestion(type: .double).decimals == "1")
        #expect(DraftQuestion(type: .str).minLength == "0")
        #expect(DraftQuestion(type: .str).maxLength == "500")
    }

    @Test func slugFollowsTheNameUntilEdited() {
        var t = Self.oneNumber()
        t.setName("Sleep Log")
        #expect(t.slug == "sleep-log")
        t.setSlug("zzz")
        t.setName("Other")
        #expect(t.slug == "zzz")
        #expect(TopicDraft.editing(name: "A", slug: "a", description: "", questions: []).slugEdited)
    }

    @Test func labelsDeriveUniqueKeysUntilEditedOrPublished() {
        var t = Self.oneNumber()
        let first = t.questions[0].id
        t.setLabel(first, "Mood")
        let second = t.addQuestion(.str)
        t.setLabel(second, "Mood")
        #expect(t[second]?.key == "mood_2")
        let r1 = t.setKey(second, "feeling")
        #expect(r1)
        t.setLabel(second, "Feeling today")
        #expect(t[second]?.key == "feeling")
        t.setLabel(first, "  ")
        #expect(t[first]?.key == "")

        var edit = TopicDraft.editing(name: "T", slug: "t", description: "", questions: [Self.published])
        let id = edit.questions[0].id
        let r2 = edit.setKey(id, "other")
        #expect(!r2)
        edit.setLabel(id, "How do you feel?")
        #expect(edit[id]?.key == "mood")
        #expect(edit[id]?.label == "How do you feel?")
    }

    @Test func addRemoveAndMoveQuestions() {
        var t = Self.oneNumber()
        let a = t.questions[0].id
        let b = t.addQuestion(.str)
        let c = t.addQuestion(.enum)
        t.moveQuestion(c, to: 0)
        #expect(t.questions.map(\.id) == [c, a, b])
        t.moveQuestions(fromOffsets: [0], toOffset: 3)
        #expect(t.questions.map(\.id) == [a, b, c])
        t.moveQuestions(fromOffsets: [2], toOffset: 0)
        #expect(t.questions.map(\.id) == [c, a, b])
        let r3 = t.removeQuestion(a)
        #expect(r3)
        let r4 = t.removeQuestion(b)
        #expect(r4)
        let r5 = t.removeQuestion(c)
        #expect(r5, "the last question goes too (a single topic)")
        #expect(t.questions.isEmpty)
    }

    @Test func canAddQuestionUpToTheLimit() {
        var limits = Limits.serverDefaults
        limits.maxQuestions = 2
        var t = Self.oneNumber()
        #expect(t.canAddQuestion(limits: limits))
        t.addQuestion(.int)
        #expect(!t.canAddQuestion(limits: limits))
    }

    @Test func duplicateMakesAnUnpublishedCopyWithAUniqueLabelAndKey() throws {
        var t = TopicDraft.editing(name: "T", slug: "t", description: "", questions: [Self.published])
        let id = t.questions[0].id
        let copyResult = t.duplicateQuestion(id)
        let copy = try #require(copyResult)
        let againResult = t.duplicateQuestion(id)
        let again = try #require(againResult)
        #expect(t.questions.map(\.id) == [id, again, copy])
        let q = try #require(t[copy])
        #expect(q.label == "Mood (copy)")
        #expect(q.key == "mood_copy")
        #expect(!q.locked && !q.keyEdited && !q.publishedMultiple)
        #expect(q.options.map(\.value) == ["good", "bad"])
        #expect(q.options.allSatisfy { !$0.locked })
        #expect(Set(q.options.map(\.id)).isDisjoint(with: t.questions[0].options.map(\.id)))
        #expect(t[again]?.label == "Mood (copy 2)")
        #expect(t[again]?.key == "mood_copy_2")
        #expect(throws: Never.self) { try t.validatedQuestions().get() }
    }

    @Test func typeChangesOnlyBeforePublishing() {
        var t = TopicDraft.editing(name: "T", slug: "t", description: "", questions: [Self.published])
        let r6 = t.setType(t.questions[0].id, to: .str)
        #expect(!r6)
        #expect(t.questions[0].type == .enum)

        let n = t.addQuestion(.int)
        t.setLabel(n, "Weight")
        if let i = t.index(of: n) {
            t.questions[i].min = "1"
            t.questions[i].unit = "kg"
        }
        let r7 = t.setType(n, to: .double)
        #expect(r7)
        #expect(t[n]?.type == .double)
        #expect(t[n]?.min == "1")
        #expect(t[n]?.unit == "kg")
        #expect(t[n]?.decimals == "1")
        #expect(t[n]?.key == "weight")
        let r8 = t.setType(n, to: .enum)
        #expect(r8)
        #expect(t[n]?.min == "")
        #expect(t[n]?.options.map(\.value) == ["yes", "no"])
    }

    /// A fractional bound survives the switch to whole numbers and is flagged, never truncated.
    @Test func fractionalDoubleBecomingIntIsFlagged() throws {
        var t = Self.oneNumber()
        t.setLabel(t.questions[0].id, "Mood")
        let n = t.addQuestion(.double)
        t.setLabel(n, "Hours")
        let i = try #require(t.index(of: n))
        t.questions[i].min = "0.5"
        t.questions[i].max = "7.25"
        let switched = t.setType(n, to: .int)
        #expect(switched)
        #expect(t.questions[i].min == "0.5")
        #expect(t.questions[i].max == "7.25")
        let issues = DraftIssues<DraftField>.fields(of: t.validatedQuestions())
        #expect(issues == ["questions.1.min": "Must be a whole number", "questions.1.max": "Must be a whole number"])
        t.questions[i].min = "0"
        t.questions[i].max = "7"
        let fixed = try t.validatedQuestions().get()
        #expect(fixed[1].kind == .int(.init(min: 0, max: 7)))
    }

    @Test func optionsAddRenameAndDeriveValues() throws {
        var t = Self.oneNumber()
        let q = t.addQuestion(.enum)
        let r9 = t.addOption(to: q, label: "   ")
        #expect(r9 == nil)
        let r10 = t.addOption(to: t.questions[0].id, label: "A")
        #expect(r10 == nil, "not a choice")
        let oResult = t.addOption(to: q, label: " Very good ")
        let o = try #require(oResult)
        #expect(t[q]?.options.last?.label == "Very good")
        #expect(t[q]?.options.last?.value == "very_good")
        let o2Result = t.addOption(to: q, label: "Very good!")
        let o2 = try #require(o2Result)
        #expect(t[q]?.options.last?.value == "very_good_2")
        t.setOptionLabel(q, option: o, "Great")
        #expect(t[q]?.options.first { $0.id == o }?.value == "great")
        t.setOptionLabel(q, option: o, "")
        #expect(t[q]?.options.first { $0.id == o }?.value == "option")
        let r11 = t.setOptionValue(q, option: o2, "vg")
        #expect(r11)
        t.setOptionLabel(q, option: o2, "Superb")
        #expect(t[q]?.options.first { $0.id == o2 }?.value == "vg")
    }

    @Test func publishedOptionsAreRetiredNotRemoved() throws {
        var t = TopicDraft.editing(name: "T", slug: "t", description: "", questions: [Self.published])
        let q = t.questions[0].id
        let good = t.questions[0].options[0].id
        let r12 = t.removeOption(q, option: good)
        #expect(!r12)
        let r13 = t.setOptionValue(q, option: good, "fine")
        #expect(!r13)
        t.setOptionLabel(q, option: good, "Fine")
        #expect(t.questions[0].options[0].value == "good")
        #expect(t.questions[0].options[0].label == "Fine")
        t.setOptionArchived(q, option: good, true)
        #expect(t.questions[0].options[0].archived)
        t.setOptionArchived(q, option: good, false)
        #expect(!t.questions[0].options[0].archived)

        let freshResult = t.addOption(to: q, label: "Meh")

        let fresh = try #require(freshResult)
        t.moveOption(q, option: fresh, to: 0)
        #expect(t.questions[0].options.map(\.value) == ["meh", "good", "bad"])
        t.moveOptions(q, fromOffsets: [0], toOffset: 3)
        #expect(t.questions[0].options.map(\.value) == ["good", "bad", "meh"])
        let r14 = t.removeOption(q, option: fresh)
        #expect(r14)
        #expect(t.questions[0].options.map(\.value) == ["good", "bad"])
    }

    @Test func publishedMultiSelectCantGoBack() {
        var multi = Self.published
        multi.kind = .choice(.init(options: [EnumOption(value: "a", label: "A")], multiple: true))
        var t = TopicDraft.editing(name: "T", slug: "t", description: "", questions: [multi])
        let q = t.questions[0].id
        let r15 = t.setMultiple(q, false)
        #expect(!r15)
        #expect(t.questions[0].multiple)
        let fresh = t.addQuestion(.enum)
        let r16 = t.setMultiple(fresh, true)
        #expect(r16)
        let r17 = t.setMultiple(fresh, false)
        #expect(r17)
    }

    @Test func editingRoundTripsEveryType() throws {
        let questions = [
            Question(key: "n", label: "N", helpText: "h", kind: .int(.init(min: -3, max: 9, unit: "x"))),
            Question(key: "d", label: "D", required: false, kind: .double(.init(min: 0.1, max: 1e20, decimals: 2))),
            Question(key: "s", label: "S", kind: .string(.init(minLength: 2, maxLength: 40, multiline: true))),
            Question(
                key: "e", label: "E",
                kind: .choice(
                    .init(
                        options: [EnumOption(value: "a", label: "A"), EnumOption(value: "b", label: "B")],
                        multiple: true,
                        minSelected: 1, maxSelected: 2))),
        ]
        let t = TopicDraft.editing(name: "T", slug: "t", description: "", questions: questions)
        #expect(t.questions[1].max == "100000000000000000000")  // JS String(1e20), like the PWA
        #expect(try t.validatedQuestions().get() == questions)
    }

    @Test func serverErrorsLandOnFieldsOrTheBanner() {
        var t = Self.oneNumber()
        t.addQuestion(.enum)
        let problem = Problem(
            code: .invalidRequest, detail: "request validation failed",
            errors: [
                .init(
                    location: [.key("body"), .key("questions"), .index(1), .key("options"), .index(0), .key("label")],
                    message: "dup"),
                .init(location: [.key("body"), .key("questions"), .index(0), .key("required")], message: "bool"),
                .init(location: [.key("body"), .key("questions"), .index(7), .key("key")], message: "gone"),
                .init(location: [.key("body"), .key("schedule"), .key("timezone")], message: "tz"),
                .init(location: [.key("body"), .key("base_version")], message: "stale"),
            ])
        let mapped = BuilderProblemMapping.builderForm(problem, draft: t)
        #expect(mapped.banner == "Some fields need attention")
        #expect(
            mapped.fields == [
                .question(1, .optionLabel(0)): "Dup", .question(0, .key): "Bool", .questions: "Gone",
            ])
        #expect(mapped.unplaced.map(\.message) == ["Tz", "Stale"])
    }
}

extension DraftIssues<DraftField> {
    static func fields<T>(of result: Result<T, Self>) -> [String: String] {
        guard case .failure(let e) = result else { return [:] }
        return Dictionary(e.issues.map { ($0.field.path, $0.message) }, uniquingKeysWith: { $1 })
    }
}

/// Timer v2 in the builder (timers2.md §1.1, §1.3, §1.6): lap types, variables and alerts, keyed
/// in one namespace with the steps, validated at the server's paths and published normalised.
@Suite struct TimerDraftEditingTests {
    static let base = TopicTimer(
        steps: [.init(key: "warm", label: "Warm up")],
        laps: [
            .init(key: "run", label: "Run", alerts: [.init(key: "half", label: "Half", at: "t/2", atMs: 30_000)]),
            .init(key: "rest", label: "Rest"),
        ],
        variables: [.init(name: "t", ms: 60_000)])

    @Test func aPublishedTimerOpensLockedWithItsVariablesAsText() {
        let opened = TopicDraft.timerDraft(from: Self.base)
        #expect(opened.timed)
        #expect(opened.laps.map(\.key) == ["run", "rest"])
        let lapsLocked = opened.laps.allSatisfy(\.locked)
        #expect(lapsLocked)
        #expect(opened.laps[0].alerts.map(\.key) == ["half"])
        let alertsLocked = opened.laps[0].alerts.allSatisfy(\.locked)
        #expect(alertsLocked)
        #expect(opened.variables.map(\.name) == ["t"])
        #expect(opened.variables.map(\.duration) == ["1:00"])
        let draft = TopicDraft.editing(name: "Run", slug: "run", description: "", questions: [], timer: Self.base)
        #expect(draft.laps.map(\.key) == ["run", "rest"])
        #expect(draft.variables.count == 1)
    }

    @Test func lapTypeKeysAvoidStepsAndBothHistories() {
        var draft = TopicDraft(questions: [], timed: true, steps: [DraftStep(key: "run", label: "Run")])
        let history = TimerHistory(
            steps: [HistoricStep(key: "prep", label: "Prep")], laps: [HistoricStep(key: "jog", label: "Jog")])
        let id = draft.addLapType()
        draft.setLapTypeLabel(id, "Run", history: history)
        #expect(draft.laps[0].key == "run_2", "a step has run")
        draft.setLapTypeLabel(id, "Prep", history: history)
        #expect(draft.laps[0].key == "prep_2", "a retired step's key is never a lap type's")
        draft.setLapTypeLabel(id, " JOG ", history: history)
        #expect(draft.laps[0].key == "jog", "a retired lap type takes its key back")
    }

    @Test func stepKeysAvoidLapTypesAndTheirHistory() {
        var draft = TopicDraft(questions: [], timed: true, laps: [DraftLapType(key: "rest", label: "Rest")])
        let history = TimerHistory(steps: [], laps: [HistoricStep(key: "cig", label: "Cig")])
        let id = draft.addStep()
        draft.setStepLabel(id, "Rest", history: history)
        #expect(draft.steps[0].key == "rest_2")
        draft.setStepLabel(id, "Cig", history: history)
        #expect(draft.steps[0].key == "cig_2", "never a retired lap type's key")
    }

    @Test func aPublishedLapTypeKeepsItsKeyWhenRenamed() {
        var draft = TopicDraft.editing(name: "Run", slug: "run", description: "", questions: [], timer: Self.base)
        draft.setLapTypeLabel(draft.laps[0].id, "Jog")
        #expect(draft.laps[0].key == "run")
        #expect(draft.laps[0].label == "Jog")
    }

    @Test func lapTypesMoveAndRemoveUpToTheLimit() {
        var draft = TopicDraft(questions: [], timed: true)
        for _ in 0..<Limits.serverDefaults.maxLapTypes { draft.addLapType() }
        #expect(!draft.canAddLapType())
        draft.laps = [DraftLapType(key: "a", label: "A"), DraftLapType(key: "b", label: "B")]
        draft.moveLapType(draft.laps[1].id, to: 0)
        #expect(draft.laps.map(\.key) == ["b", "a"])
        draft.removeLapType(draft.laps[0].id)
        #expect(draft.laps.map(\.key) == ["a"])
        #expect(draft.canAddLapType())
    }

    @Test func variableNamesAreLowercasedOnEntry() {
        var draft = TopicDraft(questions: [], timed: true)
        let id = draft.addVariable()
        draft.setVariableName(id, "Rest")
        draft.setVariableDuration(id, "0:30")
        #expect(draft.variables[0].name == "rest")
        #expect(draft.variables[0].duration == "0:30")
        draft.removeVariable(id)
        #expect(draft.variables.isEmpty)
    }

    @Test func durationTextRoundTrips() {
        #expect(DurationText.parse("1:00") == 60_000)
        #expect(DurationText.parse(" 1:30:00 ") == 5_400_000)
        #expect(DurationText.parse("0:01.5") == 1_500)
        #expect(DurationText.parse("90") == nil)
        #expect(DurationText.parse("1:60") == nil)
        #expect(DurationText.format(90_500) == "1:30.500")
        #expect(DurationText.format(5_400_000) == "1:30:00")
    }

    @Test func alertsOnStepsAndLapTypesKeyWithinTheirOwner() throws {
        var draft = TopicDraft(
            questions: [], timed: true, steps: [DraftStep(key: "warm", label: "Warm")],
            laps: [DraftLapType(key: "run", label: "Run")])
        let step = TimerItemID.step(draft.steps[0].id)
        let lap = TimerItemID.lapType(draft.laps[0].id)
        let aAdded = draft.addAlert(to: lap)
        let a = try #require(aAdded)
        draft.setAlertLabel(lap, a, "Half")
        draft.setAlertAt(lap, a, "t/2")
        let bAdded = draft.addAlert(to: lap)
        let b = try #require(bAdded)
        draft.setAlertLabel(lap, b, "half")
        let cAdded = draft.addAlert(to: step)
        let c = try #require(cAdded)
        draft.setAlertLabel(step, c, "Half")
        #expect(draft.laps[0].alerts.map(\.key) == ["half", "half_2"])
        #expect(draft.steps[0].alerts.map(\.key) == ["half"], "alert keys are unique within their owner only")
        draft.removeAlert(lap, b)
        #expect(draft.laps[0].alerts.map(\.key) == ["half"])
        #expect(draft.laps[0].alerts[0].at == "t/2")
    }

    @Test func anAlertPreviewEvaluatesWithTheDraftsVariables() {
        let vars = [DraftVariable(name: "t", duration: "1:00")]
        #expect(TopicDraft.alertPreview("t/2", variables: vars) == .value(ms: 30_000, text: "0:30"))
        #expect(
            TopicDraft.alertPreview("t+", variables: vars) == .error(message: "Syntax at 2: unexpected end", pos: 2))
        #expect(
            TopicDraft.alertPreview("x", variables: vars)
                == .error(message: "Unknown_variable at 0: unknown variable 'x'", pos: 0))
    }

    /// The expression length is `GET /limits`' `max_expr_length`, as the PWA's evaluator takes
    /// it (Codex review).
    @Test func theExpressionLengthLimitIsTheServers() {
        var limits = Limits.serverDefaults
        limits.maxExprLength = 10
        let vars = [DraftVariable(name: "t", duration: "1:00")]
        #expect(
            TopicDraft.alertPreview("t+t+t+t+t+t", variables: vars, limits: limits)
                == .error(message: "Too_long at 10: longer than 10 characters", pos: 10))
        #expect(
            TopicDraft.alertPreview("t+t+t+t+t", variables: vars, limits: limits) == .value(ms: 300_000, text: "5:00"))
        let draft = TopicDraft(
            questions: [], timed: true,
            laps: [
                DraftLapType(key: "run", label: "Run", alerts: [DraftAlert(key: "a", label: "A", at: "t+t+t+t+t+t")])
            ],
            variables: vars)
        #expect(draft.timerIssues(limits: limits).map(\.field) == [.alert(.lap(0), 0, .at)])
    }

    /// I1-BUILDER acceptance: a duplicate key across steps and lap types is refused before
    /// sending, at the server's path (`timer.laps.0.key` is the draft's `laps.0.key`).
    @Test func aKeySharedByAStepAndALapTypeIsRefusedAtTheServersPath() {
        let draft = TopicDraft(
            questions: [], timed: true, steps: [DraftStep(key: "run", label: "Run")],
            laps: [DraftLapType(key: "run", label: "Run")])
        guard case .failure(let issues) = draft.validatedForVersion() else {
            Issue.record("a shared key must not validate")
            return
        }
        #expect(issues.issues.map(\.field) == [.lap(0, .key)])
        #expect(issues.issues.map(\.field.path) == ["laps.0.key"])
        #expect(issues.issues.map(\.message) == ["A step has this key"])
        #expect(BuilderProblemMapping.field(for: "timer.laps.0.key", in: draft) == .lap(0, .key))
    }

    @Test func serverTimerPathsLandOnTheirFields() {
        var draft = TopicDraft.editing(name: "Run", slug: "run", description: "", questions: [], timer: Self.base)
        #expect(BuilderProblemMapping.field(for: "timer.laps", in: draft) == .laps)
        #expect(BuilderProblemMapping.field(for: "timer.laps.1.label", in: draft) == .lap(1, .label))
        #expect(BuilderProblemMapping.field(for: "timer.laps.5.key", in: draft) == .laps)
        #expect(BuilderProblemMapping.field(for: "timer.variables", in: draft) == .variables)
        #expect(BuilderProblemMapping.field(for: "timer.variables.0.ms", in: draft) == .variable(0, .duration))
        #expect(BuilderProblemMapping.field(for: "timer.variables.0.name", in: draft) == .variable(0, .name))
        #expect(BuilderProblemMapping.field(for: "timer.variables.3.ms", in: draft) == .variables)
        #expect(
            BuilderProblemMapping.field(for: "timer.laps.0.alerts.0.at", in: draft) == .alert(.lap(0), 0, .at))
        #expect(
            BuilderProblemMapping.field(for: "timer.laps.0.alerts.0.at_ms", in: draft) == .alert(.lap(0), 0, .at))
        #expect(BuilderProblemMapping.field(for: "timer.laps.0.alerts.4.key", in: draft) == .alerts(.lap(0)))
        #expect(BuilderProblemMapping.field(for: "timer.steps.0.alerts", in: draft) == .alerts(.step(0)))
        #expect(BuilderProblemMapping.field(for: "timer.steps.0.key", in: draft) == .step(0, .key))
        draft.timed = false
        #expect(BuilderProblemMapping.field(for: "timer.laps.0.key", in: draft) == nil)
    }

    @Test func publishingSendsTheNormalisedTimer() throws {
        var draft = TopicDraft.editing(name: "Run", slug: "run", description: "", questions: [], timer: Self.base)
        let id = draft.addVariable()
        draft.setVariableName(id, "Rest")
        draft.setVariableDuration(id, "0:30")
        let rest = TimerItemID.lapType(draft.laps[1].id)
        let alertAdded = draft.addAlert(to: rest)
        let alert = try #require(alertAdded)
        draft.setAlertLabel(rest, alert, " Up ")
        draft.setAlertAt(rest, alert, "rest - 10s")
        let timer = try draft.validatedForVersion().get().timer
        #expect(
            timer
                == TopicTimer(
                    steps: [.init(key: "warm", label: "Warm up")],
                    laps: [
                        .init(
                            key: "run", label: "Run",
                            alerts: [.init(key: "half", label: "Half", at: "t/2", atMs: 30_000)]),
                        .init(
                            key: "rest", label: "Rest",
                            alerts: [.init(key: "up", label: "Up", at: "rest - 10s", atMs: 20_000)]),
                    ],
                    variables: [.init(name: "t", ms: 60_000), .init(name: "rest", ms: 30_000)]))
    }

    @Test func notTimedPublishesNoTimerWhateverTheLists() throws {
        var draft = TopicDraft.editing(name: "Run", slug: "run", description: "", questions: [], timer: Self.base)
        draft.laps.append(DraftLapType(key: "", label: ""))
        draft.timed = false
        #expect(try draft.validatedForVersion().get().timer == nil)
    }
}
