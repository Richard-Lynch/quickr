import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

/// `shared/fixtures/builder-ui-vectors.json`, from the PWA's own `builder.ts` and
/// `questionSummary.ts`: a new question's draft, the draft a published question opens as, the
/// live preview's question, and the versions list's constraint line (en-US); for timed topics a
/// new step's or lap type's key, the draft a timer opens as, renaming, a variable as entered, an
/// alert's live evaluation, the normalised v2 timer a draft publishes (or its issues at the
/// draft's paths) and the review sheet's timing lines (timers2.md §1.6, §12.1).
@Suite struct BuilderUIVectorTests {
    @Test func hasCases() {
        #expect(BuilderUIVectors.shared.newQuestion.count == 4)
        #expect(BuilderUIVectors.shared.fromQuestion.count >= 20)
        #expect(BuilderUIVectors.shared.preview.count >= 25)
        #expect(BuilderUIVectors.shared.constraintText.count >= 10)
        #expect(BuilderUIVectors.shared.newStep.count >= 10)
        #expect(BuilderUIVectors.shared.stepLabel.count >= 8)
        let timers = BuilderUITimerVectors.shared
        #expect(timers.fromTimer.count >= 4)
        #expect(timers.fromTimer.contains { !$0.expected.laps.isEmpty })
        #expect(timers.timerOutput.count >= 36)
        #expect(timers.timerOutput.contains { $0.expected.issues.contains { $0.path.hasPrefix("laps.") } })
        #expect(timers.timerChanges.count >= 29)
        #expect(timers.newLapType.count >= 14)
        #expect(timers.lapTypeLabel.count >= 8)
        #expect(timers.variable.count >= 15)
        #expect(timers.alertExpr.count >= 20)
    }

    // MARK: Timed topics (timers.md §2.1)

    @Test(arguments: BuilderUIVectors.shared.newStep)
    func newStep(_ vector: BuilderUIVectors.NewStepCase) {
        let step = DraftStep(label: vector.label, taken: vector.taken, history: vector.historic)
        #expect(PlainStep(step) == vector.expected)
    }

    @Test(arguments: BuilderUITimerVectors.shared.fromTimer)
    func fromTimer(_ vector: BuilderUITimerVectors.FromTimerCase) {
        let opened = TopicDraft.timerDraft(from: vector.timer)
        #expect(opened.timed == vector.expected.timed)
        #expect(opened.steps.map(PlainStep.init) == vector.expected.steps)
        #expect(opened.laps.map(PlainLapType.init) == vector.expected.laps)
        #expect(opened.variables.map(PlainVariable.init) == vector.expected.variables)
    }

    @Test(arguments: BuilderUIVectors.shared.stepLabel)
    func stepLabel(_ vector: BuilderUIVectors.StepLabelCase) {
        let step = vector.step.model.withLabel(vector.label, takenKeys: vector.taken, history: vector.historic)
        #expect(PlainStep(step) == vector.expected)
    }

    @Test(arguments: BuilderUITimerVectors.shared.timerOutput)
    func timerOutput(_ vector: BuilderUITimerVectors.TimerOutputCase) {
        switch vector.draft.model.validatedTimer() {
        case .success(let timer):
            #expect(timer == vector.expected.timer)
            #expect(vector.expected.issues.isEmpty)
        case .failure(let issues):
            let got = issues.issues.map { BuilderUITimerVectors.Issue(path: $0.field.path, message: $0.message) }
            #expect(got == vector.expected.issues)
            #expect(vector.expected.timer == nil)
        }
    }

    @Test(arguments: BuilderUITimerVectors.shared.timerChanges)
    func timerChanges(_ vector: BuilderUITimerVectors.TimerChangesCase) {
        #expect(TimerChanges.changes(base: vector.base, next: vector.next) == vector.expected)
    }

    // MARK: Timer v2 (timers2.md §1.6)

    @Test(arguments: BuilderUITimerVectors.shared.newLapType)
    func newLapType(_ vector: BuilderUITimerVectors.NewLapTypeCase) {
        let lap = DraftLapType(label: vector.label, taken: vector.taken, history: vector.history.model)
        #expect(PlainLapType(lap) == vector.expected)
    }

    @Test(arguments: BuilderUITimerVectors.shared.lapTypeLabel)
    func lapTypeLabel(_ vector: BuilderUITimerVectors.LapTypeLabelCase) {
        let lap = vector.lapType.model.withLabel(vector.label, takenKeys: vector.taken, history: vector.history.model)
        #expect(PlainLapType(lap) == vector.expected)
    }

    @Test(arguments: BuilderUITimerVectors.shared.variable)
    func variable(_ vector: BuilderUITimerVectors.VariableCase) {
        let entered = DraftVariable(name: "", duration: vector.duration).withName(vector.name)
        #expect(entered.name == vector.expected.name)
        switch entered.validated() {
        case .success(let variable):
            #expect(variable == vector.expected.variable)
            #expect(vector.expected.issues.isEmpty)
        case .failure(let issues):
            let got = issues.issues.map { BuilderUITimerVectors.Issue(path: $0.field.rawValue, message: $0.message) }
            #expect(got == vector.expected.issues)
            #expect(vector.expected.variable == nil)
        }
    }

    @Test(arguments: BuilderUITimerVectors.shared.alertExpr)
    func alertExpr(_ vector: BuilderUITimerVectors.AlertExprCase) {
        let got = TopicDraft.alertPreview(vector.at, variables: vector.variables.map(\.model))
        #expect(got == vector.expected.preview)
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
    var stepLabel: [StepLabelCase]

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

/// The timer sections of builder-ui-vectors.json, decoded without the snake-case strategy: a
/// timer's `at_ms` must reach `TopicTimer.Alert`'s own key.
struct BuilderUITimerVectors: Decodable {
    static let shared: BuilderUITimerVectors = {
        do {
            return try JSONDecoder().decode(BuilderUITimerVectors.self, from: Fixtures.data("builder-ui-vectors.json"))
        } catch {
            fatalError("builder-ui-vectors.json: \(error)")
        }
    }()

    var fromTimer: [FromTimerCase]
    var timerOutput: [TimerOutputCase]
    var timerChanges: [TimerChangesCase]
    var newLapType: [NewLapTypeCase]
    var lapTypeLabel: [LapTypeLabelCase]
    var variable: [VariableCase]
    var alertExpr: [AlertExprCase]

    enum CodingKeys: String, CodingKey {
        case fromTimer = "from_timer"
        case timerOutput = "timer_output"
        case timerChanges = "timer_changes"
        case newLapType = "new_lap_type"
        case lapTypeLabel = "lap_type_label"
        case variable
        case alertExpr = "alert_expr"
    }

    /// An issue as the vectors spell it: a path relative to the draft (`["laps", 0, "key"]`,
    /// `["variables"]`), joined with dots as `DraftField.path` spells it, and the message.
    struct Issue: Decodable, Sendable, Equatable, CustomStringConvertible {
        var path: String
        var message: String

        init(path: String, message: String) {
            self.path = path
            self.message = message
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decode(String.self, forKey: .message)
            var parts = try c.nestedUnkeyedContainer(forKey: .path)
            var path: [String] = []
            while !parts.isAtEnd {
                if let i = try? parts.decode(Int.self) {
                    path.append(String(i))
                } else {
                    path.append(try parts.decode(String.self))
                }
            }
            self.path = path.joined(separator: ".")
        }

        enum CodingKeys: String, CodingKey { case path, message }
        var description: String { "\(path): \(message)" }
    }

    struct History: Decodable, Sendable {
        var steps: [BuilderUIVectors.Historic]
        var laps: [BuilderUIVectors.Historic]
        var model: TimerHistory {
            TimerHistory(
                steps: steps.map { HistoricStep(key: $0.key, label: $0.label) },
                laps: laps.map { HistoricStep(key: $0.key, label: $0.label) })
        }
    }

    struct FromTimerCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Sendable {
            var timed: Bool
            var steps: [PlainStep]
            var laps: [PlainLapType]
            var variables: [PlainVariable]
        }
        var timer: TopicTimer?
        var expected: Expected
        var testDescription: String {
            timer.map { "\($0.steps.count) steps, \($0.laps.count) lap types" } ?? "null"
        }
    }

    /// The draft's timer fields (`TimerDraftFields`).
    struct PlainTimerDraft: Decodable, Sendable {
        var timed: Bool
        var steps: [PlainStep]
        var laps: [PlainLapType]
        var variables: [PlainVariable]
        var model: TopicDraft {
            TopicDraft(
                questions: [], timed: timed, steps: steps.map(\.model), laps: laps.map(\.model),
                variables: variables.map(\.model))
        }
    }

    struct TimerOutputCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Sendable {
            var timer: TopicTimer?
            var issues: [Issue]
        }
        var name: String
        var draft: PlainTimerDraft
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

    struct NewLapTypeCase: Decodable, Sendable, CustomTestStringConvertible {
        var label: String
        var taken: [String]
        var history: History
        var expected: PlainLapType
        var testDescription: String { "'\(label)' taken \(taken) history \(history.laps.count)" }
    }

    struct LapTypeLabelCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var lapType: PlainLapType
        var label: String
        var taken: [String]
        var history: History
        var expected: PlainLapType
        var testDescription: String { name }

        enum CodingKeys: String, CodingKey {
            case name, label, taken, history, expected
            case lapType = "lap_type"
        }
    }

    struct VariableCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Sendable {
            var name: String
            var variable: TopicTimer.Variable?
            var issues: [Issue]
        }
        var name: String
        var duration: String
        var expected: Expected
        var testDescription: String { "'\(name)' = '\(duration)'" }
    }

    struct AlertExprCase: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Sendable {
            var ms: Int?
            var text: String?
            var error: String?
            var pos: Int?
            var preview: AlertPreview {
                if let ms, let text { return .value(ms: ms, text: text) }
                return .error(message: error ?? "", pos: pos ?? -1)
            }
        }
        var name: String
        var at: String
        var variables: [PlainVariable]
        var expected: Expected
        var testDescription: String { name }
    }
}

/// A draft alert without its id (the PWA's `DraftAlert` without `uid`).
struct PlainAlert: Decodable, Sendable, Equatable {
    var key, label, at: String
    var locked: Bool

    init(_ a: DraftAlert) {
        key = a.key
        label = a.label
        at = a.at
        locked = a.locked
    }

    var model: DraftAlert { DraftAlert(key: key, label: label, at: at, locked: locked) }
}

/// A draft lap type without its id (`DraftLapType` without `uid`).
struct PlainLapType: Decodable, Sendable, Equatable {
    var key, label: String
    var locked: Bool
    var alerts: [PlainAlert]

    init(_ l: DraftLapType) {
        key = l.key
        label = l.label
        locked = l.locked
        alerts = l.alerts.map(PlainAlert.init)
    }

    var model: DraftLapType {
        DraftLapType(key: key, label: label, locked: locked, alerts: alerts.map(\.model))
    }
}

/// A draft variable without its id (`DraftVariable` without `uid`).
struct PlainVariable: Decodable, Sendable, Equatable {
    var name, duration: String

    init(_ v: DraftVariable) {
        name = v.name
        duration = v.duration
    }

    var model: DraftVariable { DraftVariable(name: name, duration: duration) }
}

/// A draft step without its id (the PWA's `DraftStep` without `uid`). The v1 sections have no
/// `alerts`.
struct PlainStep: Decodable, Sendable, Equatable {
    var key, label: String
    var locked: Bool
    var alerts: [PlainAlert]

    init(_ s: DraftStep) {
        key = s.key
        label = s.label
        locked = s.locked
        alerts = s.alerts.map(PlainAlert.init)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        locked = try c.decode(Bool.self, forKey: .locked)
        alerts = try c.decodeIfPresent([PlainAlert].self, forKey: .alerts) ?? []
    }

    enum CodingKeys: String, CodingKey { case key, label, locked, alerts }

    var model: DraftStep { DraftStep(key: key, label: label, locked: locked, alerts: alerts.map(\.model)) }
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
