import Foundation
import QuickrCore
import Synchronization

#if canImport(FoundationModels)
import FoundationModels
#endif

/// "What's your Sleep entry?" → "seven and a half hours, slept well" → answers
/// (research/04-siri.md §2 step 2), on Apple Intelligence phones only: the on-device model fills a
/// schema built from the topic's questions. What it returns is only a head start: each answer is
/// checked like any other (`IntentDraft.answer`), and the question loop asks for whatever is
/// missing or invalid. Any failure (no model, rate limits in the background, an error, taking
/// longer than `deadline`) is "no answers": the loop asks everything. Only the intent's own
/// cancellation (the system's 30 s, spike S3) is thrown, so it isn't mistaken for "no answers".
public protocol AnswerExtractor: Sendable {
    /// Whether to ask for a one-sentence answer at all (the model is ready).
    var isAvailable: Bool { get }
    /// The answers `utterance` gives for `topic`'s questions, keyed like the questions; nil when
    /// the model couldn't be used. Throws only `CancellationError`, when the caller was cancelled.
    func extract(_ utterance: String, topic: Topic) async throws -> [String: AnswerValue]?
}

/// No model: the loop asks every question.
public struct NoAnswerExtractor: AnswerExtractor {
    public init() {}
    public var isAvailable: Bool { false }
    public func extract(_ utterance: String, topic: Topic) async throws -> [String: AnswerValue]? { nil }
}

/// The schema and the mapping, free of the model so they're host-tested.
public enum AnswerExtraction {
    /// How a question is described to the model, and what it may generate for it.
    public enum Field: Sendable, Hashable {
        case number(description: String)
        case text(description: String)
        /// The option **labels** (what people say), mapped back to values.
        case choice(description: String, labels: [String])
        case choices(description: String, labels: [String])
    }

    /// One field per question, keyed by the question key: "Hours slept (h)", the option labels.
    public static func fields(for questions: [Question]) -> [(key: String, field: Field)] {
        questions.map { question in
            var description = question.label
            if let unit = question.numericRules?.unit, !unit.isEmpty { description += " (\(unit))" }
            switch question.kind {
            case .int, .double: return (question.key, .number(description: description))
            case .string: return (question.key, .text(description: description))
            case .choice(let rules):
                let labels = rules.activeOptions.map(\.label)
                return (
                    question.key,
                    rules.multiple
                        ? .choices(description: description, labels: labels)
                        : .choice(description: description, labels: labels)
                )
            }
        }
    }

    /// What the model produced, as a JSON object keyed by question key (`GeneratedContent`'s
    /// `jsonString`), back to answers: numbers typed by their question, labels back to option
    /// values (case-insensitive), empty strings and unknown labels dropped. Nothing is validated
    /// here: `IntentDraft.answer` does that.
    public static func answers(fromJSON json: String, questions: [Question]) -> [String: AnswerValue] {
        guard let data = json.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var answers: [String: AnswerValue] = [:]
        for question in questions {
            guard let raw = object[question.key], !(raw is NSNull) else { continue }
            switch question.kind {
            case .int, .double:
                // JSON true/false bridge to NSNumber (1/0): never a number answer.
                if let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { continue }
                guard let number = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
                else { continue }
                answers[question.key] = IntentText.answer(number, for: question)
            case .string:
                guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { continue }
                answers[question.key] = .string(text)
            case .choice(let rules):
                func value(_ label: Any) -> String? {
                    guard let label = label as? String else { return nil }
                    return rules.activeOptions.first {
                        $0.label.compare(label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                            || $0.value == label
                    }?.value
                }
                if rules.multiple {
                    let picked = Set(((raw as? [Any]) ?? [raw]).compactMap(value))
                    let ordered = rules.options.map(\.value).filter(picked.contains)
                    if !ordered.isEmpty { answers[question.key] = .strings(ordered) }
                } else if let picked = value(raw) {
                    answers[question.key] = .string(picked)
                }
            }
        }
        return answers
    }

    /// How long the model may take: the rest of the 30 s is for the questions it didn't answer
    /// (the user's time answering doesn't count, spike S2) and the commit.
    public static let deadline: Duration = .seconds(8)

    /// `operation`'s result, or nil when it fails or takes longer than `deadline`; then it is
    /// cancelled and **not** waited for (a model call that ignores cancellation can't hold the
    /// intent). The caller's own cancellation is rethrown, not turned into nil.
    public static func withDeadline<T: Sendable>(
        _ deadline: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let pending = Mutex<CheckedContinuation<T?, Never>?>(nil)
        let finished = Mutex<(done: Bool, value: T?)>((false, nil))
        @Sendable func finish(_ value: T?) {
            let continuation = finished.withLock { state -> CheckedContinuation<T?, Never>? in
                guard !state.done else { return nil }
                state = (true, value)
                return pending.withLock { $0.take() }
            }
            continuation?.resume(returning: value)
        }
        let work = Task { finish(try? await operation()) }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            finish(nil)
        }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = finished.withLock { state -> (Bool, T?) in
                    if !state.done { pending.withLock { $0 = continuation } }
                    return (state.done, state.value)
                }
                if ready.0 { continuation.resume(returning: ready.1) }
            }
        } onCancel: {
            finish(nil)
        }
        work.cancel()
        timer.cancel()
        try Task.checkCancellation()
        return value
    }

    /// The model's instructions: extract, never invent.
    public static func instructions(topic: Topic) -> String {
        """
        You turn what someone said about their "\(topic.name)" log into the fields given. Use only \
        what they said; leave out any field they didn't mention. Numbers are plain numbers.
        """
    }
}

#if canImport(FoundationModels)
/// The on-device Foundation Model (iOS 26 on Apple Intelligence hardware). Unavailable (device,
/// setting, model not downloaded yet: spike S5) or failing (`rateLimited` in the background, any
/// error) means no answers.
public struct OnDeviceAnswerExtractor: AnswerExtractor {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func extract(_ utterance: String, topic: Topic) async throws -> [String: AnswerValue]? {
        guard isAvailable, let schema = try? Self.schema(for: topic) else { return nil }
        let instructions = AnswerExtraction.instructions(topic: topic)
        let json = try await AnswerExtraction.withDeadline(AnswerExtraction.deadline) {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: utterance, schema: schema).content.jsonString
        }
        return json.map { AnswerExtraction.answers(fromJSON: $0, questions: topic.questions) }
    }

    static func schema(for topic: Topic) throws -> GenerationSchema {
        let properties = AnswerExtraction.fields(for: topic.questions).map { key, field in
            let schema: DynamicGenerationSchema
            let description: String
            switch field {
            case .number(let text):
                (schema, description) = (DynamicGenerationSchema(type: Double.self), text)
            case .text(let text):
                (schema, description) = (DynamicGenerationSchema(type: String.self), text)
            case .choice(let text, let labels):
                (schema, description) = (DynamicGenerationSchema(name: "\(key)_choice", anyOf: labels), text)
            case .choices(let text, let labels):
                let item = DynamicGenerationSchema(name: "\(key)_choice", anyOf: labels)
                (schema, description) = (DynamicGenerationSchema(arrayOf: item), text)
            }
            return DynamicGenerationSchema.Property(
                name: key, description: description, schema: schema, isOptional: true)
        }
        return try GenerationSchema(
            root: DynamicGenerationSchema(name: "Entry", properties: properties), dependencies: [])
    }
}
#endif
