import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// The widget extension's write context: a widget log is one durable `entry.create` from
/// "ios.widget" in the active store, the widgets reload before and after the flush, and the bounded
/// flush sends it when it can and leaves it queued when it can't.
@Suite(.timeLimit(.minutes(2))) struct WidgetWritesTests {
    static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "meh", label: "Meh")])))

    final class Count: Sendable {
        private let value = Mutex(0)
        func add() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    struct Offline: Transport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
    }

    /// A store location whose active server is FakeServer's, bootstrapped, holding `topic`.
    struct World {
        let directory: TempDirectory
        let location: StoreLocation
        let store: LocalStore
        let topic: Topic

        init(server: FakeServer? = nil) async throws {
            directory = try TempDirectory()
            location = StoreLocation(root: directory.url)
            var topic = Make.topic(name: "Mood")
            topic.questions = [WidgetWritesTests.mood]
            self.topic = topic
            let partitions = try StorePartitions.open(at: location, notifier: nil)
            store = try await partitions.createStore(serverId: "server-1", baseURL: FakeServer.base.absoluteString)
            try await partitions.registry.setActive("server-1")
            try await store.writer.write { [topic] db in
                try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
                _ = try ServerLayer.upsert(db, topic: topic)
            }
            server?.put(topic)
        }

        func items() async throws -> [OutboxItem] { try await store.outbox.items() }
    }

    @Test func offlineTheLogStaysQueuedFromTheWidget() async throws {
        let w = try await World()
        defer { w.directory.cleanup() }
        let reloads = Count()
        let context = WidgetWrites.context(
            location: w.location, transport: Offline(), credentials: StaticAccessCredentials(nil),
            reload: { reloads.add() })
        #expect(context.origin == .widget)

        let logged = try await IntentLogging.log(
            topicId: w.topic.id, answers: ["mood": .string("good")], in: context)
        #expect(logged.created)
        let item = try #require(try await w.items().first)
        #expect(item.entityId == logged.entryId.wireString && item.origin == .widget && item.state != .failed)
        guard case .entryCreate(_, let body) = try item.payload() else {
            Issue.record("not a create")
            return
        }
        #expect(body.source == "ios.widget")
        #expect(reloads.count == 2, "before the flush (queued shows) and after it")

        let shown = try #require(try await WidgetReader(store: w.store).topic(id: w.topic.id))
        #expect(shown.queued == 1 && shown.lastAnswer == .string("good"))
    }

    @Test func onlineTheFlushSendsIt() async throws {
        let server = FakeServer()
        let w = try await World(server: server)
        defer { w.directory.cleanup() }
        let reloads = Count()
        let context = WidgetWrites.context(
            location: w.location, transport: server, credentials: StaticAccessCredentials(nil),
            reload: { reloads.add() })

        let logged = try await IntentLogging.log(topicId: w.topic.id, answers: ["mood": .string("meh")], in: context)
        #expect(try await w.items().isEmpty, "acked")
        let sent = try #require(server.entry(logged.entryId))
        #expect(sent.source == "ios.widget")
        #expect(reloads.count == 2)
        #expect(try #require(try await WidgetReader(store: w.store).topic(id: w.topic.id)).queued == 0)
    }
}
