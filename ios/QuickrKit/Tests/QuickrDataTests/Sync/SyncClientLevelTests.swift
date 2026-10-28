import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
import QuickrTestSupport
import Testing

/// The coordinator and the API levels (client-versions.md §4.1, §4.5): V6's coordinator guard
/// (no pull while outdated), the flag set by a response's minimum and cleared when it drops, and
/// the host part of V13 (a server behind the client is noted, and nothing else changes).
@Suite(.timeLimit(.minutes(5))) struct SyncClientLevelTests {
    static let above = APILevel.current + 1

    static func refusal(_ env: SyncEnv) -> HTTPResponse {
        let body =
            #"{"code":"client_outdated","detail":"Update quickR.","errors":[],"min_client_level":\#(above),"#
            + #""client_level":\#(APILevel.current)}"#
        return HTTPResponse(
            status: 426,
            headers: [
                "Content-Type": "application/problem+json", QuickrHeader.serverId: env.server.serverId,
                QuickrHeader.epoch: env.server.epoch, QuickrHeader.apiLevel: String(above),
                QuickrHeader.minClientLevel: "ios=\(above), web=\(above)",
            ],
            body: Data(body.utf8))
    }

    @Test("V6 · a 426 stops the pull and sets the flag; no request is made while it is set; clearing it resumes")
    func aRefusedPullStopsAndThePausedCoordinatorMakesNoRequest() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let refusal = Self.refusal(env)
        env.server.intercept { _ in refusal }

        let result = await coordinator.sync(reason: .pullToRefresh)
        #expect(result == .clientOutdated)
        let state = try await store.state()
        #expect(state.clientOutdatedMin == Self.above)
        let status = coordinator.status
        #expect(status.clientOutdatedMin == Self.above)
        #expect(status.isClientOutdated)

        let requests = env.transport.requests.count
        let again = await coordinator.sync(reason: .pullToRefresh)
        #expect(again == .clientOutdated)
        #expect(env.transport.requests.count == requests, "checked before any request")

        // The updated build: its first open clears the flag, and pulls resume.
        env.server.intercept(nil)
        env.server.addEntry()
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET client_outdated_min = ?", arguments: [APILevel.current])
        }
        _ = try await env.partitions.openActiveStore(role: .app)
        let cleared = try await store.state().clientOutdatedMin
        #expect(cleared == nil)
        let resumed = await coordinator.sync(reason: .pullToRefresh)
        #expect(resumed == .synced)
        let after = coordinator.status
        #expect(!after.isClientOutdated)
    }

    @Test("§4.1 · a page whose ios minimum is above this build sets the flag; the next pull is refused")
    func aMinimumAboveThisBuildSetsTheFlag() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.extraHeaders = [QuickrHeader.minClientLevel: "ios=\(Self.above), web=0"]
        env.server.addEntry()
        _ = await coordinator.sync(reason: .pullToRefresh)
        let minimum = try await store.state().clientOutdatedMin
        #expect(minimum == Self.above)
        let next = await coordinator.sync(reason: .pullToRefresh)
        #expect(next == .clientOutdated)
    }

    @Test("§4.1 · Check again: getClientVersions is still sent, and a minimum this build meets clears the flag")
    func checkAgainClearsTheFlagWhenTheMinimumDrops() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET client_outdated_min = ?", arguments: [Self.above])
        }
        let (serverId, epoch) = (env.server.serverId, env.server.epoch)
        env.transport.stub(
            where: { $0.url.path == "/api/v1/client-versions" },
            { _ in
                HTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json", QuickrHeader.serverId: serverId, QuickrHeader.epoch: epoch,
                        QuickrHeader.apiLevel: String(APILevel.current),
                        QuickrHeader.minClientLevel: "ios=\(APILevel.current), web=0",
                    ],
                    body: Data(
                        #"{"api_level":\#(APILevel.current),"min_client_level":{"ios":\#(APILevel.current),"web":0},"update_url":{"ios":"itms-beta://"}}"#
                            .utf8))
            })
        let client = APIClient(
            baseURL: SyncEnv.baseURL, transport: env.transport, identity: StaticServerIdentity(nil),
            levels: StoreClientLevels(store: store))
        let blocked = try await client.listTopics().outcome
        let refused: Bool = if case .clientOutdated(Self.above) = blocked { true } else { false }
        #expect(refused)
        let versions = try #require(try await client.getClientVersions().value)
        let minimum: Int = versions.minClientLevelIOS
        #expect(minimum == APILevel.current)
        let state = try await store.state()
        #expect(state.clientOutdatedMin == nil)
        #expect(state.serverApiLevel == APILevel.current)
        let resumed = await coordinator.sync(reason: .pullToRefresh)
        #expect(resumed == .synced)
    }

    @Test(
        "V13 · a server behind: server_api_level is recorded, pulls go on, and a later response at the level clears the note"
    )
    func aServerBehindIsOnlyNoted() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let behind = APILevel.current - 1
        env.server.extraHeaders = [QuickrHeader.apiLevel: String(behind), QuickrHeader.minClientLevel: "ios=0, web=0"]
        env.server.addEntry()
        let pulled = await coordinator.sync(reason: .pullToRefresh)
        #expect(pulled == .synced)
        let noted = try await store.state()
        #expect(noted.serverApiLevel == behind)
        #expect(noted.serverIsBehind)
        #expect(!noted.isClientOutdated)
        let status = coordinator.status
        #expect(status.serverIsBehind)

        env.server.extraHeaders = [QuickrHeader.apiLevel: String(APILevel.current)]
        env.server.addEntry()
        let again = await coordinator.sync(reason: .pullToRefresh)
        #expect(again == .synced)
        let cleared = try await store.state()
        #expect(cleared.serverApiLevel == APILevel.current)
        #expect(!cleared.serverIsBehind)
        let after = coordinator.status
        #expect(!after.serverIsBehind)
    }

    @Test("V13 · a server behind: the outbox still flushes")
    func aServerBehindStillFlushes() async throws {
        let h = try OutboxHarness()
        h.server.with { $0.apiLevel = APILevel.current - 1 }
        let id = try await h.log(h.outbox())
        let report = try await h.outbox(levels: true).flushNow()
        #expect(report.acked == 1)
        #expect(h.server.entry(id) != nil)
        let state = try #require(try await h.syncState())
        #expect(state.serverApiLevel == APILevel.current - 1)
        #expect(state.serverIsBehind)
    }
}
