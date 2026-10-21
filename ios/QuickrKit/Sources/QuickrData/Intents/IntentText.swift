import AppIntents
import Foundation
import QuickrCore

/// What intents say: prompts, the logged summary and errors (Siri may not show a snippet, so
/// the dialog carries the result on its own; research/04-siri.md §1).
public enum IntentText {
    /// "How many cups?" / "What's your weight?" for a number question.
    public static func prompt(for question: Question) -> String {
        if let unit = question.numericRules?.unit, !unit.isEmpty { return "How many \(unit) for \(question.label)?" }
        return "What's your \(question.label)?"
    }

    /// A spoken number as the question's answer: an int question's whole number stays an int
    /// (anything else is left for validation to refuse).
    public static func answer(_ value: Double, for question: Question) -> AnswerValue {
        if case .int = question.kind, value.rounded() == value, let n = Int(exactly: value) { return .int(n) }
        return .double(value)
    }

    /// "Coffee: 2 cups" / "Mood: Good" / "Sleep: 7.5 h, Good": the topic and its answers in question
    /// order, options by label.
    public static func summary(_ answers: [String: AnswerValue], topic: Topic) -> String {
        let parts = topic.questions.compactMap { question -> String? in
            guard let answer = answers[question.key] else { return nil }
            return text(answer, for: question)
        }
        return parts.isEmpty ? topic.name : "\(topic.name): \(parts.joined(separator: ", "))"
    }

    /// "Nothing is due." / "Water is due." / "Water and Meds are due." / "Water, Meds and Stretch
    /// are due."
    public static func dueSentence(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Nothing is due."
        case 1: return "\(names[0]) is due."
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names.last!) are due."
        }
    }

    public static func text(_ answer: AnswerValue, for question: Question) -> String {
        let unit = question.numericRules?.unit.flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
        switch answer {
        case .int(let n): return "\(n)\(unit)"
        case .double(let x): return "\(JSNumber.string(x))\(unit)"
        case .string(let value): return label(value, in: question)
        case .strings(let values): return values.map { label($0, in: question) }.joined(separator: ", ")
        }
    }

    private static func label(_ value: String, in question: Question) -> String {
        guard case .choice(let rules) = question.kind else { return value }
        return rules.options.first { $0.value == value }?.label ?? value
    }
}

extension IntentLogging.Failure: CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource { "\(description)" }
}
