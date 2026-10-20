import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

private let token = AccessCredentials(clientId: "abc123.access", clientSecret: "s3cr3t-value")

private let tokenB = AccessCredentials(clientId: "b.access", clientSecret: "b-s3cr3t")
private let urlA = URL(string: "https://a.example.com")!
private let urlB = URL(string: "https://b.example.com/quickr/")!

/// A registry that knows servers a and b at their addresses.
private struct FakeRegistry: RegistryRepository {
    var known: [String: URL]

    func servers() async throws -> [RegisteredServer] {
        known.map { RegisteredServer(id: $0.key, baseURL: $0.value.absoluteString, createdAt: Date()) }
    }

    func server(id: String) async throws -> RegisteredServer? { try await servers().first { $0.id == id } }
    func activeServerId() async throws -> String? { nil }
    func notificationCategories() async throws -> [NotificationCategoryRecord] { [] }
}

@Suite struct KeychainAccessCredentialsTests {
    @Test func addressesNormalise() {
        #expect(
            KeychainAccessCredentials.addressKey(URL(string: "HTTPS://A.Example.com:443/")!) == "https://a.example.com")
        #expect(KeychainAccessCredentials.addressKey(urlB) == "https://b.example.com/quickr")
        #expect(KeychainAccessCredentials.addressKey(URL(string: "http://nas.local:8100")!) == "http://nas.local:8100")
        #expect(KeychainAccessCredentials.addressKey(URL(string: "http://nas.local:80/")!) == "http://nas.local")
    }

    @Test func tokensArePerServerAndRemovingOneKeepsTheOther() async throws {
        let keychain = InMemoryKeychain()
        let provider = KeychainAccessCredentials(keychain: keychain)
        #expect(try await provider.accessCredentials(for: urlA) == nil)

        // Before the registry knows them: filed by address.
        try await provider.save(token, for: urlA)
        try await provider.save(tokenB, for: urlB)
        #expect(try await provider.accessCredentials(for: urlA) == token)
        #expect(try await provider.accessCredentials(for: URL(string: "https://a.example.com/")!) == token)
        #expect(try await provider.accessCredentials(for: URL(string: "https://b.example.com/quickr")!) == tokenB)
        #expect(try await provider.accessCredentials(for: URL(string: "https://c.example.com")!) == nil)

        try await provider.save(nil, for: urlA)
        #expect(try await provider.accessCredentials(for: urlA) == nil)
        #expect(try await provider.accessCredentials(for: urlB) == tokenB)
        try await provider.save(nil, for: urlA)  // removing nothing is fine
    }

    @Test func connectingFilesTheTokenUnderTheServerId() async throws {
        let keychain = InMemoryKeychain()
        let directory = ServerDirectory()
        let provider = KeychainAccessCredentials(keychain: keychain, directory: directory)
        try await provider.save(tokenB, for: urlB)
        try provider.adopt(baseURL: urlB, serverId: "server-b")
        #expect(keychain.accounts == ["cloudflare-access:server:server-b"])
        #expect(try provider.stored(serverId: "server-b") == tokenB)

        // Once the registry records b's address, requests to it resolve to b's token...
        directory.attach(FakeRegistry(known: ["server-b": urlB]))
        #expect(try await provider.accessCredentials(for: urlB) == tokenB)
        // ...and saving for that address replaces b's, not a new address item.
        try await provider.save(token, for: urlB)
        #expect(keychain.accounts == ["cloudflare-access:server:server-b"])
        #expect(try provider.stored(serverId: "server-b") == token)
        // Removing b's clears only b's.
        try provider.save(tokenB, serverId: "server-a")
        try await provider.save(nil, for: urlB)
        #expect(keychain.accounts == ["cloudflare-access:server:server-a"])
        // Nothing filed under the address to adopt: nothing changes.
        try provider.adopt(baseURL: urlA, serverId: "server-c")
        #expect(keychain.accounts == ["cloudflare-access:server:server-a"])
    }

    /// A flush to a running while b connects: each request carries its own target's token, however
    /// they interleave.
    @Test func concurrentRequestsToTwoServersEachCarryTheirOwnToken() async throws {
        let keychain = InMemoryKeychain()
        let directory = ServerDirectory()
        let provider = KeychainAccessCredentials(keychain: keychain, directory: directory)
        try provider.save(token, serverId: "server-a")
        directory.attach(FakeRegistry(known: ["server-a": urlA]))
        try await provider.save(tokenB, for: urlB)  // b is new: filed by address

        let transport = FakeTransport()
        let page = try Fixtures.api("listChanges.bootstrap").response()
        transport.stub(where: { _ in true }, { _ in page })
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    _ = await ServerProbe.serverId(
                        at: i % 2 == 0 ? urlA : urlB, transport: transport, credentials: provider)
                }
            }
        }
        #expect(transport.requests.count == 40)
        // A server with no token of its own never gets another's.
        #expect(try await provider.accessCredentials(for: URL(string: "https://c.example.com")!) == nil)
        for request in transport.requests {
            let expected = request.url.host() == "a.example.com" ? token : tokenB
            #expect(request.headers[QuickrHeader.cfAccessClientId] == expected.clientId)
            #expect(request.headers[QuickrHeader.cfAccessClientSecret] == expected.clientSecret)
        }
    }

    @Test func theLegacySingleTokenMovesToTheActiveServer() throws {
        let legacy = try JSONEncoder().encode(["clientId": "old.access", "clientSecret": "old"])
        // To the active server, by id.
        let keychain = InMemoryKeychain([KeychainAccessCredentials.legacyAccount: legacy])
        let provider = KeychainAccessCredentials(keychain: keychain)
        try provider.migrateLegacy(serverId: "server-a", baseURL: urlA)
        #expect(keychain.accounts == ["cloudflare-access:server:server-a"])
        #expect(try provider.stored(serverId: "server-a")?.clientId == "old.access")
        try provider.migrateLegacy(serverId: "server-a", baseURL: urlA)  // done once; nothing left
        #expect(keychain.accounts == ["cloudflare-access:server:server-a"])

        // Before any store: to the configured address.
        let early = InMemoryKeychain([KeychainAccessCredentials.legacyAccount: legacy])
        try KeychainAccessCredentials(keychain: early).migrateLegacy(serverId: nil, baseURL: urlB)
        #expect(early.accounts == ["cloudflare-access:url:https://b.example.com/quickr"])

        // No server at all: it waits.
        let waiting = InMemoryKeychain([KeychainAccessCredentials.legacyAccount: legacy])
        try KeychainAccessCredentials(keychain: waiting).migrateLegacy(serverId: nil, baseURL: nil)
        #expect(waiting.accounts == [KeychainAccessCredentials.legacyAccount])

        // A server's own newer token wins; the legacy item still goes.
        let both = InMemoryKeychain([KeychainAccessCredentials.legacyAccount: legacy])
        let bothProvider = KeychainAccessCredentials(keychain: both)
        try bothProvider.save(tokenB, serverId: "server-a")
        try bothProvider.migrateLegacy(serverId: "server-a", baseURL: nil)
        #expect(try bothProvider.stored(serverId: "server-a") == tokenB)
        #expect(both.accounts == ["cloudflare-access:server:server-a"])
    }

    @Test func keychainFailuresSurfaceWithoutTheSecret() async throws {
        let keychain = InMemoryKeychain()
        let provider = KeychainAccessCredentials(keychain: keychain)
        try await provider.save(token, for: urlA)
        keychain.fail(with: KeychainError(-25308))  // errSecInteractionNotAllowed (locked)
        await #expect(throws: KeychainError(-25308)) { try await provider.accessCredentials(for: urlA) }
        await #expect(throws: KeychainError(-25308)) { try await provider.save(token, for: urlA) }
        #expect(!KeychainError(-25308).description.contains("s3cr3t"))
    }

    @Test func aMalformedItemReadsAsNoToken() async throws {
        let keychain = InMemoryKeychain(["cloudflare-access:url:https://a.example.com": Data("not json".utf8)])
        #expect(try await KeychainAccessCredentials(keychain: keychain).accessCredentials(for: urlA) == nil)
    }

    @Test func requestsCarryTheStoredToken() async throws {
        let keychain = InMemoryKeychain()
        let provider = KeychainAccessCredentials(keychain: keychain)
        let transport = FakeTransport()
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))

        _ = await ServerProbe.serverId(at: urlA, transport: transport, credentials: provider)
        #expect(transport.requests.last?.headers[QuickrHeader.cfAccessClientId] == nil)

        try await provider.save(token, for: urlA)  // applies to the next request, nothing rebuilt
        _ = await ServerProbe.serverId(at: urlA, transport: transport, credentials: provider)
        #expect(transport.requests.last?.headers[QuickrHeader.cfAccessClientId] == "abc123.access")
        #expect(transport.requests.last?.headers[QuickrHeader.cfAccessClientSecret] == "s3cr3t-value")
    }

    @Test func theSecretNeverPrints() {
        for text in [
            String(describing: token), String(reflecting: token), "\(token)", "\([token])", "\(Optional(token) as Any)",
        ] {
            #expect(!text.contains("s3cr3t"), "\(text)")
            #expect(text.contains("<redacted>"), "\(text)")
        }
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains("s3cr3t"))
    }

    /// The secret is copied into each request's headers: requests, responses and headers print
    /// and reflect with it hidden, however they're printed, while the sender still sees it.
    @Test func requestsAndHeadersNeverPrintTheSecret() async throws {
        let transport = FakeTransport()
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))
        let keychain = InMemoryKeychain()
        try await KeychainAccessCredentials(keychain: keychain).save(
            token, for: URL(string: "https://quickr.example.com")!)
        _ = await ServerProbe.serverId(
            at: URL(string: "https://quickr.example.com")!, transport: transport,
            credentials: KeychainAccessCredentials(keychain: keychain))
        var request = try #require(transport.requests.last)
        #expect(request.headers.all[QuickrHeader.cfAccessClientSecret.lowercased()] == "s3cr3t-value")
        request.headers["Authorization"] = "Bearer t0ken-value"
        request.headers["Cookie"] = "session=c00kie-value"
        let response = HTTPResponse(
            status: 200, headers: ["Set-Cookie": "id=c00kie-value", "X-Api-Token": "t0ken-value"])

        var texts: [String] = []
        for value in [request as Any, request.headers, response, response.headers, [request], Optional(request) as Any]
        {
            texts.append(String(describing: value))
            texts.append(String(reflecting: value))
            texts.append("\(value)")
            var dumped = ""
            dump(value, to: &dumped)
            texts.append(dumped)
        }
        for text in texts {
            for secret in ["s3cr3t-value", "t0ken-value", "c00kie-value"] {
                #expect(!text.contains(secret), "\(secret) in \(text)")
            }
        }
        // What isn't a credential stays readable.
        #expect(request.description.contains("abc123.access"))
        #expect(request.description.contains("/api/v1/changes"))
        #expect(texts.contains { $0.contains("<redacted>") })
    }

    @Test func sensitiveHeaderNames() {
        for name in [
            "CF-Access-Client-Secret", "authorization", "Proxy-Authorization", "Cookie", "Set-Cookie", "X-Api-Key",
            "X-Auth-Token", "x-password", "Cf-Access-Jwt-Assertion",
        ] {
            #expect(HTTPHeaders.isSensitive(name), "\(name)")
        }
        for name in ["CF-Access-Client-Id", "Content-Type", "X-QuickR-Server-Id", "X-QuickR-Epoch", "Accept"] {
            #expect(!HTTPHeaders.isSensitive(name), "\(name)")
        }
    }

    @Test func formValidation() {
        #expect(AccessCredentials.validated(clientId: "", clientSecret: " ") == .success(nil))
        #expect(
            AccessCredentials.validated(clientId: " abc.access\n", clientSecret: " s ")
                == .success(
                    AccessCredentials(clientId: "abc.access", clientSecret: "s")))
        #expect(AccessCredentials.validated(clientId: "", clientSecret: "s") == .failure(.missingClientId))
        #expect(AccessCredentials.validated(clientId: "a", clientSecret: "") == .failure(.missingClientSecret))
        #expect(AccessCredentials.validated(clientId: "a\nb", clientSecret: "s") == .failure(.invalidCharacters))
        #expect(AccessCredentials.validated(clientId: "a", clientSecret: "sé") == .failure(.invalidCharacters))
    }
}

@Suite struct ConnectOutcomeTests {
    @Test func connectResultsBecomeWhatTheScreenSays() {
        #expect(
            SyncCoordinator.ConnectResult.connected(serverId: "s", isNew: true, sync: .synced).outcome
                == .connected(
                    serverId: "s", isNew: true, note: nil))
        guard
            case .connected(_, false, let note?) = SyncCoordinator.ConnectResult.connected(
                serverId: "s", isNew: false, sync: .failed(.unreachable("timeout"))
            ).outcome
        else {
            Issue.record("a failed first sync should still connect, with a note")
            return
        }
        #expect(note.contains("carries on"))
        #expect(SyncCoordinator.ConnectResult.notQuickr.outcome == .failed(.notQuickr))
        let cases: [(SyncFailure, ConnectProblem)] = [
            (.unreachable("offline"), .unreachable("offline")),
            (.rejected(status: 401, message: nil), .accessDenied(status: 401)),
            (.rejected(status: 403, message: "nope"), .accessDenied(status: 403)),
            (.rejected(status: 404, message: "Not found"), .rejected(status: 404, message: "Not found")),
            (.protocolError("bad json"), .protocolError("bad json")),
            (.storage("disk full"), .storage("disk full")),
            (.leaseBusy, .busy),
        ]
        for (failure, problem) in cases {
            #expect(SyncCoordinator.ConnectResult.failed(failure).outcome == .failed(problem), "\(failure)")
        }
    }

    @Test func problemsReadWellAndPointAtTheTokenWhenItCouldHelp() {
        let all: [ConnectProblem] = [
            .unreachable("x"), .notQuickr, .accessDenied(status: 403), .rejected(status: 400, message: "m"),
            .protocolError("p"), .storage("s"), .busy,
        ]
        for problem in all { #expect(!problem.description.isEmpty) }
        #expect(all.filter(\.suggestsAccessToken) == [.notQuickr, .accessDenied(status: 403)])
        #expect(ConnectProblem.unreachable("timed out").detail == "timed out")
        #expect(ConnectProblem.rejected(status: 400, message: "m").description.contains("400: m"))
    }
}

@Suite struct ServerProbeTests {
    let url = URL(string: "https://quickr.example.com")!

    @Test func readsTheServerIdFromOneFeedItem() async throws {
        let transport = FakeTransport()
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))
        let result = await ServerProbe.serverId(
            at: url, transport: transport, credentials: StaticAccessCredentials(nil))
        #expect(result == .success("00000000-0000-4000-8000-000000000009"))
        let request = try #require(transport.requests.first)
        #expect(request.url.path == "/api/v1/changes")
        #expect(request.url.query?.contains("after=0") == true)
        #expect(request.url.query?.contains("limit=1") == true)
    }

    @Test func mapsWhatCanGoWrong() async throws {
        let cases: [(Result<HTTPResponse, TransportError>, ConnectProblem)] = [
            // A login page or proxy: 200 without quickR's identity headers.
            (
                .success(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))),
                .notQuickr
            ),
            (
                .success(APITest.response(403, json: APITest.problem("forbidden"), identity: nil)),
                .accessDenied(status: 403)
            ),
        ]
        for (answer, problem) in cases {
            let transport = FakeTransport()
            transport.enqueue(answer)
            let result = await ServerProbe.serverId(
                at: url, transport: transport, credentials: StaticAccessCredentials(nil))
            #expect(result == .failure(problem), "\(answer)")
        }
        let offline = FakeTransport()
        offline.enqueue(.failure(.unreachable("The Internet connection appears to be offline.")))
        guard
            case .failure(.unreachable) = await ServerProbe.serverId(
                at: url, transport: offline, credentials: StaticAccessCredentials(nil))
        else {
            Issue.record("offline should be unreachable")
            return
        }
    }
}
