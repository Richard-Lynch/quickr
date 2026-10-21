import Foundation
import GRDB
import QuickrCore

/// The widgets' reads from a store: one topic, or the due-first list. Read-only, so it works on a
/// `ReadOnlyStores` store in the widget extension.
public struct WidgetReader: Sendable {
    let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    /// One topic (nil once it's gone: deleted, or another server's).
    public func topic(id: UUID) async throws -> WidgetTopic? {
        guard let view = try await store.topics.topic(id: id) else { return nil }
        return try await widgetTopic(view.topic, skew: skew())
    }

    /// Active topics, due first (the home list's order at device time `now`, in server time), for
    /// the due-list widget.
    public func dueList(now: Date) async throws -> [WidgetTopic] {
        let skew = try await skew()
        let topics = try await store.topics.topics().map(\.topic)
        let listed = TopicListing.list(
            topics, topic: { $0 }, now: ServerClock(skew: skew).now(at: now), status: .active, sort: .due, query: "")
        var result: [WidgetTopic] = []
        for item in listed { result.append(try await widgetTopic(item.topic, skew: skew)) }
        return result
    }

    /// The store's measured skew in seconds (0 before the first pull, sync-protocol.md §10).
    private func skew() async throws -> TimeInterval {
        (try await store.syncState.syncState()?.serverClock ?? .device).skew
    }

    private func widgetTopic(_ topic: Topic, skew: TimeInterval) async throws -> WidgetTopic {
        let quick = QuickLog(questions: topic.questions)
        var lastAnswer: AnswerValue?
        if let quick, let latest = try await store.entries.latestEntry(topicId: topic.id) {
            lastAnswer = latest.entry.answers[quick.question.key]
        }
        // Counted in SQL: a long offline backlog is many rows with payloads, and a widget's
        // timeline has little memory and time.
        let topicId = topic.id.wireString
        let (queued, failed) = try await store.writer.read { db -> (Int, Int) in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(state != 'failed'), 0) AS queued, COALESCE(SUM(state = 'failed'), 0) AS failed
                    FROM outbox_item WHERE topic_id = ? AND kind = ?
                    """,
                arguments: [topicId, OutboxKind.entryCreate.rawValue])
            return (row?["queued"] ?? 0, row?["failed"] ?? 0)
        }
        return WidgetTopic(
            topic: topic, quick: quick, lastAnswer: lastAnswer, queued: queued, failed: failed, scope: store.scope,
            skew: skew)
    }
}
