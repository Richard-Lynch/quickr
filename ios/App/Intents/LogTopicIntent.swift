import AppIntents
import QuickrCore
import QuickrData
import SwiftUI

/// "Log Sleep in quickR": any topic by voice (research/04-siri.md §2, with the spike's findings).
///
/// 1. On Apple Intelligence phones, one sentence first ("What's your Sleep entry?"), mapped to
///    answers by the on-device model (`OnDeviceAnswerExtractor`; any failure: no answers).
/// 2. Then each required question still missing or invalid, one Siri turn each: a number
///    (`requestValue`), an option (`requestDisambiguation`), several options (`requestChoice`
///    until "Done") or text (`requestValue`). The same slot parameter is asked again for each
///    question (spike S1); time waiting for the user doesn't count toward the 30 s (S2). An answer
///    that doesn't validate is said and asked again, three times at most.
/// 3. A confirmation snippet (`EntryDraftSnippetIntent`) shows every answer, optional ones too,
///    with chips, toggles and ± buttons; each tap edits the held draft (`IntentDrafts`).
/// 4. Commit (`IntentLogging.log`: durable before returning, random id), then the dialog says what
///    was logged (Siri AI may show no snippet). Undoable.
///
/// Widgets, Controls and the Action button can't prompt: they use `LogEntryIntent` with values,
/// or `RepeatLastEntryIntent`.
struct LogTopicIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Log Topic"
    static let description = IntentDescription("Logs an entry for a topic in quickR, asking each question.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Topic") var topic: TopicEntity
    /// The one-sentence answer (the Foundation Model path); asked when the model is ready.
    @Parameter(title: "What to Log") var utterance: String?
    // The slots the question loop asks through, once per question.
    @Parameter(title: "Number") var numberSlot: Double?
    @Parameter(title: "Option") var optionSlot: QuestionOptionEntity?
    @Parameter(title: "Text") var textSlot: String?

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$topic)") }

    /// How often one question is asked before giving up.
    static let attempts = 3

    init() {}

    init(topic: TopicEntity) {
        self.topic = topic
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let context = IntentWrites.context() else { throw IntentLogging.Failure.noStore }
        let (_, current) = try await IntentLogging.topic(topic.id, in: context)
        var draft = IntentDraft(topic: current)

        let extractor = OnDeviceAnswerExtractor()
        if extractor.isAvailable {
            let said: String
            if let utterance {
                said = utterance
            } else {
                said = try await $utterance.requestValue("What's your \(current.name) entry?")
            }
            // At most `AnswerExtraction.deadline`; only this intent's own cancellation throws.
            for (key, value) in try await extractor.extract(said, topic: current) ?? [:] { draft.answer(key, value) }
        }
        draft = try await ask(draft)

        IntentDrafts.put(draft)
        defer { IntentDrafts.remove(draft.id) }
        let answers = try await confirm(draft)
        let logged = try await IntentLogging.log(topicId: current.id, answers: answers, in: context)
        let summary = IntentText.summary(logged.answers, topic: logged.topic)
        await IntentUndo.register(undoManager, logged: logged, context: context)
        return .result(value: summary, dialog: "Logged \(summary).")
    }

    /// Step 3: the snippet until the user confirms a valid draft. The system's Log button can't be
    /// disabled, so a draft the snippet's edits left invalid (a multi-select short of its minimum,
    /// a required one emptied) is shown again with the problem said, a few times at most.
    private func confirm(_ draft: IntentDraft) async throws -> [String: AnswerValue] {
        var dialog: IntentDialog = "Log \(IntentText.summary(draft.answers, topic: draft.topic))?"
        for round in 1...Self.attempts {
            try await requestConfirmation(
                actionName: .log, dialog: dialog, snippetIntent: EntryDraftSnippetIntent(draftID: draft.id.uuidString))
            // The edits live only in the held draft: one that's gone (evicted, or another process)
            // must not fall back to the answers before the edits.
            guard let confirmed = IntentDrafts.get(draft.id) else {
                throw IntentLogging.Failure.invalid(
                    "This entry isn't open any more. Ask again to log \(draft.topic.name).")
            }
            switch confirmed.validated {
            case .success(let answers): return answers
            case .failure(let failure):
                guard round < Self.attempts else { throw failure }
                dialog = "\(failure.description) Fix it, then log."
            }
        }
        throw IntentLogging.Failure.invalid("Couldn't log \(draft.topic.name).")
    }

    /// Step 2: asks until every required question has a valid answer.
    private func ask(_ start: IntentDraft) async throws -> IntentDraft {
        var draft = start
        var asked: (key: String, times: Int, problem: String?) = ("", 0, nil)
        while let next = draft.next {
            let key = next.question.key
            asked = asked.key == key ? (key, asked.times + 1, asked.problem) : (key, 1, nil)
            guard asked.times <= Self.attempts else {
                throw IntentLogging.Failure.invalid(asked.problem ?? "\(next.question.label) is required.")
            }
            let again = asked.problem.map { "\($0) " } ?? ""
            let problem: String?
            switch next {
            case .number(let question):
                let value = try await $numberSlot.requestValue("\(again)\(IntentText.prompt(for: question))")
                problem = draft.answer(key, IntentText.answer(value, for: question))
            case .option(let question, let options):
                let entities = options.map { QuestionOptionEntity(topicId: draft.topic.id, key: key, option: $0) }
                let picked = try await $optionSlot.requestDisambiguation(
                    among: entities, dialog: "\(again)Which \(question.label)?")
                problem = draft.answer(key, .string(picked.value ?? ""))
            case .options(let question, let options):
                problem = draft.answer(key, .strings(try await choose(question, options, again: again)))
            case .text(let question):
                let text = try await $textSlot.requestValue("\(again)What's your \(question.label)?")
                problem = draft.answer(key, .string(text))
            }
            asked.problem = problem
        }
        return draft
    }

    /// A multi-select by voice: one option per turn until "Done" (the snippet's toggles are the
    /// better way; this is for voice only).
    private func choose(_ question: Question, _ options: [EnumOption], again: String) async throws -> [String] {
        var picked: [String] = []
        let done = IntentChoiceOption(title: "Done")
        while picked.count < options.count {
            let remaining = options.filter { !picked.contains($0.value) }
            let choices = remaining.map { IntentChoiceOption(title: "\($0.label)") }
            let dialog: IntentDialog =
                picked.isEmpty ? "\(again)\(question.label): pick one." : "\(question.label): another, or Done?"
            let chosen = try await requestChoice(between: choices + (picked.isEmpty ? [] : [done]), dialog: dialog)
            guard chosen != done, let index = choices.firstIndex(of: chosen) else { break }
            picked.append(remaining[index].value)
        }
        return options.map(\.value).filter(picked.contains)
    }
}

// MARK: - The confirmation snippet

/// The draft as the confirmation shows it: every question, with chips, toggles and ± buttons
/// (snippets have no text fields: text is voice-only). Re-performed after each tap.
struct EntryDraftSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Entry"
    static let isDiscoverable = false

    @Parameter(title: "Draft") var draftID: String

    init() {}

    init(draftID: String) {
        self.draftID = draftID
    }

    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let draft = UUID(uuidString: draftID).flatMap(IntentDrafts.get)
        return .result(view: EntryDraftSnippet(draft: draft))
    }
}

/// A chip: picks one option.
struct SetDraftOptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick Option"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Draft") var draftID: String
    @Parameter(title: "Question") var key: String
    @Parameter(title: "Value") var value: String

    init() {}

    init(draftID: UUID, key: String, value: String) {
        self.draftID = draftID.uuidString
        self.key = key
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) { IntentDrafts.update(id) { $0.set(key, option: value) } }
        return .result()
    }
}

/// A toggle: adds or removes one option of a multi-select.
struct ToggleDraftOptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Option"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Draft") var draftID: String
    @Parameter(title: "Question") var key: String
    @Parameter(title: "Value") var value: String

    init() {}

    init(draftID: UUID, key: String, value: String) {
        self.draftID = draftID.uuidString
        self.key = key
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) { IntentDrafts.update(id) { $0.toggle(key, option: value) } }
        return .result()
    }
}

/// ±: moves a number one step.
struct StepDraftNumberIntent: AppIntent {
    static let title: LocalizedStringResource = "Step Number"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Draft") var draftID: String
    @Parameter(title: "Question") var key: String
    @Parameter(title: "Direction") var direction: Int

    init() {}

    init(draftID: UUID, key: String, direction: Int) {
        self.draftID = draftID.uuidString
        self.key = key
        self.direction = direction
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) { IntentDrafts.update(id) { $0.step(key, by: direction) } }
        return .result()
    }
}

/// The snippet's view: system styling (it renders in the system's UI, not the app's).
struct EntryDraftSnippet: View {
    let draft: IntentDraft?

    var body: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(draft.topic.questions, id: \.key) { question in
                    row(question, draft)
                }
            }
            .padding()
        } else {
            Text("This entry isn't open any more. Ask again to log it.").padding()
        }
    }

    @ViewBuilder
    private func row(_ question: Question, _ draft: IntentDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.required ? question.label : "\(question.label) (optional)").font(.subheadline.bold())
            switch question.kind {
            case .int, .double:
                HStack {
                    Button(intent: StepDraftNumberIntent(draftID: draft.id, key: question.key, direction: -1)) {
                        Image(systemName: "minus")
                    }
                    .accessibilityLabel("Less \(question.label)")
                    Text(draft.answers[question.key].map { IntentText.text($0, for: question) } ?? "–")
                        .monospacedDigit().frame(minWidth: 64)
                    Button(intent: StepDraftNumberIntent(draftID: draft.id, key: question.key, direction: 1)) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("More \(question.label)")
                }
                .buttonStyle(.bordered)
            case .choice(let rules) where rules.multiple:
                ForEach(rules.activeOptions, id: \.value) { option in
                    Toggle(
                        isOn: Self.picked(option.value, in: draft.answers[question.key]),
                        intent: ToggleDraftOptionIntent(draftID: draft.id, key: question.key, value: option.value)
                    ) { Text(option.label) }
                }
            case .choice(let rules):
                HStack {
                    ForEach(rules.activeOptions, id: \.value) { option in
                        let selected = draft.answers[question.key] == .string(option.value)
                        Button(intent: SetDraftOptionIntent(draftID: draft.id, key: question.key, value: option.value))
                        {
                            Text(option.label)
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : .secondary)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            case .string:
                Text(draft.answers[question.key].map { IntentText.text($0, for: question) } ?? "Say it to Siri")
                    .foregroundStyle(.secondary)
            }
            if let problem = draft.problem(for: question) {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    static func picked(_ value: String, in answer: AnswerValue?) -> Bool {
        if case .strings(let values) = answer { return values.contains(value) }
        return false
    }
}
