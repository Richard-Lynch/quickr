/// Validates form input against a topic version's questions and turns it into the API's answer
/// map. A port of `frontend/src/lib/answerSchema.ts` with the same user-facing messages; every
/// rule the server enforces (`backend/app/services/answers.py`) is caught here first.
public struct AnswerValidator: Sendable {
    public var questions: [Question]
    /// Question key → archived option values that are still accepted: editing an entry that
    /// already holds them (`AnswerInput.archivedValues(in:for:)`). The server's `allowed_archived`.
    public var allowArchived: [String: Set<String>]

    public init(questions: [Question], allowArchived: [String: Set<String>] = [:]) {
        self.questions = questions
        self.allowArchived = allowArchived
    }

    /// Validates every question. A missing input counts as blank.
    public func validate(_ inputs: [String: AnswerInput]) -> Result<ValidatedAnswers, AnswerErrors> {
        var values: [String: AnswerValue?] = [:]
        var errors: [AnswerError] = []
        for question in questions {
            let allowed = allowArchived[question.key] ?? []
            switch Self.validate(question, inputs[question.key], allowArchived: allowed) {
            case .success(let value): values[question.key] = .some(value)
            case .failure(let message): errors.append(AnswerError(key: question.key, message: message.message))
            }
        }
        return errors.isEmpty ? .success(ValidatedAnswers(all: values)) : .failure(AnswerErrors(errors))
    }

    /// Validates one question's input: the value, nil when an optional question is left blank,
    /// or the message to show under the field (`answerFieldSchema`).
    public static func validate(
        _ question: Question, _ input: AnswerInput?, allowArchived: Set<String> = []
    ) -> Result<AnswerValue?, AnswerMessage> {
        if case .choice(let rules) = question.kind, rules.multiple {
            return validateSelection(question, rules, input, allowArchived)
        }
        let raw: String =
            switch input {
            case .text(let s): s
            case .selection(let values): values.first ?? ""
            case nil: ""
            }
        // Numbers trim like the PWA's input; text and choices strip like the server stores them.
        let value = question.numericRules != nil ? JSNumber.trim(raw) : ServerText.strip(raw)
        if value.isEmpty { return question.required ? .failure("Required") : .success(nil) }

        switch question.kind {
        case .int(let rules):
            guard NumberInput.isWholeNumber(value) else { return .failure("Enter a whole number") }
            // Number(value), then Number.isSafeInteger.
            guard let n = Double(value), abs(n) <= JSNumber.maxSafeInteger else {
                return .failure("Number is too large")
            }
            let min = rules.min.map(Double.init)
            let max = rules.max.map(Double.init)
            if let message = rangeMessage(n, min: min, max: max, unit: rules.unit) { return .failure(message) }
            return .success(.int(Int(n)))
        case .double(let rules):
            guard let n = NumberInput.parse(value) else { return .failure("Enter a number") }
            if let message = rangeMessage(n, min: rules.min, max: rules.max, unit: rules.unit) {
                return .failure(message)
            }
            return .success(.double(n))
        case .string(let rules):
            // The server counts code points (Python `len`); see `characterCount`.
            let count = characterCount(value)
            // The server rejects NUL (the PWA shares this message).
            if value.unicodeScalars.contains("\u{0}") { return .failure("Remove the invalid character") }
            if count < rules.minLength {
                return .failure(AnswerMessage("At least \(rules.minLength) characters (\(count) so far)"))
            }
            if count > rules.maxLength {
                return .failure(AnswerMessage("At most \(rules.maxLength) characters (\(count) entered)"))
            }
            return .success(.string(value))
        case .choice(let rules):
            guard let option = rules.options.first(where: { $0.value == value }) else {
                return .failure("Pick one of the options")
            }
            if option.archived && !allowArchived.contains(value) { return .failure("That option has been retired") }
            return .success(.string(value))
        }
    }

    /// Characters as the server counts them for `min_length` / `max_length`: Unicode code points.
    public static func characterCount(_ s: String) -> Int { s.unicodeScalars.count }

    private static func rangeMessage(_ n: Double, min: Double?, max: Double?, unit: String?) -> AnswerMessage? {
        let suffix = unit.map { $0.isEmpty ? "" : " \($0)" } ?? ""
        if let min, n < min { return AnswerMessage("Must be at least \(JSNumber.string(min))\(suffix)") }
        if let max, n > max { return AnswerMessage("Must be at most \(JSNumber.string(max))\(suffix)") }
        return nil
    }

    private static func validateSelection(
        _ question: Question, _ rules: Question.ChoiceRules, _ input: AnswerInput?, _ allowed: Set<String>
    ) -> Result<AnswerValue?, AnswerMessage> {
        let raw: [String] =
            switch input {
            case .selection(let values): values
            case .text(let s): s.isEmpty ? [] : [s]
            case nil: []
            }
        var picked: [String] = []
        for value in raw.map(ServerText.strip) where !value.isEmpty && !picked.contains(value) {
            picked.append(value)
        }
        if picked.isEmpty { return question.required ? .failure("Pick at least one") : .success(nil) }
        for value in picked {
            guard let option = rules.options.first(where: { $0.value == value }) else {
                return .failure("Pick from the options")
            }
            if option.archived && !allowed.contains(value) {
                return .failure(AnswerMessage("“\(option.label)” has been retired"))
            }
        }
        let bounds = SelectionBounds(question: question, rules: rules)
        if picked.count < bounds.min { return .failure(AnswerMessage("Pick at least \(optionCount(bounds.min))")) }
        if let max = bounds.max, picked.count > max {
            return .failure(AnswerMessage("Pick at most \(optionCount(max))"))
        }
        // Option order, like the server stores it.
        let order = Dictionary(
            rules.options.enumerated().map { ($1.value, $0) }, uniquingKeysWith: { first, _ in first })
        return .success(.strings(picked.sorted { order[$0, default: 0] < order[$1, default: 0] }))
    }

    private static func optionCount(_ n: Int) -> String { "\(n) option\(n == 1 ? "" : "s")" }
}

/// The selection limits of a multi-select question as the server applies them
/// (`selectionBounds`): at least one when required, and never fewer than `min_selected`.
public struct SelectionBounds: Sendable, Hashable {
    public var min: Int
    public var max: Int?

    public init(question: Question, rules: Question.ChoiceRules) {
        min = Swift.max(question.required ? 1 : 0, rules.minSelected ?? 0)
        max = rules.maxSelected
    }

    /// Nil unless the question is a multi-select.
    public init?(_ question: Question) {
        guard case .choice(let rules) = question.kind, rules.multiple else { return nil }
        self.init(question: question, rules: rules)
    }

    /// "Pick 2", "Pick 1–3", "Pick up to 3", "Pick at least 2" or "Pick any", shown by the chips.
    public var hint: String {
        if let max, min == max { return "Pick \(min)" }
        if let max, min > 0 { return "Pick \(min)–\(max)" }
        if let max { return "Pick up to \(max)" }
        if min > 1 { return "Pick at least \(min)" }
        return "Pick any"
    }
}

/// A user-facing validation message.
public struct AnswerMessage: Error, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var message: String

    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { message = value }

    public var description: String { message }
}

/// A valid answer map.
public struct ValidatedAnswers: Sendable, Hashable {
    /// Every question key; nil when left blank. The body of an update, where null clears an answer.
    public var all: [String: AnswerValue?]

    public init(all: [String: AnswerValue?]) { self.all = all }

    /// The answered questions only: the body of a create (blank optional answers are omitted,
    /// `compactAnswers`).
    public var answered: [String: AnswerValue] { all.compactMapValues { $0 } }
}

/// One field's problem. `key` is the question key; the server's `loc` for it is `["answers", key]`.
public struct AnswerError: Sendable, Hashable {
    public var key: String
    public var message: String

    public init(key: String, message: String) {
        self.key = key
        self.message = message
    }

    public var issue: FieldIssue { FieldIssue(location: [.key("answers"), .key(key)], message: message) }
}

/// Every invalid field, in question order (focus the first).
public struct AnswerErrors: Error, Sendable, Hashable {
    public var errors: [AnswerError]

    public init(_ errors: [AnswerError]) { self.errors = errors }

    public var byKey: [String: String] {
        Dictionary(errors.map { ($0.key, $0.message) }, uniquingKeysWith: { first, _ in first })
    }

    public var first: AnswerError? { errors.first }
}
