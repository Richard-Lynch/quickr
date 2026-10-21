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
    /// server's at `date + skew`, with its times mapped back to device time, so the views'
    /// relative text ("Due in 25 min") against `date` is the server's.
    public func due(at date: Date) -> DueStatus? {
        TopicListing.due(of: topic, at: date.addingTimeInterval(skew)).map { status in
            var status = status
            status.dueSince = status.dueSince?.addingTimeInterval(-skew)
            status.nextDueAt = status.nextDueAt?.addingTimeInterval(-skew)
            status.lastEntryAt = status.lastEntryAt?.addingTimeInterval(-skew)
            return status
        }
    }

    /// `quickr://t/<slug>/record`: where a tap on the widget goes.
    public var recordURL: URL { URL(string: "quickr://t/\(topic.slug)/record")! }
}

extension WidgetTopic {
    /// `topics` in the home list's due-first order at device time `date` (a timeline entry's own
    /// order), in server time: they come from one store, so they share its skew.
    public static func dueFirst(_ topics: [WidgetTopic], at date: Date) -> [WidgetTopic] {
        let now = date.addingTimeInterval(topics.first?.skew ?? 0)
        return TopicListing.list(topics, topic: \.topic, now: now, status: .active, sort: .due, query: "").map(\.value)
    }
}
