import Foundation
import QuickrCore
import Testing

/// Drafts with a valid key and label, like the PWA tests' `draft(type, patch)`.
func draft(_ type: QuestionType, _ patch: (inout DraftQuestion) -> Void = { _ in }) -> DraftQuestion {
    var d = DraftQuestion(type: type)
    d.key = "q"
    d.label = "Q"
    patch(&d)
    return d
}

/// `issuesOf`: path → message, a later issue replacing an earlier one (`Object.fromEntries`).
func issuesOf(_ d: DraftQuestion, _ limits: Limits = .serverDefaults) -> [String: String] {
    switch d.validated(limits: limits) {
    case .success: [:]
    case .failure(let e): Dictionary(e.issues.map { ($0.field.path, $0.message) }, uniquingKeysWith: { $1 })
    }
}

func options(_ labels: String...) -> [DraftOption] {
    labels.enumerated().map { i, label in
        var o = DraftOption(label: label)
        if o.value.isEmpty { o.value = "o\(i)" }
        return o
    }
}

func paths<T>(_ result: Result<T, DraftIssues<DraftField>>) -> [String] {
    if case .failure(let e) = result { e.issues.map(\.field.path) } else { [] }
}

/// frontend/src/lib/builder.test.ts, case for case.
@Suite struct BuilderTests {
    // MARK: naming helpers

    @Test func toSnakeKeyProducesValidKeys() {
        #expect(BuilderText.snakeKey("Hours slept (approx.)") == "hours_slept_approx")
        #expect(BuilderText.snakeKey("  Café au lait! ") == "cafe_au_lait")
        #expect(BuilderText.snakeKey("2nd try") == "nd_try")
        #expect(BuilderText.snakeKey("!!!") == "")
        #expect(BuilderText.snakeKey(String(repeating: "x", count: 100)).count == 63)
    }

    @Test func slugifyMirrorsTheBackend() {
        #expect(BuilderText.slug("Sleep Log — 2026") == "sleep-log-2026")
        #expect(BuilderText.slug("  --Hello__World-- ") == "hello-world")
    }

    @Test func uniqueKeyAppendsACounter() {
        #expect(BuilderText.uniqueKey("mood", taken: []) == "mood")
        #expect(BuilderText.uniqueKey("mood", taken: ["mood", "mood_2"]) == "mood_3")
        #expect(BuilderText.uniqueKey("", taken: []) == "question")
    }

    @Test func withLabelDerivesTheKeyUntilItIsEditedOrLocked() {
        let q = DraftQuestion(type: .int)
        #expect(q.withLabel("Glasses of water", takenKeys: []).key == "glasses_of_water")
        #expect(q.withLabel("Mood", takenKeys: ["mood"]).key == "mood_2")
        var edited = q
        edited.key = "custom"
        edited.keyEdited = true
        #expect(edited.withLabel("Other", takenKeys: []).key == "custom")
        var locked = q
        locked.key = "fixed"
        locked.locked = true
        #expect(locked.withLabel("Other", takenKeys: []).key == "fixed")
    }

    @Test func newDraftOptionDerivesAUniqueValue() {
        #expect(DraftOption(label: "Very good", taken: ["very_good"]).value == "very_good_2")
    }

    // MARK: convertDraftQuestion

    @Test func convertsNumericDrafts() throws {
        let d = draft(.double) {
            $0.min = "0"
            $0.max = "24,5"
            $0.unit = " h "
            $0.decimals = "1"
            $0.helpText = ""
        }
        let q = try d.validated().get()
        #expect(
            q
                == Question(
                    key: "q", label: "Q", helpText: nil, required: true,
                    kind: .double(.init(min: 0, max: 24.5, decimals: 1, unit: "h"))))
    }

    @Test func requiresMinLeMaxAndIntegerBoundsForInt() {
        #expect(
            issuesOf(
                draft(.int) {
                    $0.min = "5"
                    $0.max = "1"
                }) == ["max": "Max must be ≥ min"])
        #expect(issuesOf(draft(.int) { $0.min = "1.5" }) == ["min": "Must be a whole number"])
        #expect(issuesOf(draft(.double) { $0.decimals = "11" }) == ["decimals": "Must be at most 10"])
    }

    @Test func validatesKeyFormatAndLabelPresence() {
        #expect(
            issuesOf(
                draft(.int) {
                    $0.key = "Bad Key"
                    $0.label = " "
                }) == [
                    "key": "Use lower_snake_case: a–z, 0–9, _ (start with a letter, max 63)", "label": "Required",
                ])
    }

    @Test func validatesStringLengths() {
        #expect(
            issuesOf(
                draft(.str) {
                    $0.minLength = "10"
                    $0.maxLength = "5"
                }) == [
                    "max_length": "Max length must be ≥ min length"
                ])
        #expect(issuesOf(draft(.str) { $0.maxLength = "0" }) == ["max_length": "Must be at least 1"])
    }

    @Test func requiresAtLeastOneActiveUniquelyValuedEnumOption() {
        var a = DraftOption(label: "A")
        a.archived = true
        #expect(issuesOf(draft(.enum) { $0.options = [a] }) == ["options": "At least one option must be active"])
        #expect(issuesOf(draft(.enum) { $0.options = [] }) == ["options": "Add at least one option"])
        a.archived = false
        #expect(
            issuesOf(draft(.enum) { $0.options = [a, DraftOption(label: "A")] }) == [
                "options.1.value": "Another option has this value",
                "options.1.label": "Another option has this label",
            ])
    }

    // MARK: topicDraftSchema

    @Test func outputsATopicCreateBody() throws {
        let topic = TopicDraft(name: " Sleep ", questions: [draft(.int) { $0.key = "hours" }])
        let body = try topic.validatedForCreation().get()
        #expect(body.name == "Sleep")
        #expect(body.slug == nil)
        #expect(body.description == "")
        #expect(body.questions.first?.key == "hours")
        #expect(body.questions.first?.type == .int)
    }

    @Test func reportsDuplicateKeysBadSlugsAndEmptyQuestionListsAtFieldPaths() {
        let dup = TopicDraft(
            name: "x", slug: "Bad Slug", slugEdited: true,
            questions: [draft(.int) { $0.key = "a" }, draft(.str) { $0.key = "a" }])
        let dupPaths = paths(dup.validatedForCreation())
        #expect(dupPaths.contains("slug"))
        #expect(dupPaths.contains("questions.1.key"))

        let none = TopicDraft(questions: [])
        #expect(paths(none.validatedForCreation()) == ["name", "questions"])
    }

    @Test func versionDraftValidatesQuestionsAndNote() throws {
        let topic = TopicDraft(name: "x", slug: "x", slugEdited: true, questions: [draft(.int)], changeNote: " hi ")
        let version = try topic.validatedForVersion().get()
        #expect(version.changeNote == "hi")
    }

    // MARK: draftFromQuestion / previewQuestion

    static let published = Question(
        key: "mood", label: "Mood", helpText: "How was it?", required: false,
        kind: .choice(
            .init(options: [
                EnumOption(value: "good", label: "Good"), EnumOption(value: "bad", label: "Bad", archived: true),
            ])))

    @Test func roundTripsAPublishedQuestion() throws {
        let d = DraftQuestion(question: Self.published, locked: true)
        #expect(d.locked)
        #expect(d.options.allSatisfy { $0.locked })
        let question = try d.validated().get()
        #expect(question == Self.published)
    }

    @Test func previewsIncompleteDraftsWithPlaceholders() {
        let p = DraftQuestion(type: .int).preview(index: 2)
        #expect(p.key == "question_3")
        #expect(p.label == "Question 3")
        #expect(p.type == .int)
        let broken = draft(.int) {
            $0.min = "9"
            $0.max = "1"
        }.preview(index: 0)
        #expect(broken.kind == .int(.init(min: nil, max: nil)))
    }
}

/// The builder cases of frontend/src/lib/constraints.test.ts ("question constraints",
/// "multi-select constraints", "question list + topic constraints", "server error locations").
@Suite struct BuilderConstraintTests {
    let limits = Limits.serverDefaults

    @Test func boundsLabelHelpTextAndUnitLengthsWithTheServerLimits() {
        var tight = limits
        tight.maxLabelLength = 5
        tight.maxHelpTextLength = 3
        tight.maxUnitLength = 2
        let d = draft(.int) {
            $0.label = "Too long"
            $0.helpText = "abcd"
            $0.unit = "kgs"
        }
        #expect(
            issuesOf(d, tight) == [
                "label": "At most 5 characters (8 now)", "help_text": "At most 3 characters (4 now)",
                "unit": "At most 2 characters (3 now)",
            ])
    }

    @Test func countsLabelLengthsInCodePoints() {
        var tight = limits
        tight.maxLabelLength = 2
        #expect(issuesOf(draft(.int) { $0.label = "😀😀" }, tight) == [:])
        #expect(issuesOf(draft(.int) { $0.label = "😀😀😀" }, tight) == ["label": "At most 2 characters (3 now)"])
    }

    @Test func usesTheServerKeyPattern() {
        #expect(issuesOf(draft(.int) { $0.key = String(repeating: "a", count: 64) })["key"] != nil)
        #expect(issuesOf(draft(.int) { $0.key = String(repeating: "a", count: 63) }) == [:])
    }

    @Test func checksDecimalsAndIntegerBounds() {
        #expect(issuesOf(draft(.double) { $0.decimals = "11" }) == ["decimals": "Must be at most 10"])
        #expect(issuesOf(draft(.double) { $0.decimals = "-1" }) == ["decimals": "Must be at least 0"])
        #expect(issuesOf(draft(.int) { $0.min = "1.5" }) == ["min": "Must be a whole number"])
        #expect(issuesOf(draft(.int) { $0.max = "99999999999999999999" }) == ["max": "Number is too large"])
        #expect(
            issuesOf(
                draft(.double) {
                    $0.min = "2"
                    $0.max = "1"
                }) == ["max": "Max must be ≥ min"])
    }

    @Test func boundsStringLengthsByMaxStrLength() {
        #expect(issuesOf(draft(.str) { $0.maxLength = "10001" }) == ["max_length": "Must be at most 10000"])
    }

    @Test func requiresUniqueOptionValuesAndCaseInsensitiveUniqueOptionLabels() {
        let a = DraftOption(label: "Good")
        var b = DraftOption(label: "good")
        b.value = "other"
        #expect(issuesOf(draft(.enum) { $0.options = [a, b] }) == ["options.1.label": "Another option has this label"])
        b.label = "Fine"
        b.value = a.value
        #expect(issuesOf(draft(.enum) { $0.options = [a, b] }) == ["options.1.value": "Another option has this value"])
        var bad = a
        bad.value = "Bad value"
        #expect(issuesOf(draft(.enum) { $0.options = [bad] })["options.0.value"] != nil)
    }

    @Test func capsTheNumberOfOptions() {
        var two = limits
        two.maxEnumOptions = 2
        #expect(issuesOf(draft(.enum) { $0.options = options("A", "B", "C") }, two) == ["options": "At most 2 options"])
    }

    // MARK: multi-select

    @Test func acceptsOneLeMinLeMaxLeActiveOptions() throws {
        let q = try draft(.enum) {
            $0.options = options("A", "B", "C")
            $0.multiple = true
            $0.minSelected = "1"
            $0.maxSelected = "3"
        }.validated().get()
        guard case .choice(let rules) = q.kind else { throw Unexpected() }
        #expect(rules.multiple && rules.minSelected == 1 && rules.maxSelected == 3)
    }

    @Test func rejectsMinGtMaxZeroAndLimitsAboveTheActiveOptions() {
        let three = options("A", "B", "C")
        #expect(
            issuesOf(
                draft(.enum) {
                    $0.options = three
                    $0.multiple = true
                    $0.minSelected = "3"
                    $0.maxSelected = "2"
                }) == ["max_selected": "Max must be ≥ min"])
        #expect(
            issuesOf(
                draft(.enum) {
                    $0.options = three
                    $0.multiple = true
                    $0.minSelected = "0"
                }) == ["min_selected": "Must be at least 1"])
        var archived = three
        archived[0].archived = true
        #expect(
            issuesOf(
                draft(.enum) {
                    $0.options = archived
                    $0.multiple = true
                    $0.maxSelected = "3"
                }) == ["max_selected": "Only 2 active options"])
    }

    @Test func dropsSelectionLimitsOnSingleSelectQuestions() throws {
        let q = try draft(.enum) {
            $0.options = options("A", "B", "C")
            $0.minSelected = "2"
        }.validated().get()
        guard case .choice(let rules) = q.kind else { throw Unexpected() }
        #expect(!rules.multiple && rules.minSelected == nil && rules.maxSelected == nil)
    }

    @Test func blocksMultiToSingleForAPublishedQuestionButAllowsSingleToMulti() {
        let published = Question(
            key: "tags", label: "Tags",
            kind: .choice(.init(options: [EnumOption(value: "a", label: "A")], multiple: true)))
        var d = DraftQuestion(question: published, locked: true)
        #expect(d.publishedMultiple)
        d.multiple = false
        #expect(issuesOf(d)["multiple"] != nil)
        var singleQuestion = published
        singleQuestion.kind = .choice(.init(options: [EnumOption(value: "a", label: "A")]))
        var single = DraftQuestion(question: singleQuestion, locked: true)
        single.multiple = true
        #expect(issuesOf(single) == [:])
    }

    // MARK: question list + topic

    @Test func flagsDuplicateKeysAndCaseInsensitiveDuplicateLabelsOnTheLaterQuestion() {
        let issues = TopicDraft.questionListIssues([("a", "Mood"), ("a", " mood ")])
        #expect(
            issues == [
                DraftIssue(field: .question(1, .key), message: "Key already used by another question"),
                DraftIssue(field: .question(1, .label), message: "Another question has this label"),
            ])
    }

    @Test func capsTheQuestionCount() {
        var one = limits
        one.maxQuestions = 1
        #expect(
            TopicDraft.questionListIssues([("a", "A"), ("b", "B")], limits: one) == [
                DraftIssue(field: .questions, message: "At most 1 questions")
            ])
    }

    @Test func validatesNameSlugDescriptionAgainstTheLimits() {
        var tight = limits
        tight.maxTopicNameLength = 3
        tight.maxDescriptionLength = 2
        let topic = TopicDraft(name: "Long name", slug: "-bad", description: "abc", questions: [draft(.int)])
        let found = paths(topic.validatedForCreation(limits: tight))
        #expect(Set(["name", "slug", "description"]).isSubset(of: found))
        var three = limits
        three.maxTopicNameLength = 3
        let emoji = TopicDraft(name: "😀😀😀", questions: [draft(.int)])
        #expect(!paths(emoji.validatedForCreation(limits: three)).contains("name"))
        let meta = TopicDraft(name: "x", slug: String(repeating: "a", count: 65), questions: [])
        #expect(paths(meta.validatedDetails()) == ["slug"])
    }

    // MARK: server error locations

    static let fiveEnums: TopicDraft = {
        var t = TopicDraft.empty()
        t.questions = (0..<5).map { _ in
            var q = DraftQuestion(type: .enum)
            q.options = options("A", "B")
            return q
        }
        return t
    }()

    @Test func landsEveryPreciseLocOnItsBuilderField() {
        typealias P = FieldIssue.PathComponent
        func field(_ loc: [P]) -> String? {
            BuilderProblemMapping.field(for: ProblemMapping.path(loc), in: Self.fiveEnums)?.path
        }
        #expect(field([.key("body"), .key("questions"), .index(4), .key("key")]) == "questions.4.key")
        #expect(
            field([.key("body"), .key("questions"), .index(2), .key("options"), .index(1), .key("value")])
                == "questions.2.options.1.value")
        #expect(
            field([.key("body"), .key("questions"), .index(2), .key("options"), .index(1), .key("label")])
                == "questions.2.options.1.label")
        #expect(
            field([.key("body"), .key("questions"), .index(1), .key("max_selected")]) == "questions.1.max_selected")
        #expect(field([.key("body"), .key("name")]) == "name")
    }
}

struct Unexpected: Error {}
