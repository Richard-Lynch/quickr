import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@_spi(Testing) @testable import QuickrData

/// A version's timer (timers.md §2.1) through the feed into the store (`timer_json`, store v2),
/// and back out in a publish from this device: the edit keeps the timer the server has.
@Suite(.timeLimit(.minutes(5))) struct SyncTimerTests {
    /// Records each request and answers none (offline): what a publish would send.
    final class Recorder: Transport, Sendable {
        private let log = Mutex<[HTTPRequest]>([])
        var requests: [HTTPRequest] { log.withLock { $0 } }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            log.withLock { $0.append(request) }
            throw TransportError.unreachable("recorded")
        }
    }

    static let everything = UUID(uuidString: FakeFeedServer.everything)!
    /// The timer `listChanges.bootstrap` carries on Everything's version 2.
    static let fixtureTimer = TopicTimer(steps: [
        .init(key: "pour", label: "Pour"), .init(key: "drink", label: "Drink"),
    ])

    @Test func aTimedVersionRoundTripsAndAPublishCarriesItsTimer() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let store = try await env.connect(env.coordinator())

        // The feed's versions, as the store reads them back: v2 timed, v1 not.
        let versions = try await store.versions.versions(topicId: Self.everything)
        #expect(versions.map(\.version) == [1, 2])
        #expect(versions.map(\.timer) == [nil, Self.fixtureTimer])
        let stored = try await store.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT timer_json FROM topic_version WHERE topic_id = ? AND timer_json IS NOT NULL",
                arguments: [FakeFeedServer.everything])
        }
        #expect(stored.count == 1)

        // A publish edited from v2 sends v2's timer, unchanged.
        let binding = AppSession.Binding(
            serverId: store.serverId, storeGen: store.storeGen, baseURL: SyncEnv.baseURL)
        let scope = try #require(await TopicWrites.scope(binding: binding, store: store))
        let recorder = Recorder()
        let writes = TopicWrites(
            scope: scope, store: store, transport: recorder, credentials: StaticAccessCredentials(nil),
            requestSync: { _ in })
        // The editor opens on v2 with its timer; an unedited timer is sent as it is.
        let v2 = try #require(versions.last)
        let draft = TopicDraft.editing(name: "x", slug: "x", description: "", questions: v2.questions, timer: v2.timer)
        let outcome = await writes.publishVersion(
            topicId: Self.everything, try draft.validatedForVersion().get(), baseVersion: 2, changeNote: "")
        #expect(outcome.isOffline, "\(outcome)")
        let body = try #require(recorder.requests.last?.body)
        let sent = try WireCoding.decoder().decode(SentTimer.self, from: body)
        #expect(sent.timer == Self.fixtureTimer)
    }

    struct SentTimer: Decodable {
        var timer: TopicTimer?
    }
}

extension TopicWrites.Outcome {
    fileprivate var isOffline: Bool {
        if case .offline = self { true } else { false }
    }
}
