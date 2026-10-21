import Foundation

/// What a widget shows of one topic, read once from the store (widgets render snapshots; they
/// don't observe). Plain values, so the timeline provider, the app's reload check and the views
/// share it, and tests build it directly.
public struct WidgetTopic: Sendable, Hashable, Identifiable {
    public var topic: Topic
    /// How it logs in one tap (chips or "✓ last"), or nil when it needs the record screen.
    public var quick: QuickLog?
    /// The latest entry's answer to the quick question (pending ones included: they're the user's).
    public var lastAnswer: AnswerValue?
    /// Entries this device has logged that haven't reached the server yet ("queued").
    public var queued: Int
    /// Entries the server refused (the sync sheet fixes them).
    public var failed: Int
    /// The store this was read from: a widget's buttons log only while it is still the active one.
    /// Nil for a sample (the app's widget gallery): its buttons open the record screen.
    public var scope: EntryScope?
    /// Server time minus device time, in seconds: the store's measured skew (sync-protocol.md
    /// §10, `skew_ms`). Due state is the server's, at device time plus this.
    public var skew: TimeInterval

    public var id: UUID { topic.id }

    public init(
        topic: Topic, quick: QuickLog?, lastAnswer: AnswerValue?, queued: Int = 0, failed: Int = 0,
        scope: EntryScope? = nil, skew: TimeInterval = 0
    ) {
        self.topic = topic
        self.quick = quick
        self.lastAnswer = lastAnswer
        self.queued = queued
        self.failed = failed
        self.scope = scope
        self.skew = skew
    }

    /// What ✓ shows and logs for a number topic, the same value for both: the last one while the
    /// question still accepts it, else its start (the minimum), like the tile's stepper; nil when
    /// there's neither.
    public var checkAnswer: AnswerValue? {
        guard case .number(let question) = quick,
            let number = Double(QuickLog.initialText(for: question, last: lastAnswer))
        else { return nil }
        if case .int = question.kind, number == number.rounded(), abs(number) < Double(Int.max) {
            return .int(Int(number))
        }
        return .double(number)
    }

    /// The due state at device time `date` (timeline entries are rendered ahead of time): the
    /// server's, at `serverTime(date)`. Its times are the server's ("Next 08:00" is 08:00), so
    /// show it against `serverTime(date)` too (`DueView(due:now:)`).
    public func due(at date: Date) -> DueStatus? { TopicListing.due(of: topic, at: serverTime(date)) }

    /// Device time `date` on the server's clock (`date + skew`), the "now" of due state.
    public func serverTime(_ date: Date) -> Date { date.addingTimeInterval(skew) }

    /// Where a tap on the widget goes: the topic's record screen by id, naming the store it was
    /// read from (`quickr://t/{topic_id}/record?scope=…`), so a widget left over from another
    /// server or store is refused, not opened on a same-slug topic (notifications.md §7.5). A
    /// sample (no store) links by slug.
    public var recordURL: URL {
        guard let scope else {
            return DeepLink.url(for: .record(TopicLinkRef(topic.slug) ?? TopicLinkRef(id: topic.id)))
        }
        return DeepLink.url(for: .record(TopicLinkRef(id: topic.id)), scope: scope)
    }
}

extension WidgetTopic {
    /// `topics` in the home list's due-first order at device time `date` (a timeline entry's own
    /// order), in server time: they come from one store, so they share its skew.
    public static func dueFirst(_ topics: [WidgetTopic], at date: Date) -> [WidgetTopic] {
        let now = date.addingTimeInterval(topics.first?.skew ?? 0)
        return TopicListing.list(topics, topic: \.topic, now: now, status: .active, sort: .due, query: "").map(\.value)
    }
}
