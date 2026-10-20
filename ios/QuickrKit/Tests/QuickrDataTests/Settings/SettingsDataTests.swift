import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

private let token = AccessCredentials(clientId: "abc123.access", clientSecret: "s3cr3t-value")

@Suite struct KeychainAccessCredentialsTests {
    @Test func savesReadsAndRemovesTheToken() async throws {
        let keychain = InMemoryKeychain()
        let provider = KeychainAccessCredentials(keychain: keychain)
        #expect(try await provider.accessCredentials() == nil)

        try provider.save(token)
        #expect(keychain.accounts == [KeychainAccessCredentials.account])
        #expect(try await provider.accessCredentials() == token)
        // A second provider over the same Keychain (another process) sees it.
        #expect(try KeychainAccessCredentials(keychain: keychain).stored() == token)

        try provider.save(AccessCredentials(clientId: "new.access", clientSecret: "other"))
        #expect(try provider.stored()?.clientId == "new.access")

        try provider.save(nil)
        #expect(keychain.accounts.isEmpty)
        #expect(try await provider.accessCredentials() == nil)
        try provider.save(nil)  // removing nothing is fine
    }

    @Test func keychainFailuresSurfaceWithoutTheSecret() async throws {
        let keychain = InMemoryKeychain()
        let provider = KeychainAccessCredentials(keychain: keychain)
        try provider.save(token)
        keychain.fail(with: KeychainError(-25308))  // errSecInteractionNotAllowed (locked)
        await #expect(throws: KeychainError(-25308)) { try await provider.accessCredentials() }
        #expect(throws: KeychainError(-25308)) { try provider.save(token) }
        #expect(!KeychainError(-25308).description.contains("s3cr3t"))
    }

    @Test func aMalformedItemReadsAsNoToken() throws {
        let keychain = InMemoryKeychain([KeychainAccessCredentials.account: Data("not json".utf8)])
        #expect(try KeychainAccessCredentials(keychain: keychain).stored() == nil)
    }

    @Test func requestsCarryTheStoredToken() async throws {
        let keychain = InMemoryKeychain()
        let provider = KeychainAccessCredentials(keychain: keychain)
        let transport = FakeTransport()
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))
        transport.enqueue(.success(try Fixtures.api("listChanges.bootstrap").response()))
        let url = URL(string: "https://quickr.example.com")!

        _ = await ServerProbe.serverId(at: url, transport: transport, credentials: provider)
        #expect(transport.requests.last?.headers[QuickrHeader.cfAccessClientId] == nil)

        try provider.save(token)  // applies to the next request, nothing rebuilt
        _ = await ServerProbe.serverId(at: url, transport: transport, credentials: provider)
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
