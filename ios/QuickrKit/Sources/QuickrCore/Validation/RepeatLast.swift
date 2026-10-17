/// "Same as last time" and Repeat-last (docs/ios/PLAN.md §2): re-logging the latest entry's
/// answers against the topic's *current* version.
public enum RepeatLast {
    /// The answers to log again (a create body), or nil when they no longer validate against
    /// `questions` (open the record screen pre-filled with `reusableInputs` instead).
    ///
    /// Answers are re-read the way the form would show them, so an old single-select answer still
    /// counts for a question that became multi-select, and answers to removed questions are
    /// dropped. Archived options are not allowed: this is a new entry. Nil as well when nothing
    /// would be logged.
    public static func answers(_ last: [String: AnswerValue], questions: [Question]) -> [String: AnswerValue]? {
        let inputs = AnswerInput.inputs(for: questions, from: last)
        guard case .success(let valid) = AnswerValidator(questions: questions).validate(inputs) else { return nil }
        let answered = valid.answered
        return answered.isEmpty ? nil : answered
    }

    /// Form state from the latest entry that keeps only what is still valid to log now
    /// (`reusableValuesFromEntry`): archived options and out-of-range or malformed values are
    /// dropped; for choices, only archived picks are removed.
    public static func reusableInputs(_ last: [String: AnswerValue], questions: [Question]) -> [String: AnswerInput] {
        var inputs = AnswerInput.inputs(for: questions, from: last)
        for question in questions {
            guard let input = inputs[question.key] else { continue }
            if case .choice(let rules) = question.kind {
                let active = Set(rules.activeOptions.map(\.value))
                switch input {
                case .selection(let values): inputs[question.key] = .selection(values.filter(active.contains))
                case .text(let value): inputs[question.key] = .text(active.contains(value) ? value : "")
                }
            } else if case .failure = AnswerValidator.validate(question, input) {
                inputs[question.key] = .empty(for: question)
            }
        }
        return inputs
    }
}
