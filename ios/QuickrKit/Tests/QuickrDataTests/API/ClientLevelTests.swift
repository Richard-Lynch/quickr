import Foundation
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// V7 (client-versions.md §3–§4): the classifier's 426 row, `X-QuickR-Client` on every request,
/// the client holding requests back while outdated, and the levels it hands the store.
@Suite(.timeLimit(.minutes(5))) struct ClientLevelTests {
    static let above = APILevel.current + 1

    /// The server's 426 body: the repo's Problem envelope plus the two levels.
    static func outdatedBody(minimum: Int = above) -> String {
        #"{"code":"client_outdated","detail":"This version of quickR is too old for the server.","errors":[],"#
            + #""min_client_level":\#(minimum),"client_level":\#(APILevel.current)}"#
    }

    static func classify(_ response: HTTPResponse) -> APIResponse<Entry> {
        ClassificationTests.classify(response)
    }

    /// Records what the client hands it; `minimum` is its outdated state.
    final class Recorder: ClientLevelGate {
        let minimum: Mutex<Int?>
        let recorded = Mutex<[(ServerLevels, Int?)]>([])

        init(minimum: Int? = nil) { self.minimum = Mutex(minimum) }

        func outdatedMinimum() async -> Int? { minimum.withLock { $0 } }

        func record(_ levels: ServerLevels, outdatedMinimum: Int?) async {
            recorded.withLock { $0.append((levels, outdatedMinimum)) }
        }

        var levels: [ServerLevels] { recorded.withLock { $0.map(\.0) } }
        var outdated: [Int?] { recorded.withLock { $0.map(\.1) } }
    }

    // MARK: Classification

    @Test func a426ClientOutdatedWithIdentityIsClientOutdated() {
        let result = Self.classify(APITest.response(426, json: Self.outdatedBody(minimum: 5)))
        #expect(result.outcome == .clientOutdated(minimum: 5))
        #expect(!result.outcome.setsMaybeDelivered)
        #expect(!result.outcome.isRetry)
        #expect(result.outcome.stopsPass)
        #expect(result.message == ClientOutdated.updateMessage)
    }

    @Test func a426WithoutIdentityHeadersIsRetryable() {
        let result = Self.classify(APITest.response(426, json: Self.outdatedBody(), identity: nil))
        #expect(result.outcome == .retryable(.unexpectedResponse(status: 426)))
    }

    @Test func a426FromAnotherServerIsAnIdentityMismatch() {
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.fixtureIdentity.epoch)
        let result = Self.classify(APITest.response(426, json: Self.outdatedBody(), identity: other))
        guard case .identityMismatch = result.outcome else {
            Issue.record("\(result.outcome)")
            return
        }
    }

    @Test func a426WithAnotherCodeIsTerminal() {
        let result = Self.classify(APITest.response(426, json: APITest.problem("upgrade_required")))
        guard case .terminal(426, _) = result.outcome else {
            Issue.record("\(result.outcome)")
            return
        }
    }

    @Test func a426WithoutTheMinimumStillRefusesThisBuild() {
        let result = Self.classify(APITest.response(426, json: APITest.problem("client_outdated")))
        #expect(result.outcome == .clientOutdated(minimum: Self.above))
    }

    // MARK: The header

    /// V7: the goldens carry a placeholder, so this checks the real header.
    @Test func everyRequestCarriesThisBuildsLevel() async throws {
        let transport = FakeTransport()
        transport.enqueue(.failure(.unreachable("capture")))
        _ = try await APITest.client(transport).listTopics()
        let request = try #require(transport.requests.first)
        let header = try #require(request.headers[QuickrHeader.client])
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(parts.first == "ios")
        #expect(parts.contains("level=\(APILevel.current)"))
        let build = parts.first { $0.hasPrefix("build=") }
        #expect(build != nil)
        #expect(header == ClientHeader.current)
    }

    @Test func theGeneratedLevelMatchesTheSharedFile() throws {
        let url = Fixtures.root.deletingLastPathComponent().appendingPathComponent("api-level.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let level = json["api_level"] as? Int
        #expect(level == APILevel.current)
    }

    // MARK: Held back while outdated

    @Test func nothingIsSentWhileOutdated() async throws {
        let transport = FakeTransport()
        var client = APITest.client(transport)
        client.levels = Recorder(minimum: Self.above)
        let response = try await client.listTopics()
        let refused: Bool = if case .clientOutdated(Self.above) = response.outcome { true } else { false }
        #expect(refused)
        let entry = try await client.deleteEntry(id: UUID())
        #expect(entry.outcome == .clientOutdated(minimum: Self.above))
        #expect(transport.requests.isEmpty)
    }

    @Test func healthAndClientVersionsAreStillSent() async throws {
        let transport = FakeTransport()
        transport.enqueue(.failure(.unreachable("capture")))
        transport.enqueue(.failure(.unreachable("capture")))
        var client = APITest.client(transport)
        client.levels = Recorder(minimum: Self.above)
        _ = try await client.getClientVersions()
        _ = try await client.health()
        let paths = transport.requests.map(\.url.path)
        #expect(paths == ["/api/v1/client-versions", "/api/v1/health"])
    }

    // MARK: Levels recorded

    @Test func everyResponseFromTheExpectedServerHandsOverItsLevels() async throws {
        let transport = FakeTransport()
        let headers = [QuickrHeader.apiLevel: "3", QuickrHeader.minClientLevel: "ios=2, web=1"]
        transport.enqueue(.success(APITest.response(404, json: APITest.problem("not_found"), headers: headers)))
        let recorder = Recorder()
        var client = APITest.client(transport)
        client.levels = recorder
        _ = try await client.getTopic(ref: "x")
        let levels: [ServerLevels] = recorder.levels
        let expected: [ServerLevels] = [ServerLevels(apiLevel: 3, minClientLevelIOS: 2)]
        #expect(levels == expected)
        let outdated: [Int?] = recorder.outdated
        let none: [Int?] = [nil]
        #expect(outdated == none)
    }

    @Test func anotherServersLevelsAreIgnored() async throws {
        let transport = FakeTransport()
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.otherEpoch)
        let headers = [QuickrHeader.apiLevel: "3", QuickrHeader.minClientLevel: "ios=9"]
        transport.enqueue(.success(APITest.response(200, json: "{}", identity: other, headers: headers)))
        transport.enqueue(.success(APITest.response(200, json: "{}", identity: nil, headers: headers)))
        let recorder = Recorder()
        var client = APITest.client(transport)
        client.levels = recorder
        _ = try await client.getTopic(ref: "x")
        _ = try await client.getTopic(ref: "x")
        #expect(recorder.levels.isEmpty)
    }

    @Test func a426HandsOverItsMinimum() async throws {
        let transport = FakeTransport()
        transport.enqueue(
            .success(
                APITest.response(
                    426, json: Self.outdatedBody(minimum: 4),
                    headers: [QuickrHeader.apiLevel: "4", QuickrHeader.minClientLevel: "ios=4, web=4"])))
        let recorder = Recorder()
        var client = APITest.client(transport)
        client.levels = recorder
        _ = try await client.createEntry(
            ref: "t", EntryCreateDTO(id: nil, answers: [:], source: nil, capturedAt: Date(), version: 1))
        let outdated: [Int?] = recorder.outdated
        let four: [Int?] = [4]
        #expect(outdated == four)
    }

    static let minimumHeaders: [(String, Int?)] = [
        ("ios=2, web=1", 2), ("web=1,ios=3", 3), ("ios = 4", 4), ("ios=x, web=1", nil), ("", nil), ("ios=-1", nil),
    ]

    @Test(arguments: minimumHeaders)
    func theMinimumHeaderParses(_ value: String, _ ios: Int?) {
        let levels = ServerLevels(headers: [QuickrHeader.minClientLevel: value])
        let parsed: Int? = levels.minClientLevelIOS
        #expect(parsed == ios)
    }

    // MARK: Live Activity tokens

    /// V7: a Live Activity token registration refused as outdated isn't settled: it stays owed.
    @Test func aLiveActivityRegistrationRefusedAsOutdatedStaysOwed() async throws {
        let transport = FakeTransport()
        transport.stub(where: { _ in true }, { _ in APITest.response(426, json: Self.outdatedBody()) })
        let client = APITest.client(transport)
        let dependencies = LiveActivityTokens.Dependencies.api(
            { client }, deviceToken: { "device" }, environment: { .sandbox }, serverId: { "s" }, loadOwed: { [] },
            saveOwed: { _ in })
        let body = LiveActivityInDTO(token: "t", kind: .start, deviceToken: "device", environment: .sandbox)
        await #expect(throws: LiveActivityTokens.Dependencies.Failed.self) { try await dependencies.register(body) }
        await #expect(throws: LiveActivityTokens.Dependencies.Failed.self) { try await dependencies.unregister("t") }
    }
}
