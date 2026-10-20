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

    public var id: UUID { topic.id }

    public init(topic: Topic, quick: QuickLog?, lastAnswer: AnswerValue?, queued: Int = 0, failed: Int = 0) {
        self.topic = topic
        self.quick = quick
        self.lastAnswer = lastAnswer
        self.queued = queued
        self.failed = failed
    }

    /// The due state at `date` (timeline entries are rendered ahead of time).
    public func due(at date: Date) -> DueStatus? { TopicListing.due(of: topic, at: date) }

    /// `quickr://t/<slug>/record`: where a tap on the widget goes.
    public var recordURL: URL { URL(string: "quickr://t/\(topic.slug)/record")! }
}

extension WidgetTopic {
    /// `topics` in the home list's due-first order at `date` (a timeline entry's own order).
    public static func dueFirst(_ topics: [WidgetTopic], at date: Date) -> [WidgetTopic] {
        TopicListing.list(topics, topic: \.topic, now: date, status: .active, sort: .due, query: "").map(\.value)
    }
}
