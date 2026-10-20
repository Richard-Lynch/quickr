import Foundation

/// One enum option being edited (`DraftOption` in `frontend/src/lib/builder.ts`).
public struct DraftOption: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var value: String
    public var label: String
    /// Retired: still valid for historic answers, hidden from new entries.
    public var archived: Bool
    /// The value was typed by hand: stop deriving it from the label.
    public var valueEdited: Bool
    /// Exists in a published version: can be archived, never removed, and its value never changes.
    public var locked: Bool

    public init(
        id: UUID = UUID(), value: String, label: String, archived: Bool = false, valueEdited: Bool = false,
        locked: Bool = false
    ) {
        self.id = id
        self.value = value
        self.label = label
        self.archived = archived
        self.valueEdited = valueEdited
        self.locked = locked
    }

    /// A new option whose value is derived from `label`, unique among `taken` (`newDraftOption`).
    public init(label: String, taken: some Sequence<String> = [String]()) {
        let derived = BuilderText.snakeKey(label)
        self.init(
            value: label.isEmpty ? "" : BuilderText.uniqueKey(derived.isEmpty ? "option" : derived, taken: taken),
            label: label)
    }
}

/// One question being edited (`DraftQuestion`). Every constraint is the text of its input field;
/// `TopicDraft.validated…` and `DraftQuestion.validated` turn it into a `Question`.
public struct DraftQuestion: Sendable, Hashable, Identifiable {
    public internal(set) var id: UUID
    /// Fixed once published (`locked`); see `TopicDraft.setType`.
    public internal(set) var type: QuestionType
    public var key: String
    public var label: String
    public var helpText: String
    public var required: Bool
    /// The key was typed by hand: stop deriving it from the label.
    public var keyEdited: Bool
    /// Exists in the published version: key and type are immutable.
    public var locked: Bool
    // int and double
    public var min: String
    public var max: String
    public var unit: String
    public var decimals: String
    // str
    public var minLength: String
    public var maxLength: String
    public var multiline: Bool
    // enum
    public var options: [DraftOption]
    public var multiple: Bool
    public var minSelected: String
    public var maxSelected: String
    /// Published as multi-select: can never go back to single-select under this key.
    public var publishedMultiple: Bool

    /// A new, empty question (`newDraftQuestion`): required, a "Yes" / "No" choice for enums,
    /// one decimal for doubles, 0–500 characters for text.
    public init(type: QuestionType, id: UUID = UUID()) {
        self.id = id
        self.type = type
        key = ""
        label = ""
        helpText = ""
        required = true
        keyEdited = false
        locked = false
        min = ""
        max = ""
        unit = ""
        decimals = type == .double ? "1" : ""
        minLength = "0"
        maxLength = String(Question.StringRules.defaultMaxLength)
        multiline = false
        options = type == .enum ? [DraftOption(label: "Yes"), DraftOption(label: "No", taken: ["yes"])] : []
        multiple = false
        minSelected = ""
        maxSelected = ""
        publishedMultiple = false
    }

    /// A draft of a published question (`draftFromQuestion`). `locked` marks it as existing on the
    /// server: its key, type and options' values are then fixed.
    public init(question q: Question, locked: Bool, id: UUID = UUID()) {
        self.init(type: q.type, id: id)
        key = q.key
        label = q.label
        helpText = q.helpText ?? ""
        required = q.required
        keyEdited = true
        self.locked = locked
        switch q.kind {
        case .int(let r):
            min = r.min.map(String.init) ?? ""
            max = r.max.map(String.init) ?? ""
            unit = r.unit ?? ""
        case .double(let r):
            min = r.min.map(JSNumber.string) ?? ""
            max = r.max.map(JSNumber.string) ?? ""
            unit = r.unit ?? ""
            decimals = r.decimals.map(String.init) ?? ""
        case .string(let r):
            minLength = String(r.minLength)
            maxLength = String(r.maxLength)
            multiline = r.multiline
        case .choice(let r):
            options = r.options.map {
                DraftOption(value: $0.value, label: $0.label, archived: $0.archived, valueEdited: true, locked: locked)
            }
            multiple = r.multiple
            minSelected = r.minSelected.map(String.init) ?? ""
            maxSelected = r.maxSelected.map(String.init) ?? ""
            publishedMultiple = locked && r.multiple
        }
    }

    /// The label changed: derive the key from it while the key is neither hand-edited nor
    /// published (`withLabel`). `takenKeys` are the other questions' keys.
    public func withLabel(_ label: String, takenKeys: some Sequence<String>) -> DraftQuestion {
        var q = self
        q.label = label
        if keyEdited || locked { return q }
        q.key =
            BuilderText.strip(label).isEmpty ? "" : BuilderText.uniqueKey(BuilderText.snakeKey(label), taken: takenKeys)
        return q
    }

    /// The number of options a new answer may pick.
    public var activeOptionCount: Int { options.count { !$0.archived } }
}

/// A topic being created, or its questions being edited for a new version (`TopicDraft`).
/// The schedule is edited separately (TOPIC), so it isn't part of this draft.
///
/// Fields are plain `var`s for bindings; the methods keep the builder's rules (derived keys and
/// values, published keys, types and options fixed) and are what the screens should call.
public struct TopicDraft: Sendable, Hashable {
    public var name: String
    public var slug: String
    /// The slug was typed by hand: stop deriving it from the name.
    public var slugEdited: Bool
    public var description: String
    public var questions: [DraftQuestion]
    /// Only used when publishing a new version.
    public var changeNote: String

    public init(
        name: String = "", slug: String = "", slugEdited: Bool = false, description: String = "",
        questions: [DraftQuestion], changeNote: String = ""
    ) {
        self.name = name
        self.slug = slug
        self.slugEdited = slugEdited
        self.description = description
        self.questions = questions
        self.changeNote = changeNote
    }

    /// A new topic with one number question (`emptyTopicDraft`).
    public static func empty() -> TopicDraft { TopicDraft(questions: [DraftQuestion(type: .int)]) }

    /// The latest version of a topic, to edit into the next one (`draftFromTopic`).
    public static func editing(name: String, slug: String, description: String, questions: [Question]) -> TopicDraft {
        TopicDraft(
            name: name, slug: slug, slugEdited: true, description: description,
            questions: questions.map { DraftQuestion(question: $0, locked: true) })
    }

    // MARK: Topic details

    /// The slug follows the name until it's edited (`TopicMetaFields`).
    public mutating func setName(_ name: String) {
        self.name = name
        if !slugEdited { slug = BuilderText.slug(name) }
    }

    public mutating func setSlug(_ slug: String) {
        self.slug = slug
        slugEdited = true
    }

    // MARK: Questions

    public func index(of id: DraftQuestion.ID) -> Int? { questions.firstIndex { $0.id == id } }

    public subscript(id: DraftQuestion.ID) -> DraftQuestion? { index(of: id).map { questions[$0] } }

    /// Whether another question fits (`max_questions`).
    public func canAddQuestion(limits: Limits = .serverDefaults) -> Bool { questions.count < limits.maxQuestions }

    /// Appends a new question of `type` and returns its id.
    @discardableResult
    public mutating func addQuestion(_ type: QuestionType) -> DraftQuestion.ID {
        let q = DraftQuestion(type: type)
        questions.append(q)
        return q.id
    }

    /// A topic keeps at least one question, so the last one can't be removed.
    public var canRemoveQuestion: Bool { questions.count > 1 }

    /// Removes a question, published or not (the compatibility check warns about published ones).
    /// False for the last question or an unknown id.
    @discardableResult
    public mutating func removeQuestion(_ id: DraftQuestion.ID) -> Bool {
        guard canRemoveQuestion, let i = index(of: id) else { return false }
        questions.remove(at: i)
        return true
    }

    /// Moves a question to `destination` (its index once moved), like the PWA's up and down.
    public mutating func moveQuestion(_ id: DraftQuestion.ID, to destination: Int) {
        guard let i = index(of: id) else { return }
        questions.insert(questions.remove(at: i), at: Swift.max(0, Swift.min(destination, questions.count)))
    }

    /// SwiftUI's `onMove`: `offsets` move to before the item at `destination`.
    public mutating func moveQuestions(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        questions.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Inserts an unpublished copy after the question: "Mood" becomes "Mood (copy)" with a key
    /// derived from that. Returns the copy's id.
    @discardableResult
    public mutating func duplicateQuestion(_ id: DraftQuestion.ID) -> DraftQuestion.ID? {
        guard let i = index(of: id) else { return nil }
        let source = questions[i]
        var copy = source
        copy.id = UUID()
        copy.locked = false
        copy.keyEdited = false
        copy.publishedMultiple = false
        copy.options = source.options.map {
            DraftOption(value: $0.value, label: $0.label, archived: $0.archived, valueEdited: $0.valueEdited)
        }
        let label = BuilderText.strip(source.label)
        let takenKeys = questions.map(\.key)
        if label.isEmpty {
            let key = BuilderText.strip(source.key)
            copy.key = key.isEmpty ? "" : BuilderText.uniqueKey(key, taken: takenKeys)
        } else {
            let labels = Set(questions.map { BuilderText.fold($0.label) })
            var candidate = "\(label) (copy)"
            var n = 2
            while labels.contains(BuilderText.fold(candidate)) {
                candidate = "\(label) (copy \(n))"
                n += 1
            }
            copy = copy.withLabel(candidate, takenKeys: takenKeys)
        }
        questions.insert(copy, at: i + 1)
        return copy.id
    }

    /// Changes an unpublished question's type. Published keys keep their type forever (the server
    /// rejects a change); false then. Number bounds and the unit survive int ⇄ double; other
    /// type-specific fields start from the new type's defaults.
    @discardableResult
    public mutating func setType(_ id: DraftQuestion.ID, to type: QuestionType) -> Bool {
        guard let i = index(of: id), !questions[i].locked else { return false }
        let old = questions[i]
        if old.type == type { return true }
        var q = DraftQuestion(type: type)
        q.id = old.id
        q.key = old.key
        q.label = old.label
        q.helpText = old.helpText
        q.required = old.required
        q.keyEdited = old.keyEdited
        let numeric: Set<QuestionType> = [.int, .double]
        if numeric.contains(old.type) && numeric.contains(type) {
            q.min = old.min
            q.max = old.max
            q.unit = old.unit
        }
        questions[i] = q
        return true
    }

    /// Sets the label, deriving the key from it until the key is edited or published.
    public mutating func setLabel(_ id: DraftQuestion.ID, _ label: String) {
        guard let i = index(of: id) else { return }
        let taken = questions.indices.filter { $0 != i }.map { questions[$0].key }
        questions[i] = questions[i].withLabel(label, takenKeys: taken)
    }

    /// Types a key by hand. Published keys never change: false then.
    @discardableResult
    public mutating func setKey(_ id: DraftQuestion.ID, _ key: String) -> Bool {
        guard let i = index(of: id), !questions[i].locked else { return false }
        questions[i].key = key
        questions[i].keyEdited = true
        return true
    }

    /// Turns multi-select on or off. A question published as multi-select can't go back (its
    /// answers are lists): false then.
    @discardableResult
    public mutating func setMultiple(_ id: DraftQuestion.ID, _ multiple: Bool) -> Bool {
        guard let i = index(of: id) else { return false }
        if !multiple && questions[i].publishedMultiple { return false }
        questions[i].multiple = multiple
        return true
    }

    // MARK: Options

    /// Appends an option with this label (trimmed) and a unique value derived from it. Nil for a
    /// blank label, an unknown question or a question that isn't a choice.
    @discardableResult
    public mutating func addOption(to id: DraftQuestion.ID, label: String) -> DraftOption.ID? {
        let label = BuilderText.strip(label)
        guard !label.isEmpty, let i = index(of: id), questions[i].type == .enum else { return nil }
        let option = DraftOption(label: label, taken: questions[i].options.map(\.value))
        questions[i].options.append(option)
        return option.id
    }

    /// Renames an option. Its value follows the label until edited by hand or published.
    public mutating func setOptionLabel(_ id: DraftQuestion.ID, option: DraftOption.ID, _ label: String) {
        guard let (i, j) = locate(id, option) else { return }
        questions[i].options[j].label = label
        let o = questions[i].options[j]
        if o.locked || o.valueEdited { return }
        let taken = questions[i].options.indices.filter { $0 != j }.map { questions[i].options[$0].value }
        let derived = BuilderText.snakeKey(label)
        questions[i].options[j].value = BuilderText.uniqueKey(derived.isEmpty ? "option" : derived, taken: taken)
    }

    /// Types an option's value by hand. A published option's value never changes: false then.
    @discardableResult
    public mutating func setOptionValue(_ id: DraftQuestion.ID, option: DraftOption.ID, _ value: String) -> Bool {
        guard let (i, j) = locate(id, option), !questions[i].options[j].locked else { return false }
        questions[i].options[j].value = value
        questions[i].options[j].valueEdited = true
        return true
    }

    /// Removes an unpublished option. Published ones can only be retired (`setOptionArchived`),
    /// or historic answers would be orphaned: false then.
    @discardableResult
    public mutating func removeOption(_ id: DraftQuestion.ID, option: DraftOption.ID) -> Bool {
        guard let (i, j) = locate(id, option), !questions[i].options[j].locked else { return false }
        questions[i].options.remove(at: j)
        return true
    }

    /// Retires (archives) or restores an option.
    public mutating func setOptionArchived(_ id: DraftQuestion.ID, option: DraftOption.ID, _ archived: Bool) {
        guard let (i, j) = locate(id, option) else { return }
        questions[i].options[j].archived = archived
    }

    /// Moves an option to `destination` (its index once moved).
    public mutating func moveOption(_ id: DraftQuestion.ID, option: DraftOption.ID, to destination: Int) {
        guard let (i, j) = locate(id, option) else { return }
        var options = questions[i].options
        options.insert(options.remove(at: j), at: Swift.max(0, Swift.min(destination, options.count)))
        questions[i].options = options
    }

    /// SwiftUI's `onMove` for a question's options.
    public mutating func moveOptions(_ id: DraftQuestion.ID, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let i = index(of: id) else { return }
        questions[i].options.move(fromOffsets: offsets, toOffset: destination)
    }

    private func locate(_ id: DraftQuestion.ID, _ option: DraftOption.ID) -> (Int, Int)? {
        guard let i = index(of: id), let j = questions[i].options.firstIndex(where: { $0.id == option }) else {
            return nil
        }
        return (i, j)
    }
}

extension Array {
    /// SwiftUI's `move(fromOffsets:toOffset:)`, which Foundation lacks.
    fileprivate mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.filter { indices.contains($0) }.map { self[$0] }
        let before = offsets.count { $0 < destination }
        for i in offsets.sorted(by: >) where indices.contains(i) { remove(at: i) }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(destination - before, count)))
    }
}
