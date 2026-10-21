import Foundation
import QuickrCore
import Synchronization

/// One `LogTopicIntent` entry in progress (research/04-siri.md §2): the topic's current questions
/// and the answers so far. The intent's loop asks `next` until there is nothing to ask, then the
/// confirmation snippet edits it (`set`, `toggle`, `step`) and the commit validates it whole.
/// Pure and host-tested: AppIntentsTesting can't answer prompts (spike S4).
public struct IntentDraft: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let topic: Topic
    public private(set) var answers: [String: AnswerValue]

    public init(id: UUID = UUID(), topic: Topic, answers: [String: AnswerValue] = [:]) {
        self.id = id
        self.topic = topic
        self.answers = [:]
        for (key, value) in answers { _ = answer(key, value) }
    }

    /// What the loop asks for one question.
    public enum Ask: Sendable, Hashable {
        /// A spoken number (`requestValue` on a number slot); `unit` for the dialog.
        case number(Question)
        /// One of the options (`requestDisambiguation` on an option slot).
        case option(Question, [EnumOption])
        /// Several options: asked one at a time until "Done" (`requestChoice`).
        case options(Question, [EnumOption])
        /// Free text (`requestValue` on a text slot); voice only, the snippet has no text field.
        case text(Question)

        public var question: Question {
            switch self {
            case .number(let q), .option(let q, _), .options(let q, _), .text(let q): q
            }
        }
    }

    /// The first required question, in the topic's order, without a valid answer; nil when every
    /// required question has one (optional questions are left to the snippet).
    public var next: Ask? {
        topic.questions.first { $0.required && !isAnswered($0) }.map(Self.ask)
    }

    static func ask(_ question: Question) -> Ask {
        switch question.kind {
        case .int, .double: .number(question)
        case .string: .text(question)
        case .choice(let rules):
            rules.multiple ? .options(question, rules.activeOptions) : .option(question, rules.activeOptions)
        }
    }

    /// Whether `question` has a valid answer.
    public func isAnswered(_ question: Question) -> Bool {
        guard let value = answers[question.key] else { return false }
        return Self.check(value, for: question) == nil
    }

    /// Sets one question's answer if it validates for that question; otherwise leaves the draft
    /// unchanged and returns the message (to say before asking again). nil clears it.
    @discardableResult
    public mutating func answer(_ key: String, _ value: AnswerValue?) -> String? {
        guard let question = topic.questions.first(where: { $0.key == key }) else {
            return "\(key) isn't a question of \(topic.name)."
        }
        guard let value else {
            answers[key] = nil
            return nil
        }
        if let message = Self.check(value, for: question) { return message }
        answers[key] = value
        return nil
    }

    /// The message for `value` as `question`'s answer, or nil when it validates.
    static func check(_ value: AnswerValue, for question: Question) -> String? {
        switch AnswerValidator.validate(question, AnswerInput(value, for: question)) {
        case .success(let validated): validated == nil && question.required ? "\(question.label) is required." : nil
        case .failure(let message): "\(question.label): \(message.message)"
        }
    }

    // MARK: - Snippet edits

    /// A chip: picks one option of a single-select.
    public mutating func set(_ key: String, option value: String) {
        answer(key, .string(value))
    }

    /// A toggle: adds or removes one option of a multi-select (kept in option order; a change
    /// that breaks the question's limits is refused).
    public mutating func toggle(_ key: String, option value: String) {
        guard let question = topic.questions.first(where: { $0.key == key }),
            case .choice(let rules) = question.kind, rules.multiple
        else { return }
        var picked: Set<String>
        if case .strings(let values) = answers[key] { picked = Set(values) } else { picked = [] }
        if picked.contains(value) { picked.remove(value) } else { picked.insert(value) }
        let ordered = rules.options.map(\.value).filter(picked.contains)
        if ordered.isEmpty {
            answers[key] = nil
        } else {
            answer(key, .strings(ordered))
        }
    }

    /// ±: moves a number by one step (1, or 10^-decimals), starting from the answer, else the
    /// minimum, else 0, and staying within the bounds.
    public mutating func step(_ key: String, by direction: Int) {
        guard let question = topic.questions.first(where: { $0.key == key }) else { return }
        switch question.kind {
        case .int(let rules):
            let current: Int
            if case .int(let n) = answers[key] { current = n } else { current = rules.min ?? 0 }
            var next = current + direction.signum()
            if let min = rules.min { next = Swift.max(min, next) }
            if let max = rules.max { next = Swift.min(max, next) }
            answer(key, .int(next))
        case .double(let rules):
            let size = pow(10, -Double(rules.decimals ?? 0))
            let current: Double
            if case .double(let x) = answers[key] { current = x } else { current = rules.min ?? 0 }
            var next = ((current + Double(direction.signum()) * size) / size).rounded() * size
            if let min = rules.min { next = Swift.max(min, next) }
            if let max = rules.max { next = Swift.min(max, next) }
            answer(key, .double(next))
        case .string, .choice:
            return
        }
    }

    /// Every answer, validated whole (`IntentLogging.validate`).
    public var validated: Result<[String: AnswerValue], IntentLogging.Failure> {
        IntentLogging.validate(answers, questions: topic.questions)
    }
}

/// The drafts this process holds while their confirmation snippet is on screen: the snippet's
/// buttons (`SetDraftAnswerIntent`, …) run in the same process and find their draft by id. Kept
/// in memory: a snippet keeps the app alive while visible (research §4); a draft whose process
/// died is gone, and the entry is asked again.
public enum IntentDrafts {
    private static let state = Mutex<(drafts: [UUID: IntentDraft], order: [UUID])>(([:], []))
    /// More than this many drafts at once is a leak: the oldest go.
    static let limit = 16

    public static func put(_ draft: IntentDraft) {
        state.withLock { state in
            if state.drafts.updateValue(draft, forKey: draft.id) == nil { state.order.append(draft.id) }
            while state.order.count > limit { state.drafts[state.order.removeFirst()] = nil }
        }
    }

    public static func get(_ id: UUID) -> IntentDraft? { state.withLock { $0.drafts[id] } }

    /// Changes a held draft; nil when it isn't held (any more).
    @discardableResult
    public static func update(_ id: UUID, _ change: (inout IntentDraft) -> Void) -> IntentDraft? {
        state.withLock { state in
            guard var draft = state.drafts[id] else { return nil }
            change(&draft)
            state.drafts[id] = draft
            return draft
        }
    }

    public static func remove(_ id: UUID) {
        state.withLock { state in
            state.drafts[id] = nil
            state.order.removeAll { $0 == id }
        }
    }
}
