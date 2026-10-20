import Foundation
import Observation
import QuickrCore

/// The topic a tile quick-logs for.
public struct QuickLogTopic: Sendable, Hashable {
    public var id: UUID
    public var slug: String
    public var name: String
    /// The topic's current version, which every quick-logged entry is answered against.
    public var version: Int
    public var quick: QuickLog

    /// The topic as entries are logged against it.
    public var entryTopic: EntryTopic { EntryTopic(id: id, slug: slug, name: name, version: version) }

    public init(id: UUID, slug: String, name: String, version: Int, quick: QuickLog) {
        self.id = id
        self.slug = slug
        self.name = name
        self.version = version
        self.quick = quick
    }
}

/// Numbers typed into tiles but not logged yet (the PWA's `numberDrafts`). One per app run,
/// shared by every tile: a draft survives leaving the home screen and coming back, not a relaunch.
/// Kept per store (`EntryScope`), so a topic id that exists on two servers never shares one.
@MainActor @Observable
public final class QuickLogDrafts {
    private struct Key: Hashable {
        var scope: EntryScope?
        var topic: UUID
    }

    private var values: [Key: String] = [:]

    public init() {}

    public subscript(scope: EntryScope?, topic: UUID) -> String? {
        get { values[Key(scope: scope, topic: topic)] }
        // Every write redraws whatever reads it, so an unchanged value isn't written.
        set {
            let key = Key(scope: scope, topic: topic)
            if values[key] != newValue { values[key] = newValue }
        }
    }
}

/// One tile's quick-log (the PWA's `QuickChips` and `QuickNumber`): logs through `writer`, then
/// waits up to ``sendWait`` for the server like the PWA's `recordEntry(waitMs: 2500)`.
///
/// - Chips: one tap logs. Every chip is disabled until the outcome is known; then the tapped chip
///   lights for 1.6 s (``flash``) and the Undo toast follows.
/// - Number: the field starts from the draft, else the last value (``QuickLog/initialText``). ✓
///   logs it; a logged value clears the draft, a refused one keeps it.
@MainActor @Observable
public final class QuickLogModel {
    /// How long a quick-log waits for the server before saying "will sync" (outbox.md §10).
    public static let sendWait: Duration = .milliseconds(2500)

    public var topic: QuickLogTopic
    /// The last logged answer to the quick question: the chips' dot and the stepper's start.
    public var last: AnswerValue?
    /// The chip being logged; every chip is disabled while it is set.
    public private(set) var busyOption: String?
    public private(set) var isLoggingNumber = false
    public private(set) var numberError: String?
    /// The tapped chip's confirmation.
    public let flash: ConfirmFlash

    @ObservationIgnored private let writer: any EntryWriter
    @ObservationIgnored private let toasts: EntryToasts
    @ObservationIgnored private let drafts: QuickLogDrafts
    /// The store this model shows (its drafts are that store's).
    public let scope: EntryScope?

    public init(
        topic: QuickLogTopic, last: AnswerValue? = nil, writer: any EntryWriter, toasts: EntryToasts,
        drafts: QuickLogDrafts, flash: ConfirmFlash = ConfirmFlash()
    ) {
        self.scope = writer.scope
        self.topic = topic
        self.last = last
        self.writer = writer
        self.toasts = toasts
        self.drafts = drafts
        self.flash = flash
    }

    /// The value the dot marks: the last answer when it is one of the chips.
    public var lastOption: String? {
        if case .string(let value) = last { value } else { nil }
    }

    /// The number field's text: the draft, else the last value or the minimum.
    public var numberText: String {
        get { drafts[scope, topic.id] ?? QuickLog.initialText(for: topic.quick.question, last: last) }
        set {
            // A text field can hand back the text it was given (as it is rebuilt while a list
            // scrolls); writing it anyway redraws the field, which hands it back again.
            guard newValue != numberText else { return }
            drafts[scope, topic.id] = newValue
            if numberError != nil { numberError = nil }
        }
    }

    /// The number field's label (the PWA's): the question, plus its unit when that adds something.
    public var numberLabel: String {
        let question = topic.quick.question
        guard let unit = question.numericRules?.unit, !unit.isEmpty,
            unit.lowercased() != question.label.lowercased()
        else { return question.label }
        return "\(question.label) (\(unit))"
    }

    /// Logs a chip. Ignored while another chip of this tile is being logged.
    public func pick(_ option: EnumOption) async {
        guard busyOption == nil else { return }
        busyOption = option.value
        defer { busyOption = nil }
        let answers = QuickLog.answers(picking: option, for: topic.quick.question)
        if await log(answers, label: option.label) { flash.confirm(option.value) }
    }

    /// Logs the number field: shows the validation message instead when it doesn't parse.
    public func logNumber() async {
        guard !isLoggingNumber else { return }
        let text = numberText
        switch QuickLog.parseNumber(text, for: topic.quick.question) {
        case .failure(let message):
            numberError = message.message
        case .success(let answers):
            isLoggingNumber = true
            defer { isLoggingNumber = false }
            let unit = topic.quick.question.numericRules?.unit.flatMap { $0.isEmpty ? nil : $0 }
            if await log(answers, label: unit.map { "\(text) \($0)" } ?? text) { drafts[scope, topic.id] = nil }
        }
    }

    /// True when the entry was sent or queued; every outcome gets its toast.
    private func log(_ answers: [String: AnswerValue], label: String) async -> Bool {
        let entry: LoggedEntry
        do {
            entry = try await writer.log(topic, answers: answers)
        } catch {
            toasts.logFailed(topicName: topic.name, writer.failure(error))
            return false
        }
        switch await writer.sendNow(entry, wait: Self.sendWait) {
        case .sent:
            toasts.logged(entry, label: label, topicName: topic.name, sent: true)
            return true
        case .queued:
            toasts.logged(entry, label: label, topicName: topic.name, sent: false)
            return true
        case .failed(let message, _):
            toasts.logFailed(topicName: topic.name, .message(message))
            return false
        case .notSaved:
            toasts.logFailed(topicName: topic.name, .notSaved)
            return false
        }
    }
}

/// Every tile's `QuickLogModel`, kept for the app run. A lazy list drops a tile's views when it
/// scrolls away; with the model (and its last value) kept here, the tile comes back at its final
/// height at once. A tile that grew only after its model loaded made a fling at accessibility
/// sizes thrash: the height change moved the list, which dropped and rebuilt the tile again.
/// It also keeps a chip's busy and confirmation state across the scroll.
///
/// The cache belongs to one store: when the writer's `EntryScope` changes (a server switch or a
/// reset) every model goes, so a topic id that exists on both servers never shows the old store's
/// definition or last value, and late updates from the old store's observation are ignored.
@MainActor
public final class QuickLogModels {
    private var models: [UUID: QuickLogModel] = [:]
    private var scope: EntryScope?
    private let writer: any EntryWriter
    private let toasts: EntryToasts
    private let drafts: QuickLogDrafts

    public init(writer: any EntryWriter, toasts: EntryToasts, drafts: QuickLogDrafts) {
        self.writer = writer
        self.toasts = toasts
        self.drafts = drafts
    }

    /// The topic's model, made on first use. Reading it from a view's body is fine: making one
    /// changes nothing a view observes. Bring an existing model up to date with ``update(_:last:from:)``.
    public func model(for topic: QuickLogTopic) -> QuickLogModel {
        followScope()
        if let model = models[topic.id] { return model }
        let model = QuickLogModel(topic: topic, writer: writer, toasts: toasts, drafts: drafts)
        models[topic.id] = model
        return model
    }

    /// Updates a model's topic and last value, touching only what changed (each write redraws).
    /// `scope`: the store the values were read from; ignored unless it is still the active one.
    public func update(_ topic: QuickLogTopic, last: AnswerValue?, from scope: EntryScope?) {
        followScope()
        guard scope == self.scope else { return }
        let model = model(for: topic)
        if model.topic != topic { model.topic = topic }
        if model.last != last { model.last = last }
    }

    /// Drops the models of topics no longer in the store (`ids`: every topic it holds).
    public func retain(_ ids: Set<UUID>) {
        followScope()
        models = models.filter { ids.contains($0.key) }
    }

    /// Starts over when the writer moved to another store.
    private func followScope() {
        let current = writer.scope
        guard current != scope else { return }
        models.removeAll()
        scope = current
    }
}
