/// What a form control holds for one question, before validation: the typed text (numbers, text
/// and single-select choices, where `""` is blank) or the picked option values of a multi-select
/// (`[]` is nothing picked). The PWA's `AnswerInput` (`string | string[]`).
public enum AnswerInput: Sendable, Hashable {
    case text(String)
    case selection([String])

    /// The blank input for a question.
    public static func empty(for question: Question) -> AnswerInput {
        question.isMultiSelect ? .selection([]) : .text("")
    }

    /// Whether the input holds anything (`hasInput`).
    public var hasValue: Bool {
        switch self {
        case .text(let s): !JSNumber.trim(s).isEmpty
        case .selection(let values): !values.isEmpty
        }
    }

    /// The input for a stored or request-shaped value (`inputFromValue`). An old single-select
    /// answer becomes a one-option selection when the question has since become multi-select.
    public init(_ value: AnswerValue?, for question: Question) {
        if question.isMultiSelect {
            switch value {
            case .strings(let values): self = .selection(values)
            case .string(let s): self = .selection(s.isEmpty ? [] : [s])
            default: self = .selection([])
            }
            return
        }
        switch value {
        case .int(let n): self = .text(String(n))
        case .double(let x): self = .text(JSNumber.string(x))
        case .string(let s): self = .text(s)
        case .strings(let values): self = .text(values.first ?? "")
        case nil: self = .text("")
        }
    }

    /// Form state for `questions`, pre-filled from an entry's answers (`answerValuesFromMap`).
    public static func inputs(
        for questions: [Question], from answers: [String: AnswerValue] = [:]
    ) -> [String: AnswerInput] {
        Dictionary(uniqueKeysWithValues: questions.map { ($0.key, AnswerInput(answers[$0.key], for: $0)) })
    }

    /// Archived option values an entry already holds, by question key (`archivedValuesInEntry`).
    /// Pass them as `allowArchived` when editing that entry: they stay valid there.
    public static func archivedValues(
        in answers: [String: AnswerValue], for questions: [Question]
    ) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for question in questions {
            guard case .choice(let rules) = question.kind, let value = answers[question.key] else { continue }
            let held: [String] =
                switch value {
                case .string(let s): [s]
                case .strings(let values): values
                default: []
                }
            let archived = Set(rules.options.filter(\.archived).map(\.value))
            let kept = Set(held).intersection(archived)
            if !kept.isEmpty { out[question.key] = kept }
        }
        return out
    }
}

extension Question {
    /// A multi-select choice question: its answers are lists of option values.
    public var isMultiSelect: Bool {
        if case .choice(let rules) = kind { return rules.multiple }
        return false
    }
}
