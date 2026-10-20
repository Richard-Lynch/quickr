import Foundation
import QuickrCore

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

/// The widgets' reads from a store: one topic, or the due-first list. Read-only, so it works on a
/// `ReadOnlyStores` store in the widget extension.
public struct WidgetReader: Sendable {
    let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    /// One topic (nil once it's gone: deleted, or another server's).
    public func topic(id: UUID) async throws -> WidgetTopic? {
        guard let view = try await store.topics.topic(id: id) else { return nil }
        return try await widgetTopic(view.topic)
    }

    /// Active topics, due first (the home list's order), for the due-list widget.
    public func dueList(now: Date) async throws -> [WidgetTopic] {
        let topics = try await store.topics.topics().map(\.topic)
        let listed = TopicListing.list(topics, topic: { $0 }, now: now, status: .active, sort: .due, query: "")
        var result: [WidgetTopic] = []
        for item in listed { result.append(try await widgetTopic(item.topic)) }
        return result
    }

    private func widgetTopic(_ topic: Topic) async throws -> WidgetTopic {
        let quick = QuickLog(questions: topic.questions)
        var lastAnswer: AnswerValue?
        if let quick, let latest = try await store.entries.latestEntry(topicId: topic.id) {
            lastAnswer = latest.entry.answers[quick.question.key]
        }
        let creates = try await store.outbox.items(topicId: topic.id.wireString).filter { $0.kind == .entryCreate }
        return WidgetTopic(
            topic: topic, quick: quick, lastAnswer: lastAnswer,
            queued: creates.filter { $0.state != .failed }.count,
            failed: creates.filter { $0.state == .failed }.count)
    }
}
