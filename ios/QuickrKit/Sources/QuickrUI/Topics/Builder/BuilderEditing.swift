import Foundation
import Observation
import QuickrCore

/// What the builder's views edit (the PWA's `TopicBuilder` over a react-hook-form `TopicDraft`):
/// the draft, its field errors, which cards are open, and the live preview. ``NewTopicModel``
/// creates a topic with it; ``EditQuestionsModel`` publishes a topic's next version.
@MainActor
public protocol BuilderEditing: AnyObject, Observable {
    var draft: TopicDraft { get set }
    var draftErrors: [DraftField: String] { get }
    var expansion: QuestionExpansion { get set }
    /// "Add an option…" text not added yet, by question: kept across the panes and a closed card,
    /// and counted as an unsaved change.
    var newOptionLabels: [DraftQuestion.ID: String] { get set }
    var preview: BuilderPreview { get }
    var limits: Limits { get }
}

extension BuilderEditing {
    /// "Add question": a new question of `type` at the end, its card open.
    public func addQuestion(_ type: QuestionType) {
        guard draft.canAddQuestion(limits: limits) else { return }
        expansion.opened(draft.addQuestion(type))
    }

    /// "Add" next to "Add an option…": the typed label (trimmed) as a new option.
    public func addPendingOption(to id: DraftQuestion.ID) {
        let label = JSNumber.trim(newOptionLabels[id] ?? "")
        guard !label.isEmpty else { return }
        _ = draft.addOption(to: id, label: label)
        newOptionLabels[id] = nil
    }

    /// Some question still on the draft has option text typed but not added.
    public var hasPendingOptionText: Bool {
        newOptionLabels.contains { id, text in draft.index(of: id) != nil && !JSNumber.trim(text).isEmpty }
    }

    /// Whether a question's card is open: by choice, or because one of its fields shows an error.
    public func isOpen(_ id: DraftQuestion.ID) -> Bool {
        guard let index = draft.index(of: id) else { return false }
        return expansion.isOpen(id, hasError: draftErrors.hasError(inQuestion: index))
    }
}

extension Dictionary where Key == DraftField {
    /// Whether any field of question `index` has an error (its card shows the alert icon).
    public func hasError(inQuestion index: Int) -> Bool {
        keys.contains { field in
            if case .question(index, _) = field { return true }
            return false
        }
    }
}

/// Which question cards are open (`QuestionsEditor`'s `expanded`). Creating a topic starts with
/// every card open; editing a published one with none. An added question opens. A card whose
/// fields show an error stays open whatever this says.
public struct QuestionExpansion: Sendable, Hashable {
    public enum Start: Sendable {
        case all
        case none
    }

    public private(set) var open: Set<DraftQuestion.ID>

    public init(_ start: Start, questions: [DraftQuestion]) {
        open = start == .all ? Set(questions.map(\.id)) : []
    }

    public func isOpen(_ id: DraftQuestion.ID, hasError: Bool = false) -> Bool { hasError || open.contains(id) }

    public mutating func toggle(_ id: DraftQuestion.ID) {
        if open.remove(id) == nil { open.insert(id) }
    }

    public mutating func opened(_ id: DraftQuestion.ID) { open.insert(id) }

    /// Every card of `questions` is open: the button says "Collapse all".
    public func allOpen(_ questions: [DraftQuestion]) -> Bool { questions.allSatisfy { open.contains($0.id) } }

    /// "Expand all" / "Collapse all".
    public mutating func toggleAll(_ questions: [DraftQuestion]) {
        open = allOpen(questions) ? [] : Set(questions.map(\.id))
    }

    /// The button's title, shown once there is more than one question.
    public static func toggleAllTitle(allOpen: Bool) -> String { allOpen ? "Collapse all" : "Expand all" }
}

/// The live preview (`FormPreview`): the form being built as it will look, each question the
/// draft's best-effort version (`DraftQuestion.preview`), with answers that validate as they
/// would on the record screen. Answers are kept by question key, so they survive edits to the
/// question; one whose shape no longer fits (a choice became a number) starts blank. An error
/// shows once its question has been left.
@MainActor @Observable
public final class BuilderPreview {
    public private(set) var inputs: [String: AnswerInput] = [:]
    public private(set) var touched: Set<String> = []

    public init() {}

    /// The questions as the preview shows them.
    public static func questions(_ draft: TopicDraft) -> [Question] {
        draft.questions.enumerated().map { index, question in question.preview(index: index) }
    }

    public func input(for question: Question) -> AnswerInput {
        switch (inputs[question.key], question.isMultiSelect) {
        case (.text(let text)?, false): .text(text)
        case (.selection(let values)?, true): .selection(values)
        default: .empty(for: question)
        }
    }

    public func set(_ input: AnswerInput, for question: Question) { inputs[question.key] = input }

    /// The question was left (a field lost focus, or another question was used).
    public func leave(_ question: Question) { touched.insert(question.key) }

    public func error(for question: Question) -> String? {
        guard touched.contains(question.key) else { return nil }
        if case .failure(let message) = AnswerValidator.validate(question, input(for: question)) {
            return message.message
        }
        return nil
    }

    /// Back to a blank form (an editor that reloaded its topic).
    public func reset() {
        inputs = [:]
        touched = []
    }
}

extension DraftQuestion {
    /// The key field's hint (`QuestionCard`).
    public var keyHint: String {
        if locked { return "Published keys never change" }
        return keyEdited ? "Edited by hand" : "Follows the question text"
    }

    /// The type's hint: fixed once published, otherwise what the type is for.
    public var typeHint: String { locked ? "Types are fixed once published" : type.builderHint }

    /// "Allow multiple selections"' hint.
    public var multipleHint: String {
        if publishedMultiple { return "Published as multi-select — can’t go back to single-select" }
        if locked && multiple { return "Existing answers will count as one-option selections" }
        return "Answers become a list, e.g. symptoms or tags"
    }

    /// A published multi-select can't be turned back into a single-select.
    public var canToggleMultiple: Bool { !(publishedMultiple && multiple) }
}
