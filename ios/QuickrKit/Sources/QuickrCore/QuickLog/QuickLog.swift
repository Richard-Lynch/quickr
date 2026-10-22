/// Inline quick-log on topic tiles, widgets and intents: which topics can be logged without the
/// record screen, and what they offer. A port of `frontend/src/lib/quickLog.ts`, kept in lockstep
/// with it and `backend/app/services/quicklog.py` by `shared/fixtures/quicklog-vectors.json`.
///
/// Rule: the current version has no questions at all → `single`: one tap logs it, with no answers;
/// or exactly one *required* question, and it is
/// - a single-select with 1–6 active options → those options as chips (one tap logs), or
/// - an int or double → a stepper pre-filled by `initialText(last:)`, plus a log button.
///
/// Optional questions are left unanswered by a quick-log. Anything else (several required
/// questions, a multi-select, text, only optional questions) logs through the record screen.
public enum QuickLog: Sendable, Hashable {
    case chips(question: Question, options: [EnumOption])
    case number(question: Question)
    /// No questions: a "single" topic. Logging it is an entry with no answers.
    case single

    /// Most options shown as chips (more need the record screen's picker).
    public static let chipLimit = 6

    /// Nil when the topic logs through the record screen (`quickLogFor`).
    public init?(questions: [Question]) {
        if questions.isEmpty {
            self = .single
            return
        }
        let required = questions.filter(\.required)
        guard required.count == 1, let question = required.first else { return nil }
        switch question.kind {
        case .choice(let rules):
            guard !rules.multiple else { return nil }
            let options = rules.activeOptions
            guard !options.isEmpty && options.count <= Self.chipLimit else { return nil }
            self = .chips(question: question, options: options)
        case .int, .double:
            self = .number(question: question)
        case .string:
            return nil
        }
    }

    /// The quick question; nil for a single topic, which has none.
    public var question: Question? {
        switch self {
        case .chips(let question, _), .number(let question): question
        case .single: nil
        }
    }

    /// The answers a chip tap logs.
    public static func answers(picking option: EnumOption, for question: Question) -> [String: AnswerValue] {
        [question.key: .string(option.value)]
    }

    /// The text a number quick-log starts with (`initialNumber`): the last logged value while
    /// the question still accepts it (printed as JS `String(n)` would), else its minimum when that
    /// is ≥ 0, else blank. Non-numbers count as no last value. Compares as doubles, like the PWA.
    public static func initialText(for question: Question, last: AnswerValue?) -> String {
        let lastNumber: Double? =
            switch last {
            case .int(let n): Double(n)
            case .double(let x): x
            default: nil
            }
        if let lastNumber {
            let text = JSNumber.string(lastNumber)
            if case .success = AnswerValidator.validate(question, .text(text)) { return text }
        }
        if let min = question.numericRules?.min, min >= 0 { return JSNumber.string(min) }
        return ""
    }

    /// Parses a number quick-log's text with the question's own rules, as if required
    /// (`parseQuickNumber`): the answers to log, or the message to show.
    public static func parseNumber(
        _ text: String, for question: Question
    ) -> Result<[String: AnswerValue], AnswerMessage> {
        var required = question
        required.required = true
        switch AnswerValidator.validate(required, .text(text)) {
        case .success(let value?): return .success([question.key: value])
        case .success(nil): return .failure("Enter a number")
        case .failure(let message): return .failure(message)
        }
    }
}
