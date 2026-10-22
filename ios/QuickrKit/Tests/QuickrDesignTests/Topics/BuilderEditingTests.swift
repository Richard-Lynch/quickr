import Foundation
import QuickrCore
import QuickrUI
import Testing

/// The builder's shared state: which cards are open, the live preview, and the Versions tab's rows.
@MainActor @Suite struct BuilderEditingTests {
    static func questions(_ n: Int) -> [DraftQuestion] { (0..<n).map { _ in DraftQuestion(type: .int) } }

    // MARK: Expansion

    @Test func creatingStartsOpenEditingClosed() {
        let qs = Self.questions(2)
        #expect(QuestionExpansion(.all, questions: qs).allOpen(qs))
        #expect(QuestionExpansion(.none, questions: qs).open.isEmpty)
    }

    @Test func toggleAllFollowsTheCurrentQuestions() {
        var qs = Self.questions(3)
        var expansion = QuestionExpansion(.none, questions: qs)
        expansion.toggle(qs[0].id)
        #expect(expansion.isOpen(qs[0].id) && !expansion.isOpen(qs[1].id))
        #expect(QuestionExpansion.toggleAllTitle(allOpen: expansion.allOpen(qs)) == "Expand all")
        expansion.toggleAll(qs)
        #expect(expansion.allOpen(qs))
        #expect(QuestionExpansion.toggleAllTitle(allOpen: expansion.allOpen(qs)) == "Collapse all")
        // A removed question doesn't count; an added one that is closed does.
        qs.removeLast()
        #expect(expansion.allOpen(qs))
        qs.append(DraftQuestion(type: .str))
        #expect(!expansion.allOpen(qs))
        expansion.toggleAll(qs)
        #expect(expansion.allOpen(qs), "not everything open: Expand all opens everything")
        expansion.toggleAll(qs)
        #expect(expansion.open.isEmpty)
    }

    @Test func anErrorKeepsACardOpen() {
        let qs = Self.questions(1)
        var expansion = QuestionExpansion(.all, questions: qs)
        expansion.toggle(qs[0].id)
        #expect(!expansion.isOpen(qs[0].id))
        #expect(expansion.isOpen(qs[0].id, hasError: true))
    }

    @Test func errorsAreFoundByQuestion() {
        let errors: [DraftField: String] = [.name: "x", .question(1, .optionLabel(0)): "y"]
        #expect(errors.hasError(inQuestion: 1))
        #expect(!errors.hasError(inQuestion: 0))
    }

    @Test func addingAQuestionOpensItUpToTheLimit() {
        let model = NewTopicModel(writer: FakeTopicWriter(server: TopicSettingsModelTests.topic), toasts: ToastCenter())
        model.addQuestion(.int)
        model.expansion.toggleAll(model.draft.questions)
        #expect(model.expansion.open.isEmpty)
        model.addQuestion(.enum)
        #expect(model.draft.questions.count == 2)
        #expect(model.isOpen(model.draft.questions[1].id))
        #expect(!model.isOpen(model.draft.questions[0].id))
        while model.draft.canAddQuestion(limits: model.limits) { model.addQuestion(.int) }
        let count = model.draft.questions.count
        model.addQuestion(.int)
        #expect(model.draft.questions.count == count, "no more than max_questions")
    }

    @Test func aRemovedQuestionsOptionTextIsNotAChange() {
        let model = NewTopicModel(writer: FakeTopicWriter(server: TopicSettingsModelTests.topic), toasts: ToastCenter())
        model.addQuestion(.int)
        model.addQuestion(.enum)
        let choice = model.draft.questions[1].id
        model.newOptionLabels[choice] = "Maybe"
        #expect(model.hasPendingOptionText)
        _ = model.draft.removeQuestion(choice)
        #expect(!model.hasPendingOptionText, "its question is gone")
    }

    // MARK: Preview

    @Test func previewQuestionsAreTheDraftsBestEffort() {
        var draft = TopicDraft(questions: [DraftQuestion(type: .int), DraftQuestion(type: .enum)])
        draft.setLabel(draft.questions[0].id, "Steps")
        let questions = BuilderPreview.questions(draft)
        #expect(questions.map(\.key) == ["steps", "question_2"])
        #expect(questions.map(\.label) == ["Steps", "Question 2"])
    }

    @Test func previewErrorsShowOnceLeft() {
        let preview = BuilderPreview()
        let q = Question(key: "steps", label: "Steps", kind: .int(.init(min: 1, max: 10)))
        preview.set(.text("40"), for: q)
        #expect(preview.error(for: q) == nil, "not left yet")
        preview.leave(q)
        #expect(preview.error(for: q) != nil)
        preview.set(.text("4"), for: q)
        #expect(preview.error(for: q) == nil)
        let required = Question(key: "mood", label: "Mood", kind: .int(.init()))
        preview.leave(required)
        #expect(preview.error(for: required) == "Required")
    }

    @Test func previewAnswersFollowTheKeyButNotAChangedShape() {
        let preview = BuilderPreview()
        let number = Question(key: "x", label: "X", kind: .int(.init()))
        preview.set(.text("3"), for: number)
        let renamedLabel = Question(key: "x", label: "Renamed", kind: .int(.init()))
        #expect(preview.input(for: renamedLabel) == .text("3"))
        let multi = Question(
            key: "x", label: "X", kind: .choice(.init(options: [.init(value: "a", label: "A")], multiple: true)))
        #expect(preview.input(for: multi) == .selection([]), "a number's text doesn't fit a multi-select")
        preview.set(.selection(["a"]), for: multi)
        #expect(preview.input(for: multi) == .selection(["a"]))
        let single = Question(key: "x", label: "X", kind: .choice(.init(options: [.init(value: "a", label: "A")])))
        #expect(preview.input(for: single) == .text(""), "a selection doesn't fit a single-select")
        preview.reset()
        #expect(preview.input(for: number) == .text(""))
    }

    // MARK: Versions

    static func version(_ n: Int, note: String = "", entries: Int = 0) -> TopicVersion {
        TopicVersion(
            version: n, questions: [], changeNote: note, createdAt: Date(timeIntervalSince1970: Double(n)),
            entryCount: entries)
    }

    @Test func versionsNewestFirstWithTheCurrentOneMarked() {
        let list = VersionsList(
            versions: [Self.version(1, note: "Initial version", entries: 1), Self.version(2, entries: 12)],
            currentVersion: 2)
        #expect(list.rows.map(\.version) == [2, 1])
        #expect(list.rows.map(\.isCurrent) == [true, false])
        #expect(list.rows[0].note == nil && list.rows[0].placeholder == "No change note")
        #expect(list.rows[1].note == "Initial version")
        #expect(list.rows[0].entries(locale: Locale(identifier: "en_US")) == "12 entries")
        #expect(list.rows[1].entries(locale: Locale(identifier: "en_US")) == "1 entry")
        #expect(list.pending == nil)
    }

    @Test func aJustPublishedVersionIsPendingUntilItsRowArrives() {
        let list = VersionsList(versions: [Self.version(1)], currentVersion: 2)
        #expect(list.pending == 2)
        #expect(list.rows.map(\.isCurrent) == [false])
        #expect(list.rows[0].placeholder == "Initial version")
    }
}
