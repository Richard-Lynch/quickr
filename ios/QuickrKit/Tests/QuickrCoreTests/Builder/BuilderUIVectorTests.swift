import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/builder-ui-vectors.json`, from the PWA's own `builder.ts` and
/// `questionSummary.ts`: a new question's draft, the draft a published question opens as, the
/// live preview's question, and the versions list's constraint line (en-US).
@Suite struct BuilderUIVectorTests {
    @Test func hasCases() {
        #expect(BuilderUIVectors.shared.newQuestion.count == 4)
        #expect(BuilderUIVectors.shared.fromQuestion.count >= 20)
        #expect(BuilderUIVectors.shared.preview.count >= 25)
        #expect(BuilderUIVectors.shared.constraintText.count >= 10)
        #expect(BuilderUIVectors.shared.newStep.count >= 10)
        #expect(BuilderUIVectors.shared.fromTimer.count == 3)
        #expect(BuilderUIVectors.shared.stepLabel.count >= 8)
        #expect(BuilderUIVectors.shared.timerOutput.count >= 10)
        #expect(BuilderUIVectors.shared.timerChanges.count >= 9)
    }

    // MARK: Timed topics (timers.md §2.1)

    @Test(arguments: BuilderUIVectors.shared.newStep)
    func newStep(_ vector: BuilderUIVectors.NewStepCase) {
        let step = DraftStep(label: vector.label, taken: vector.taken, history: vector.historic)
        #expect(PlainStep(step) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.fromTimer)
    func fromTimer(_ vector: BuilderUIVectors.FromTimerCase) {
        let (timed, steps) = TopicDraft.steps(from: vector.timer)
        #expect(timed == vector.expected.timed)
        #expect(steps.map(PlainStep.init) == vector.expected.steps)
    }

    @Test(arguments: BuilderUIVectors.shared.stepLabel)
    func stepLabel(_ vector: BuilderUIVectors.StepLabelCase) {
        let step = vector.step.model.withLabel(vector.label, takenKeys: vector.taken, history: vector.historic)
        #expect(PlainStep(step) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.timerOutput)
    func timerOutput(_ vector: BuilderUIVectors.TimerOutputCase) {
        let draft = TopicDraft(questions: [], timed: vector.timed, steps: vector.steps.map(\.model))
        switch draft.validatedTimer() {
        case .success(let timer):
            #expect(timer == vector.expected.timer)
            #expect(vector.expected.issues.isEmpty)
        case .failure(let issues):
            let got = issues.issues.map { BuilderUIVectors.Issue($0) }
            #expect(got == vector.expected.issues)
            #expect(vector.expected.timer == nil)
        }
    }

    @Test(arguments: BuilderUIVectors.shared.timerChanges)
    func timerChanges(_ vector: BuilderUIVectors.TimerChangesCase) {
        #expect(TimerChanges.changes(base: vector.base, next: vector.next) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.newQuestion)
    func newQuestion(_ vector: BuilderUIVectors.NewQuestionCase) {
        #expect(PlainDraft(DraftQuestion(type: vector.type)) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.fromQuestion)
    func fromQuestion(_ vector: BuilderUIVectors.FromQuestionCase) {
        #expect(PlainDraft(DraftQuestion(question: vector.question.question, locked: vector.locked)) == vector.expected)
    }

    @Test(arguments: BuilderUIVectors.shared.preview)
    func preview(_ vector: BuilderUIVectors.PreviewCase) {
        #expect(vector.draft.model.preview(index: vector.index) == vector.expected.question)
    }

    @Test(arguments: BuilderUIVectors.shared.constraintText)
    func constraintText(_ vector: BuilderUIVectors.ConstraintCase) {
        #expect(
            QuestionSummary.constraint(vector.question.question, locale: Locale(identifier: "en_US")) == vector.expected
        )
    }
}

struct BuilderUIVectors: Decodable {
    static let shared: BuilderUIVectors = {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(BuilderUIVectors.self, from: Fixtures.data("builder-ui-vectors.json"))
        } catch {
            fatalError("builder-ui-vectors.json: \(error)")
        }
    }()

    var newQuestion: [NewQuestionCase]
    var fromQuestion: [FromQuestionCase]
    var preview: [PreviewCase]
    var constraintText: [ConstraintCase]
    var newStep: [NewStepCase]
    var fromTimer: [FromTimerCase]
    var stepLabel: [StepLabelCase]
    var timerOutput: [TimerOutputCase]
    var timerChanges: [TimerChangesCase]

    struct Historic: Decodable, Sendable {
        var key, label: String
    }

    struct NewStepCase: Decodable, Sendable, CustomTestStringConvertible {
        var label: String
        var taken: [String]
        var history: [Historic]
        var expected: PlainStep
        var historic: [HistoricStep] { history.map { HistoricStep(key: $0.key, label: $0.label) } }
        var testDescription: String { "'\(label)' taken \(taken) history \(history.count)" }
    }

    struct FromTimerCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Sendable {
            var timed: Bool
            var steps: [PlainStep]
        }
        var timer: TopicTimer?
        var expected: Expected
        var testDescription: String { timer.map { "\($0.steps.count) steps" } ?? "null" }
    }

    struct StepLabelCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var step: PlainStep
        var label: String
        var taken: [String]
        var history: [Historic]
        var expected: PlainStep
        var historic: [HistoricStep] { history.map { HistoricStep(key: $0.key, label: $0.label) } }
        var testDescription: String { name }
    }

    /// An issue as the vectors spell it: a path relative to the step list (`[0, "label"]`, or
    /// `[]` for the list) and the message.
    struct Issue: Decodable, Sendable, Equatable {
        var path: [String]
        var message: String

        init(_ issue: DraftIssue<DraftField>) {
            switch issue.field {
            case .step(let i, let field): path = [String(i), field.rawValue]
            default: path = []
            }
            message = issue.message
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decode(String.self, forKey: .message)
            var parts = try c.nestedUnkeyedContainer(forKey: .path)
            path = []
            while !parts.isAtEnd {
                if let i = try? parts.decode(Int.self) {
                    path.append(String(i))
                } else {
                    path.append(try parts.decode(String.self))
                }
            }
        }

        enum CodingKeys: String, CodingKey { case path, message }
    }

    struct TimerOutputCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Sendable {
            var timer: TopicTimer?
            var issues: [Issue]
        }
        var name: String
        var timed: Bool
        var steps: [PlainStep]
        var expected: Expected
        var testDescription: String { name }
    }

    struct TimerChangesCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var base: TopicTimer?
        var next: TopicTimer?
        var expected: [String]
        var testDescription: String { name }
    }

    struct NewQuestionCase: Decodable, Sendable, CustomTestStringConvertible {
        var type: QuestionType
        var expected: PlainDraft
        var testDescription: String { type.rawValue }
    }

    struct FromQuestionCase: Decodable, Sendable, CustomTestStringConvertible {
        var question: QuestionJSON
        var locked: Bool
        var expected: PlainDraft
        var testDescription: String { "\(question.question.key) locked: \(locked)" }
    }

    struct PreviewCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var index: Int
        var draft: PlainDraft
        var expected: QuestionJSON
        var testDescription: String { name }
    }

    struct ConstraintCase: Decodable, Sendable, CustomTestStringConvertible {
        var question: QuestionJSON
        var expected: String
        var testDescription: String { "\(question.question.key): \(expected)" }
    }
}

/// A draft step without its id (the PWA's `DraftStep` without `uid`).
struct PlainStep: Decodable, Sendable, Equatable {
    var key, label: String
    var locked: Bool

    init(_ s: DraftStep) {
        key = s.key
        label = s.label
        locked = s.locked
    }

    var model: DraftStep { DraftStep(key: key, label: label, locked: locked) }
}

/// A draft without its ids, in the vectors' spelling (the PWA's `DraftQuestion` fields).
struct PlainDraft: Decodable, Sendable, Equatable, CustomStringConvertible {
    var type: QuestionType
    var key, label, helpText: String
    var required, keyEdited, locked: Bool
    var min, max, unit, decimals, minLength, maxLength: String
    var multiline: Bool
    var options: [Option]
    var multiple: Bool
    var minSelected, maxSelected: String
    var publishedMultiple: Bool

    struct Option: Decodable, Sendable, Equatable {
        var value, label: String
        var archived, valueEdited, locked: Bool
    }

    init(_ d: DraftQuestion) {
        type = d.type
        key = d.key
        label = d.label
        helpText = d.helpText
        required = d.required
        keyEdited = d.keyEdited
        locked = d.locked
        min = d.min
        max = d.max
        unit = d.unit
        decimals = d.decimals
        minLength = d.minLength
        maxLength = d.maxLength
        multiline = d.multiline
        options = d.options.map {
            Option(
                value: $0.value, label: $0.label, archived: $0.archived, valueEdited: $0.valueEdited, locked: $0.locked)
        }
        multiple = d.multiple
        minSelected = d.minSelected
        maxSelected = d.maxSelected
        publishedMultiple = d.publishedMultiple
    }

    var model: DraftQuestion {
        var d = DraftQuestion(type: type)
        d.key = key
        d.label = label
        d.helpText = helpText
        d.required = required
        d.keyEdited = keyEdited
        d.locked = locked
        d.min = min
        d.max = max
        d.unit = unit
        d.decimals = decimals
        d.minLength = minLength
        d.maxLength = maxLength
        d.multiline = multiline
        d.options = options.map {
            DraftOption(
                value: $0.value, label: $0.label, archived: $0.archived, valueEdited: $0.valueEdited, locked: $0.locked)
        }
        d.multiple = multiple
        d.minSelected = minSelected
        d.maxSelected = maxSelected
        d.publishedMultiple = publishedMultiple
        return d
    }

    var description: String { "\(type.rawValue) \(key)" }
}
