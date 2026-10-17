/// "Same as last time" and Repeat-last (docs/ios/PLAN.md §2): re-logging the latest entry's
/// answers against the topic's *current* version.
public enum RepeatLast {
    /// The answers to log again (a create body), or nil when they don't validate, unchanged,
    /// against `questions` (open the record screen pre-filled with `reusableInputs` instead).
    ///
    /// Nothing is converted: a stored value must already have the shape the current question
    /// takes, so a list for what is now a single-select, or text for what is now a number, gives
    /// nil, and so does an answer to a question the version no longer has (the server rejects
    /// it). Archived options are not allowed: this is a new entry. A topic whose questions are
    /// all optional can repeat an entry with no answers (an empty map).
    public static func answers(_ last: [String: AnswerValue], questions: [Question]) -> [String: AnswerValue]? {
        let keys = Set(questions.map(\.key))
        guard last.keys.allSatisfy(keys.contains) else { return nil }
        var inputs: [String: AnswerInput] = [:]
        for question in questions {
            guard let value = last[question.key] else { continue }
            guard let input = exactInput(value, for: question) else { return nil }
            inputs[question.key] = input
        }
        guard case .success(let valid) = AnswerValidator(questions: questions).validate(inputs) else { return nil }
        // Validation may not change a value (stripping, say), only put a selection in option order.
        for (key, value) in valid.answered {
            guard let stored = last[key], same(value, stored) else { return nil }
        }
        return valid.answered
    }

    /// The form input for a stored value whose shape the question takes as is, else nil.
    private static func exactInput(_ value: AnswerValue, for question: Question) -> AnswerInput? {
        switch (question.kind, value) {
        case (.int, .int(let n)): .text(String(n))
        // The server takes a whole number for a double question.
        case (.double, .int(let n)): .text(String(n))
        case (.double, .double(let x)): .text(JSNumber.string(x))
        case (.string, .string(let s)): .text(s)
        case (.choice(let rules), .string(let s)) where !rules.multiple: .text(s)
        case (.choice(let rules), .strings(let values)) where rules.multiple && Set(values).count == values.count:
            .selection(values)
        default: nil
        }
    }

    private static func same(_ validated: AnswerValue, _ stored: AnswerValue) -> Bool {
        switch (validated, stored) {
        case (.double(let x), .int(let n)): x == Double(n)
        case (.strings(let a), .strings(let b)): a.count == b.count && Set(a) == Set(b)
        default: validated == stored
        }
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
