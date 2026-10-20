import Foundation
import QuickrCore
import Testing

/// The editing behaviour the PWA keeps in its builder components (QuestionsEditor, QuestionCard,
/// OptionsEditor, TopicMetaFields), plus what iOS adds (duplicate, change type).
@Suite struct TopicDraftEditingTests {
    static let published = Question(
        key: "mood", label: "Mood",
        kind: .choice(
            .init(options: [EnumOption(value: "good", label: "Good"), EnumOption(value: "bad", label: "Bad")])))

    @Test func emptyTopicHasOneNumberQuestion() {
        let t = TopicDraft.empty()
        #expect(t.questions.map(\.type) == [.int])
        #expect(!t.canRemoveQuestion)
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
        var t = TopicDraft.empty()
        t.setName("Sleep Log")
        #expect(t.slug == "sleep-log")
        t.setSlug("zzz")
        t.setName("Other")
        #expect(t.slug == "zzz")
        #expect(TopicDraft.editing(name: "A", slug: "a", description: "", questions: []).slugEdited)
    }

    @Test func labelsDeriveUniqueKeysUntilEditedOrPublished() {
        var t = TopicDraft.empty()
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
        var t = TopicDraft.empty()
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
        #expect(!r5, "the last question stays")
        #expect(t.questions.map(\.id) == [c])
    }

    @Test func canAddQuestionUpToTheLimit() {
        var limits = Limits.serverDefaults
        limits.maxQuestions = 2
        var t = TopicDraft.empty()
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
        var t = TopicDraft.empty()
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
        var t = TopicDraft.empty()
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
        var t = TopicDraft.empty()
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
