import Foundation
import QuickrCore

/// The answers part of a request body, as ``FormModel/submit()`` produces it.
public enum AnswersBody: Sendable, Hashable {
    /// A new entry (record screen, fix mode): answered questions only; blank optional ones are
    /// omitted (`ValidatedAnswers.answered`).
    case create([String: AnswerValue])
    /// An edit: every question key, nil for a blank one, which clears it (`ValidatedAnswers.all`).
    case update([String: AnswerValue?])
}

/// The topic's latest entry, for "Same as last time" and a single-number topic's start value.
public struct LastEntry: Sendable, Hashable {
    public var answers: [String: AnswerValue]
    public var capturedAt: Date

    public init(answers: [String: AnswerValue], capturedAt: Date) {
        self.answers = answers
        self.capturedAt = capturedAt
    }

    public init(_ entry: Entry) {
        self.init(answers: entry.answers, capturedAt: entry.capturedAt)
    }
}

/// "Same as last time": the latest entry's answers that are still valid to log now
/// (`RepeatLast.reusableInputs`), with a one-line summary of them.
public struct FormPrefill: Sendable, Hashable {
    /// One input per question; blank where the old answer no longer fits.
    public var inputs: [String: AnswerInput]
    /// "Run · 45 min · 5.2 km", in question order, of the answers that are reused.
    public var summary: String
    public var capturedAt: Date

    /// Nil when nothing of the last entry can be reused.
    public init?(_ last: LastEntry, questions: [Question]) {
        let inputs = RepeatLast.reusableInputs(last.answers, questions: questions)
        let reused = questions.filter { inputs[$0.key]?.hasValue == true }
        guard !reused.isEmpty else { return nil }
        self.inputs = inputs
        self.summary = reused.compactMap { q in last.answers[q.key].map { Self.text($0, for: q) } }.joined(
            separator: " · ")
        self.capturedAt = last.capturedAt
    }

    /// An answer as the summary shows it: option labels, numbers with their unit, text as is.
    static func text(_ value: AnswerValue, for question: Question) -> String {
        switch (value, question.kind) {
        case (.string(let s), .choice(let rules)):
            return rules.options.first { $0.value == s }?.label ?? s
        case (.strings(let values), .choice(let rules)):
            return values.map { v in rules.options.first { $0.value == v }?.label ?? v }.joined(separator: ", ")
        case (.int(let n), _):
            return withUnit(String(n), question)
        case (.double(let x), _):
            return withUnit(JSNumber.string(x), question)
        case (.string(let s), _):
            return s
        case (.strings(let values), _):
            return values.joined(separator: ", ")
        }
    }

    private static func withUnit(_ number: String, _ question: Question) -> String {
        guard let unit = question.numericRules?.unit, !unit.isEmpty else { return number }
        return "\(number) \(unit)"
    }
}

/// The error banner over the form: the server's message, plus issues no field shows.
public struct FormBanner: Sendable, Hashable {
    public var message: String
    /// Body-relative locations and messages, listed under the message.
    public var unplaced: [FieldIssue]

    public init(message: String, unplaced: [FieldIssue] = []) {
        self.message = message
        self.unplaced = unplaced
    }
}

/// Where the form wants to scroll. A new ``serial`` asks again for the same target.
public struct FormScrollRequest: Sendable, Hashable {
    public var target: FormScrollTarget
    public var serial: Int
}

/// Where VoiceOver goes, fixed when the request is made: the target's error (`toError`, after a
/// failed save) or the question's heading (a fresh form).
public struct FormVoiceOverRequest: Sendable, Hashable {
    public var target: FormScrollTarget
    public var serial: Int
    public var toError: Bool
}

public enum FormScrollTarget: Sendable, Hashable {
    case banner
    case question(String)
}

/// A text answer's length as the server counts it (code points of the stripped text).
public struct CharacterCount: Sendable, Hashable {
    public var count: Int
    public var max: Int

    public init(count: Int, max: Int) {
        self.count = count
        self.max = max
    }

    public var isOver: Bool { count > max }
    /// "120/500".
    public var text: String { "\(count)/\(max)" }
}
