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
@MainActor @Observable
public final class QuickLogDrafts {
    private var values: [UUID: String] = [:]

    public init() {}

    public subscript(topic: UUID) -> String? {
        get { values[topic] }
        set { values[topic] = newValue }
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

    public init(
        topic: QuickLogTopic, last: AnswerValue? = nil, writer: any EntryWriter, toasts: EntryToasts,
        drafts: QuickLogDrafts, flash: ConfirmFlash = ConfirmFlash()
    ) {
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
        get { drafts[topic.id] ?? QuickLog.initialText(for: topic.quick.question, last: last) }
        set {
            drafts[topic.id] = newValue
            numberError = nil
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
            if await log(answers, label: unit.map { "\(text) \($0)" } ?? text) { drafts[topic.id] = nil }
        }
    }

    /// True when the entry was sent or queued; every outcome gets its toast.
    private func log(_ answers: [String: AnswerValue], label: String) async -> Bool {
        let entryId: UUID
        do {
            entryId = try await writer.log(topic, answers: answers)
        } catch {
            toasts.logFailed(topicName: topic.name, writer.failure(error))
            return false
        }
        switch await writer.sendNow(entryId, wait: Self.sendWait) {
        case .sent:
            toasts.logged(entryId: entryId, label: label, topicName: topic.name, sent: true)
            return true
        case .queued:
            toasts.logged(entryId: entryId, label: label, topicName: topic.name, sent: false)
            return true
        case .failed(let message):
            toasts.logFailed(topicName: topic.name, .message(message))
            return false
        case .notSaved:
            toasts.logFailed(topicName: topic.name, .notSaved)
            return false
        }
    }
}
