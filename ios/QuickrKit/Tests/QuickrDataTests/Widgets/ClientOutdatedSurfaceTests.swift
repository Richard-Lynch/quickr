import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// V8 (client-versions.md §4.1): a widget, Control, App Intent, Action button or Live Activity
/// button write while this build is outdated. The item is durable, no request is made, and the
/// result says "Saved on this iPhone. Update quickR to sync." (Notification actions:
/// `NotificationActionHandlerTests`.)
@Suite(.timeLimit(.minutes(2))) struct ClientOutdatedSurfaceTests {
    static let mood = WidgetWritesTests.mood

    static func outdate(_ store: LocalStore) async throws {
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET client_outdated_min = ?", arguments: [APILevel.current + 1])
        }
    }

    @Test func aWidgetChipIsKeptNotSentAndSaysToUpdate() async throws {
        let server = FakeServer()
        let w = try await WidgetWritesTests.World(server: server)
        defer { w.directory.cleanup() }
        try await Self.outdate(w.store)
        let reloads = WidgetWritesTests.Count()
        let context = WidgetWrites.context(
            location: w.location, transport: server, credentials: StaticAccessCredentials(nil),
            reload: { reloads.add() })
        let said = try await WidgetLogging.perform(
            topicId: w.topic.id,
            option: QuestionOptionEntity(
                topicId: w.topic.id, key: "mood", option: EnumOption(value: "good", label: "Good")),
            number: nil, scope: w.store.scope, context: context, reload: {})
        #expect(said == "Logged Mood: Good. \(ClientOutdated.savedMessage)")
        let items = try await w.items()
        #expect(items.map(\.state) == [.pending])
        #expect(server.requests.isEmpty, "no request")
        #expect(reloads.count == 2, "the widgets still show it queued")
    }

    @Test func anIntentLogIsKeptNotSentAndSaysToUpdate() async throws {
        let server = FakeServer()
        let w = try await WidgetWritesTests.World(server: server)
        defer { w.directory.cleanup() }
        try await Self.outdate(w.store)
        let store = w.store
        // The app's context: the commit asks for a flush.
        let context = IntentWriteContext(
            origin: .siri, openActiveStore: { store },
            afterCommit: { store in
                let client = APIClient(
                    baseURL: FakeServer.base, transport: server, identity: StaticServerIdentity(nil),
                    levels: StoreClientLevels(store: store))
                _ = try? await Outbox(store: store, sender: client, owner: "app:1").flush(
                    force: true, budget: .seconds(5))
            })
        let logged = try await IntentLogging.log(topicId: w.topic.id, answers: ["mood": .string("good")], in: context)
        #expect(logged.clientOutdated)
        #expect(logged.saying("Logged Mood: Good.") == "Logged Mood: Good. \(ClientOutdated.savedMessage)")
        let items = try await w.items()
        #expect(items.map(\.state) == [.pending])
        #expect(server.requests.isEmpty)
    }

    @Test func notOutdatedTheTextIsUnchanged() async throws {
        let w = try await WidgetWritesTests.World()
        defer { w.directory.cleanup() }
        let store = w.store
        let logged = try await IntentLogging.log(
            topicId: w.topic.id, answers: ["mood": .string("good")],
            in: IntentWriteContext(origin: .siri, openActiveStore: { store }))
        #expect(!logged.clientOutdated)
        #expect(logged.saying("Logged Mood: Good.") == "Logged Mood: Good.")
    }

    @Test(arguments: [OutboxOrigin.widget, .siri])
    func aRunIntentIsKeptNotSentAndSaysToUpdate(_ origin: OutboxOrigin) async throws {
        let h = try OutboxHarness()
        try h.timed()
        try await Self.outdate(h.store)
        let result = try await h.runs(origin).perform(
            RunIntentRequest(action: .auto, topicId: h.topic.id, origin: origin))
        #expect(result.wrote)
        #expect(result.clientOutdated)
        #expect(result.shownText == "Started Mood. First: Shower. \(ClientOutdated.savedMessage)")
        #expect(result.spokenText.hasSuffix(ClientOutdated.savedMessage))
        let report = try await h.outbox(levels: true).flushNow()
        #expect(report.ending == .clientOutdated)
        #expect(h.server.requests.isEmpty)
        let items = try h.runItems
        #expect(items.map(\.state) == [.pending])
    }

    @Test func aLiveActivityButtonTapIsKeptAndNotSent() async throws {
        let h = try OutboxHarness()
        try h.timed()
        let runId = try await h.start()
        try await Self.outdate(h.store)
        h.wall.advance(by: 30)
        let tap = RunActivityTap(button: .next, serverId: "server-1", topicId: h.topic.id, runId: runId, seg: 0)
        let written = try await h.runs().tap(tap.tapType, runId: tap.runId, target: tap.target)
        #expect(written != nil)
        let report = try await h.outbox(levels: true).flushNow()
        #expect(report.ending == .clientOutdated)
        #expect(h.server.requests.isEmpty)
        let items = try h.runItems
        #expect(items.map(\.state) == [.pending, .pending])
        let ats: [Int] = try items.map { try h.at($0) }
        let tapped: [Int] = [ms(0), ms(30)]
        #expect(ats == tapped)
    }
}
