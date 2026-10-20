import Foundation

/// A field of one draft question, where a validation message belongs.
public enum QuestionField: Sendable, Hashable {
    case key, label, helpText
    case min, max, unit, decimals
    case minLength, maxLength
    /// The option list as a whole (count, none active).
    case options
    case optionValue(Int)
    case optionLabel(Int)
    case multiple, minSelected, maxSelected

    /// The PWA's form path, relative to the question: `help_text`, `options.1.value`.
    public var path: String {
        switch self {
        case .key: "key"
        case .label: "label"
        case .helpText: "help_text"
        case .min: "min"
        case .max: "max"
        case .unit: "unit"
        case .decimals: "decimals"
        case .minLength: "min_length"
        case .maxLength: "max_length"
        case .options: "options"
        case .optionValue(let i): "options.\(i).value"
        case .optionLabel(let i): "options.\(i).label"
        case .multiple: "multiple"
        case .minSelected: "min_selected"
        case .maxSelected: "max_selected"
        }
    }

    /// The first path segment (`options` for an option's fields).
    var root: String { path.split(separator: ".").first.map(String.init) ?? path }
}

/// A field of the whole builder form.
public enum DraftField: Sendable, Hashable {
    case name, slug, description, changeNote
    /// The question list as a whole (none, too many).
    case questions
    case question(Int, QuestionField)

    /// The PWA's form path: `name`, `questions`, `questions.1.key`.
    public var path: String {
        switch self {
        case .name: "name"
        case .slug: "slug"
        case .description: "description"
        case .changeNote: "change_note"
        case .questions: "questions"
        case .question(let i, let field): "questions.\(i).\(field.path)"
        }
    }
}

/// One validation message, in the PWA's words, at the field it belongs to.
public struct DraftIssue<Field: Sendable & Hashable>: Sendable, Hashable {
    public var field: Field
    public var message: String

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// Why a draft can't be sent: every issue, in the order the PWA reports them.
public struct DraftIssues<Field: Sendable & Hashable>: Error, Sendable, Hashable {
    public var issues: [DraftIssue<Field>]

    public init(_ issues: [DraftIssue<Field>]) { self.issues = issues }

    /// One message per field; a later issue replaces an earlier one, like react-hook-form.
    public var byField: [Field: String] {
        Dictionary(issues.map { ($0.field, $0.message) }, uniquingKeysWith: { _, last in last })
    }
}

/// The builder's validation messages (`frontend/src/lib/builder.ts`).
public enum BuilderMessage {
    public static let required = "Required"
    public static let key = "Use lower_snake_case: a–z, 0–9, _ (start with a letter, max 63)"
    public static let slug = "Lowercase letters, digits and dashes (start with a letter or digit, max 64)"
    public static let topicName = "Give the topic a name"
    public static let publishedMultiple =
        "Published as multi-select: existing answers are lists, so it can’t become single-select. Add a new question instead."

    static func tooLong(_ max: Int, _ count: Int) -> String { "At most \(max) characters (\(count) now)" }
}

extension DraftQuestion {
    /// Validates the draft with the server's rules and the `limits`, and converts it to the
    /// question to send (`convertDraftQuestion`). Text is stripped as the server strips it.
    public func validated(limits: Limits = .serverDefaults) -> Result<Question, DraftIssues<QuestionField>> {
        validated(limits: limits, keys: limits.keyMatcher)
    }

    func validated(limits: Limits, keys: ServerPattern) -> Result<Question, DraftIssues<QuestionField>> {
        var issues = Issues()
        let key = BuilderText.strip(self.key)
        let label = BuilderText.strip(self.label)
        let help = BuilderText.strip(helpText)
        if label.isEmpty { issues.add(.label, BuilderMessage.required) }
        issues.maxLength(.label, label, limits.maxLabelLength)
        if key.isEmpty {
            issues.add(.key, BuilderMessage.required)
        } else if !keys.matches(key) {
            issues.add(.key, BuilderMessage.key)
        }
        issues.maxLength(.helpText, help, limits.maxHelpTextLength)

        let kind: Question.Kind
        switch type {
        case .int, .double:
            let integer = type == .int
            let lo = issues.number(min, .min, integer: integer)
            let hi = issues.number(max, .max, integer: integer)
            if case .value(let a) = lo, case .value(let b) = hi, a > b { issues.add(.max, "Max must be ≥ min") }
            let unit = BuilderText.strip(self.unit)
            issues.maxLength(.unit, unit, limits.maxUnitLength)
            if integer {
                kind = .int(.init(min: lo.int, max: hi.int, unit: unit.isEmpty ? nil : unit))
            } else {
                let places = issues.number(decimals, .decimals, integer: true, min: 0, max: limits.maxDecimals)
                kind = .double(
                    .init(min: lo.double, max: hi.double, decimals: places.int, unit: unit.isEmpty ? nil : unit))
            }
        case .str:
            let lo = issues.number(minLength, .minLength, integer: true, min: 0, max: limits.maxStrLength)
            let hi = issues.number(maxLength, .maxLength, integer: true, min: 1, max: limits.maxStrLength)
            let minLength = lo.int ?? 0
            let maxLength = hi.int ?? Question.StringRules.defaultMaxLength
            if !lo.isInvalid && !hi.isInvalid && minLength > maxLength {
                issues.add(.maxLength, "Max length must be ≥ min length")
            }
            kind = .string(.init(minLength: minLength, maxLength: maxLength, multiline: multiline))
        case .enum:
            kind = .choice(choiceRules(&issues, limits: limits, keys: keys))
        }

        if !issues.list.isEmpty { return .failure(DraftIssues(issues.list)) }
        return .success(
            Question(key: key, label: label, helpText: help.isEmpty ? nil : help, required: required, kind: kind))
    }

    private func choiceRules(_ issues: inout Issues, limits: Limits, keys: ServerPattern) -> Question.ChoiceRules {
        let values = options.map { BuilderText.strip($0.value) }
        let labels = options.map { BuilderText.strip($0.label) }
        for i in options.indices {
            if labels[i].isEmpty { issues.add(.optionLabel(i), BuilderMessage.required) }
            issues.maxLength(.optionLabel(i), labels[i], limits.maxLabelLength)
            if values[i].isEmpty {
                issues.add(.optionValue(i), BuilderMessage.required)
            } else if !keys.matches(values[i]) {
                issues.add(.optionValue(i), BuilderMessage.key)
            }
        }
        for i in duplicates(values.map(TextKey.init)) { issues.add(.optionValue(i), "Another option has this value") }
        for i in duplicates(options.map { BuilderText.fold($0.label) }) {
            issues.add(.optionLabel(i), "Another option has this label")
        }
        let active = activeOptionCount
        if options.isEmpty {
            issues.add(.options, "Add at least one option")
        } else if active == 0 {
            issues.add(.options, "At least one option must be active")
        } else if options.count > limits.maxEnumOptions {
            issues.add(.options, "At most \(limits.maxEnumOptions) options")
        }

        var minSelected: Int?
        var maxSelected: Int?
        if !multiple && publishedMultiple { issues.add(.multiple, BuilderMessage.publishedMultiple) }
        if multiple {
            minSelected = issues.number(self.minSelected, .minSelected, integer: true, min: 1).int
            maxSelected = issues.number(self.maxSelected, .maxSelected, integer: true, min: 1).int
            if active > 0 {
                let only = "Only \(active) active option\(active == 1 ? "" : "s")"
                if let n = minSelected, n > active { issues.add(.minSelected, only) }
                if let n = maxSelected, n > active { issues.add(.maxSelected, only) }
            }
            if let lo = minSelected, let hi = maxSelected, lo > hi { issues.add(.maxSelected, "Max must be ≥ min") }
        }
        let converted = options.indices.map {
            EnumOption(value: values[$0], label: labels[$0], archived: options[$0].archived)
        }
        return .init(options: converted, multiple: multiple, minSelected: minSelected, maxSelected: maxSelected)
    }
}

extension TopicDraft {
    /// A validated new topic (`makeTopicDraftSchema`), without the schedule (TOPIC adds it).
    public struct Creation: Sendable, Hashable {
        public var name: String
        /// Nil: let the server derive it from the name.
        public var slug: String?
        public var description: String
        public var questions: [Question]
    }

    /// A validated next version (`makeVersionDraftSchema`).
    public struct Version: Sendable, Hashable {
        public var questions: [Question]
        public var changeNote: String

        public init(questions: [Question], changeNote: String = "") {
            self.questions = questions
            self.changeNote = changeNote
        }
    }

    /// Validated topic details for a PATCH (`makeTopicMetaSchema`).
    public struct Details: Sendable, Hashable {
        public var name: String
        public var slug: String
        public var description: String
    }

    /// Validates everything a new topic sends. Issues come in form order: name, slug,
    /// description, the question list, then each question.
    public func validatedForCreation(limits: Limits = .serverDefaults) -> Result<Creation, DraftIssues<DraftField>> {
        var issues: [DraftIssue<DraftField>] = []
        let name = validatedName(&issues, limits: limits)
        let slug = BuilderText.strip(self.slug)
        if !slug.isEmpty && !limits.slugMatcher.matches(slug) {
            issues.append(.init(field: .slug, message: BuilderMessage.slug))
        }
        let description = validatedDescription(&issues, limits: limits)
        let questions = validatedQuestions(&issues, limits: limits)
        if !issues.isEmpty { return .failure(DraftIssues(issues)) }
        return .success(
            Creation(name: name, slug: slug.isEmpty ? nil : slug, description: description, questions: questions))
    }

    /// Validates the questions and change note of a new version.
    public func validatedForVersion(limits: Limits = .serverDefaults) -> Result<Version, DraftIssues<DraftField>> {
        var issues: [DraftIssue<DraftField>] = []
        let questions = validatedQuestions(&issues, limits: limits)
        let note = BuilderText.strip(changeNote)
        if BuilderText.count(note) > limits.maxChangeNoteLength {
            issues.append(.init(field: .changeNote, message: "At most \(limits.maxChangeNoteLength) characters"))
        }
        if !issues.isEmpty { return .failure(DraftIssues(issues)) }
        return .success(Version(questions: questions, changeNote: note))
    }

    /// Validates the topic's name, slug and description (topic settings).
    public func validatedDetails(limits: Limits = .serverDefaults) -> Result<Details, DraftIssues<DraftField>> {
        var issues: [DraftIssue<DraftField>] = []
        let name = validatedName(&issues, limits: limits)
        let slug = BuilderText.strip(self.slug)
        if slug.isEmpty {
            issues.append(.init(field: .slug, message: BuilderMessage.required))
        } else if !limits.slugMatcher.matches(slug) {
            issues.append(.init(field: .slug, message: BuilderMessage.slug))
        }
        let description = validatedDescription(&issues, limits: limits)
        if !issues.isEmpty { return .failure(DraftIssues(issues)) }
        return .success(Details(name: name, slug: slug, description: description))
    }

    /// Validates the question list alone: list rules, then each question (`makeQuestionsSchema`).
    public func validatedQuestions(limits: Limits = .serverDefaults) -> Result<[Question], DraftIssues<DraftField>> {
        var issues: [DraftIssue<DraftField>] = []
        let questions = validatedQuestions(&issues, limits: limits)
        return issues.isEmpty ? .success(questions) : .failure(DraftIssues(issues))
    }

    /// Cross-question rules (`questionListIssues`): at least one, at most `max_questions`,
    /// unique keys, and labels unique ignoring case. Flagged on the later question.
    public static func questionListIssues(
        _ questions: [(key: String, label: String)], limits: Limits = .serverDefaults
    ) -> [DraftIssue<DraftField>] {
        var issues: [DraftIssue<DraftField>] = []
        if questions.isEmpty { issues.append(.init(field: .questions, message: "Add at least one question")) }
        if questions.count > limits.maxQuestions {
            issues.append(.init(field: .questions, message: "At most \(limits.maxQuestions) questions"))
        }
        for i in duplicates(questions.map { TextKey(BuilderText.strip($0.key)) }) {
            issues.append(.init(field: .question(i, .key), message: "Key already used by another question"))
        }
        for i in duplicates(questions.map { BuilderText.fold($0.label) }) {
            issues.append(.init(field: .question(i, .label), message: "Another question has this label"))
        }
        return issues
    }

    private func validatedQuestions(_ issues: inout [DraftIssue<DraftField>], limits: Limits) -> [Question] {
        issues += Self.questionListIssues(questions.map { ($0.key, $0.label) }, limits: limits)
        let keys = limits.keyMatcher
        var out: [Question] = []
        for (i, draft) in questions.enumerated() {
            switch draft.validated(limits: limits, keys: keys) {
            case .success(let q): out.append(q)
            case .failure(let e): issues += e.issues.map { .init(field: .question(i, $0.field), message: $0.message) }
            }
        }
        return out
    }

    private func validatedName(_ issues: inout [DraftIssue<DraftField>], limits: Limits) -> String {
        let name = BuilderText.strip(self.name)
        if name.isEmpty {
            issues.append(.init(field: .name, message: BuilderMessage.topicName))
        } else if BuilderText.count(name) > limits.maxTopicNameLength {
            issues.append(.init(field: .name, message: "At most \(limits.maxTopicNameLength) characters"))
        }
        return name
    }

    private func validatedDescription(_ issues: inout [DraftIssue<DraftField>], limits: Limits) -> String {
        let description = BuilderText.strip(self.description)
        if BuilderText.count(description) > limits.maxDescriptionLength {
            issues.append(.init(field: .description, message: "At most \(limits.maxDescriptionLength) characters"))
        }
        return description
    }
}

/// Indices of items equal (code point by code point, like Python) to an earlier one; empty items
/// never clash.
func duplicates(_ items: [TextKey]) -> [Int] {
    var seen = Set<TextKey>()
    var out: [Int] = []
    for (i, item) in items.enumerated() where !item.isEmpty {
        if seen.contains(item) { out.append(i) }
        seen.insert(item)
    }
    return out
}

/// A constraint field's text, parsed (`parseConstraint`).
enum Constraint {
    case empty
    case value(Double)
    case invalid

    var double: Double? {
        if case .value(let n) = self { n } else { nil }
    }

    /// Only ever called on integer-checked values, which are within ±2^53.
    var int: Int? { double.map { Int($0) } }

    var isInvalid: Bool {
        if case .invalid = self { true } else { false }
    }
}

private struct Issues {
    var list: [DraftIssue<QuestionField>] = []

    mutating func add(_ field: QuestionField, _ message: String) {
        list.append(DraftIssue(field: field, message: message))
    }

    mutating func maxLength(_ field: QuestionField, _ value: String, _ max: Int) {
        let count = BuilderText.count(value)
        if count > max { add(field, BuilderMessage.tooLong(max, count)) }
    }

    /// The PWA's number grammar (`NumberInput`); whole numbers must be JS-safe integers.
    mutating func number(
        _ raw: String, _ field: QuestionField, integer: Bool = false, min: Int? = nil, max: Int? = nil
    ) -> Constraint {
        if JSNumber.trim(raw).isEmpty { return .empty }
        guard let n = NumberInput.parse(raw) else {
            add(field, "Enter a number")
            return .invalid
        }
        if integer && n.rounded(.towardZero) != n {
            add(field, "Must be a whole number")
            return .invalid
        }
        if integer && abs(n) > JSNumber.maxSafeInteger {
            add(field, "Number is too large")
            return .invalid
        }
        if let min, n < Double(min) {
            add(field, "Must be at least \(min)")
            return .invalid
        }
        if let max, n > Double(max) {
            add(field, "Must be at most \(max)")
            return .invalid
        }
        return .value(n)
    }
}
