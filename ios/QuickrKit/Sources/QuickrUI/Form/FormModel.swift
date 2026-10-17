import Foundation
import Observation
import QuickrCore

/// The answer form behind the record and edit screens (the PWA's `EntryForm`): one input per
/// question, validation on touch and on submit, the focus rules, "Same as last time", the
/// single-chip auto-save and fix mode. No persistence: ``submit()`` hands back the body and the
/// caller saves it; ``apply(_:)`` puts a server rejection back on the fields.
///
/// Focus rules (`frontend/docs/design-loop.md`), driven through ``focus``:
/// - On ``appear()`` a new entry focuses its first unanswered question when that takes typing
///   (number or text). Choices are never focused, only scrolled to.
/// - Picking a single-select answer moves focus to the next unanswered typed question, or
///   drops it (new entries only).
/// - Next/Return in a field moves to the next unanswered typed question instead of saving.
/// - A failed submit scrolls to the first invalid question and focuses it if it takes typing.
///
/// Validation follows react-hook-form's `onTouched`: a question shows its error once it has
/// been left (a field blurred, or another question used after a choice), then on every change.
@Observable @MainActor
public final class FormModel {
    public enum Mode: Sendable, Hashable {
        /// A new entry. `last` offers "Same as last time"; a single-number topic starts from it.
        case create(last: LastEntry? = nil)
        /// A new entry the server rejected: its answers back on the form with the problem's
        /// errors. No prefill, no auto-save, no focus moves on pick.
        case fix(answers: [String: AnswerValue], problem: Problem?)
        /// Editing an entry against its own version: archived options it holds stay shown and
        /// valid, and the body has every key (blank clears).
        case edit(answers: [String: AnswerValue])
    }

    public let questions: [Question]
    public let mode: Mode
    /// Archived option values that stay valid, by question key (edit mode only).
    public let allowArchived: [String: Set<String>]
    /// "Same as last time", when the latest entry has anything reusable (new entries only).
    public let prefill: FormPrefill?
    /// The question whose pick saves the entry at once: a new entry of a topic whose only
    /// question is a single-select shown as chips (the PWA's `submitOnPick`).
    public let autoSaveKey: String?

    public private(set) var inputs: [String: AnswerInput]
    public private(set) var touched: Set<String> = []
    /// Answer errors by question key.
    public private(set) var errors: [String: String] = [:]
    /// Server errors on `captured_at`, `source` and `notes` (fix mode); the details section's.
    public private(set) var metaErrors: [EntryFormField: String] = [:]
    public private(set) var banner: FormBanner?
    /// The question whose field has keyboard focus, or nil. Views mirror it into `FocusState`
    /// and report the user's own focus changes through ``focusChanged(_:isFocused:)``.
    public private(set) var focus: String?
    public private(set) var scrollRequest: FormScrollRequest?
    /// An auto-save is being saved: further picks are ignored (and the chips disabled) until
    /// ``autoSaveFinished(succeeded:)``.
    public private(set) var isAutoSaving = false

    private let byKey: [String: Question]
    private let initialInputs: [String: AnswerInput]
    /// The inputs before "Same as last time" filled them; non-nil while it is applied.
    private var beforePrefill: [String: AnswerInput]?
    /// The question last used (focused or picked), so leaving it counts as a touch.
    private var active: String?
    private var scrollSerial = 0
    /// The pick the last successful auto-save logged; tapping it again logs nothing.
    private var autoSaved: AnswerInput?
    /// The screen has run ``appear()``, or the user acted first; either way it never runs again.
    private var settled = false

    public init(questions: [Question], mode: Mode = .create()) {
        self.questions = questions
        self.mode = mode
        self.byKey = Dictionary(questions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var inputs = AnswerInput.inputs(for: questions)
        var allowArchived: [String: Set<String>] = [:]
        var prefill: FormPrefill?
        var autoSaveKey: String?
        switch mode {
        case .create(let last):
            prefill = last.flatMap { FormPrefill($0, questions: questions) }
            if questions.count == 1, let quick = QuickLog(questions: questions) {
                switch quick {
                case .chips(let question, _):
                    autoSaveKey = question.key
                case .number(let question):
                    // A single-number topic starts from the last value, like its tile.
                    let start = QuickLog.initialText(for: question, last: last?.answers[question.key])
                    if !start.isEmpty { inputs[question.key] = .text(start) }
                }
            }
        case .fix(let answers, _):
            inputs = AnswerInput.inputs(for: questions, from: answers)
        case .edit(let answers):
            inputs = AnswerInput.inputs(for: questions, from: answers)
            allowArchived = AnswerInput.archivedValues(in: answers, for: questions)
        }
        self.inputs = inputs
        self.initialInputs = inputs
        self.allowArchived = allowArchived
        self.prefill = prefill
        self.autoSaveKey = autoSaveKey
        if case .fix(_, let problem?) = mode { place(problem) }
    }

    private var isNewEntry: Bool {
        if case .create = mode { return true }
        return false
    }

    // MARK: - Reading

    public func input(for key: String) -> AnswerInput {
        inputs[key] ?? byKey[key].map(AnswerInput.empty(for:)) ?? .text("")
    }

    /// The options a choice question offers: the active ones, plus archived ones this entry
    /// already holds when editing (labelled "(retired)").
    public func options(for question: Question) -> [EnumOption] {
        question.visibleOptions(keeping: allowArchived[question.key] ?? [])
    }

    /// The counter under a text field: always for a multi-line one, otherwise from 80% of the
    /// limit or while under the minimum. Nil for other types.
    public func characterCount(for key: String) -> CharacterCount? {
        guard case .string(let rules)? = byKey[key]?.kind, case .text(let raw) = input(for: key) else { return nil }
        let count = AnswerValidator.characterCount(ServerText.strip(raw))
        let shown = rules.multiline || count * 5 >= rules.maxLength * 4 || (count > 0 && count < rules.minLength)
        return shown ? CharacterCount(count: count, max: rules.maxLength) : nil
    }

    /// The next question after `key` that is unanswered and takes typing, or nil.
    public func nextField(after key: String) -> String? {
        guard let index = questions.firstIndex(where: { $0.key == key }) else { return nil }
        return questions[(index + 1)...].first { Self.takesTyping($0) && !input(for: $0.key).hasValue }?.key
    }

    /// Number and text questions get keyboard focus; choices never do.
    public static func takesTyping(_ question: Question) -> Bool { question.type != .enum }

    // MARK: - Editing

    /// Sets one answer. A touched question revalidates. Picking a single-select answer moves
    /// focus on (new entries), and on the ``autoSaveKey`` question it submits: the returned body
    /// is the entry to save now (nil otherwise, or when the form is invalid). The caller saves it
    /// and reports back with ``autoSaveFinished(succeeded:)``; until then picks are ignored, and a
    /// pick that was already saved is never saved again.
    @discardableResult
    public func change(_ key: String, to input: AnswerInput) -> AnswersBody? {
        guard let question = byKey[key] else { return nil }
        if key == autoSaveKey && (isAutoSaving || input == autoSaved) { return nil }
        settled = true
        inputs[key] = input
        if !Self.takesTyping(question) { use(key) }
        if touched.contains(key) { validate(key) }
        guard question.type == .enum, !question.isMultiSelect, input.hasValue else { return nil }
        if key == autoSaveKey {
            guard let body = submit() else { return nil }
            isAutoSaving = true
            return body
        }
        if isNewEntry { focus = nextField(after: key) }
        return nil
    }

    /// The auto-saved entry was saved (or queued), or it failed: picks work again, and after a
    /// failure tapping the same answer retries.
    public func autoSaveFinished(succeeded: Bool) {
        guard isAutoSaving, let key = autoSaveKey else { return }
        isAutoSaving = false
        autoSaved = succeeded ? inputs[key] : nil
    }

    /// A field gained or lost keyboard focus (the user's tap, or the view applying ``focus``).
    /// Losing it touches the question.
    public func focusChanged(_ key: String, isFocused: Bool) {
        if isFocused {
            // Focus the model didn't ask for is the user's: initial focus no longer applies.
            if focus != key { settled = true }
            focus = key
            use(key)
        } else {
            if focus == key { focus = nil }
            if active == key { active = nil }
            touch(key)
        }
    }

    /// Next/Return in `key`'s field: on to the next unanswered typed question, else the keyboard
    /// goes away. Never submits.
    public func advance(from key: String) {
        focus = nextField(after: key)
    }

    public func dismissKeyboard() {
        focus = nil
    }

    /// The screen appeared: focus (or scroll to) the first unanswered question of a new entry,
    /// or show the first error in fix mode. Only once, and not after the user has picked, typed
    /// or focused a field: it would take focus away from them.
    public func appear() {
        guard !settled else { return }
        settled = true
        if !errors.isEmpty || banner != nil {
            revealFirstError()
            return
        }
        guard isNewEntry, autoSaveKey == nil,
            let first = questions.first(where: { !input(for: $0.key).hasValue })
        else { return }
        if Self.takesTyping(first) {
            focus = first.key
        }
        scroll(to: .question(first.key))
    }

    // MARK: - Same as last time

    /// Whether the "Same as last time" button shows: there is a prefill, the topic doesn't save
    /// on pick, and filling would change the starting answers (or it is applied, to undo).
    public var showsSameAsLast: Bool {
        guard let prefill, autoSaveKey == nil else { return false }
        return isSameAsLastApplied || questions.contains { prefill.inputs[$0.key] != initialInputs[$0.key] }
    }

    public var isSameAsLastApplied: Bool { beforePrefill != nil }

    /// One tap fills every answer from the last entry; the next tap puts back what was there.
    public func toggleSameAsLast() {
        if let before = beforePrefill {
            inputs = before
            errors = [:]
            beforePrefill = nil
            return
        }
        guard let prefill else { return }
        settled = true
        beforePrefill = inputs
        for question in questions {
            guard let input = prefill.inputs[question.key] else { continue }
            inputs[question.key] = input
            // A blanked field loses an error that no longer applies; a touched one re-checks.
            if input.hasValue || touched.contains(question.key) {
                validate(question.key)
            } else {
                errors[question.key] = nil
            }
        }
    }

    // MARK: - Submitting

    /// Validates every question. Valid: the body for the mode. Invalid: nil, with every error
    /// shown, the view scrolled to the first and focus on it when it takes typing.
    public func submit() -> AnswersBody? {
        settled = true
        banner = nil
        metaErrors = [:]
        touched.formUnion(questions.map(\.key))
        let validator = AnswerValidator(questions: questions, allowArchived: allowArchived)
        switch validator.validate(inputs) {
        case .success(let valid):
            errors = [:]
            if case .edit = mode { return .update(valid.all) }
            return .create(valid.answered)
        case .failure(let invalid):
            errors = invalid.byKey
            revealFirstError()
            return nil
        }
    }

    /// A rejected save (fix mode): server errors on their questions, `captured_at`, `source` and
    /// `notes` in ``metaErrors``, the rest under the ``banner``.
    public func apply(_ problem: Problem) {
        place(problem)
        revealFirstError()
    }

    private func place(_ problem: Problem) {
        let mapped = ProblemMapping.entryForm(problem, questionKeys: Set(byKey.keys))
        banner = FormBanner(message: mapped.banner, unplaced: mapped.unplaced)
        metaErrors = [:]
        for (field, message) in mapped.fields {
            if case .answer(let key) = field {
                errors[key] = message
                touched.insert(key)
            } else {
                metaErrors[field] = message
            }
        }
    }

    // MARK: - Internals

    /// Using a question leaves the one used before, which touches it.
    private func use(_ key: String) {
        if let previous = active, previous != key { touch(previous) }
        active = key
    }

    private func touch(_ key: String) {
        touched.insert(key)
        validate(key)
    }

    private func validate(_ key: String) {
        guard let question = byKey[key] else { return }
        switch AnswerValidator.validate(question, inputs[key], allowArchived: allowArchived[key] ?? []) {
        case .success: errors[key] = nil
        case .failure(let message): errors[key] = message.message
        }
    }

    private func revealFirstError() {
        if let first = questions.first(where: { errors[$0.key] != nil }) {
            focus = Self.takesTyping(first) ? first.key : nil
            scroll(to: .question(first.key))
        } else if banner != nil {
            scroll(to: .banner)
        }
    }

    private func scroll(to target: FormScrollTarget) {
        scrollSerial += 1
        scrollRequest = FormScrollRequest(target: target, serial: scrollSerial)
    }
}
