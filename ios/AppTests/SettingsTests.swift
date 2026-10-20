import Foundation
import QuickrCore
import QuickrData
import Synchronization
import Testing

@testable import QuickR

/// The real Keychain on the simulator, under a throwaway service.
@Test func systemKeychainStoresUpdatesAndDeletes() throws {
    let keychain = SystemKeychain(service: "com.bahumia.quickr.tests.\(UUID().uuidString)")
    defer { try? keychain.delete("item") }
    #expect(try keychain.data(for: "item") == nil)
    try keychain.set(Data("one".utf8), for: "item")
    #expect(try keychain.data(for: "item") == Data("one".utf8))
    try keychain.set(Data("two".utf8), for: "item")
    #expect(try keychain.data(for: "item") == Data("two".utf8))
    try keychain.delete("item")
    #expect(try keychain.data(for: "item") == nil)
    try keychain.delete("item")

    let credentials = KeychainAccessCredentials(keychain: keychain)
    let token = AccessCredentials(clientId: "abc.access", clientSecret: "secret")
    try credentials.save(token)
    #expect(try KeychainAccessCredentials(keychain: keychain).stored() == token)
    try credentials.save(nil)
    #expect(try credentials.stored() == nil)
}

/// `AppEnvironment.live` gives the session the Keychain token: a request carries it.
@MainActor
@Test func theLiveSessionSendsTheKeychainToken() async throws {
    let location = TestStores.emptyLocation()
    defer { TestStores.remove(location) }
    let suite = "settings-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = RecordingTransport()
    let environment = AppEnvironment.live(
        location: location, defaults: defaults, keychain: InMemoryKeychain(), transport: transport)
    let session = try #require(environment.session)
    try environment.credentials?.save(AccessCredentials(clientId: "abc.access", clientSecret: "secret"))

    _ = await session.probeServer(at: URL(string: "https://quickr.example")!)
    let request = try #require(transport.requests.last)
    #expect(request.headers[QuickrHeader.cfAccessClientId] == "abc.access")
    #expect(request.headers[QuickrHeader.cfAccessClientSecret] == "secret")
    await session.shutdown()
}

@MainActor
@Test func onboardingChecksTheFormBeforeAnyRequest() async throws {
    let (setup, transport, done) = try makeSetup()
    defer { done() }

    setup.address = "http://example.com"
    await setup.connect()
    #expect(
        setup.state
            == .failed(
                .init(message: ServerAddress.Problem.insecure.description, detail: nil, suggestsAccessToken: false)))

    setup.address = "quickr.example"
    setup.clientId = "only-the-id.access"
    await setup.connect()
    #expect(setup.showsAccessToken)
    guard case .failed(let failure) = setup.state else {
        Issue.record("a half-entered token should fail")
        return
    }
    #expect(failure.message == AccessCredentials.Problem.missingClientSecret.description)
    #expect(transport.requests.isEmpty)
}

@MainActor
@Test func onboardingConnectsAndRemembersTheAddress() async throws {
    let (setup, transport, done) = try makeSetup()
    defer { done() }
    transport.answer = .feed(serverId: "00000000-0000-4000-8000-0000000000aa")

    setup.address = " quickr.example/t/water/record "
    setup.clientId = "abc.access"
    setup.clientSecret = "secret"
    await setup.connect()
    #expect(setup.state == .connected(note: nil))
    #expect(setup.settings.serverURL == URL(string: "https://quickr.example"))
    #expect(setup.clientSecret.isEmpty)
    #expect(try setup.credentials?.stored()?.clientId == "abc.access")
    #expect(transport.requests.allSatisfy { $0.url.host() == "quickr.example" })
    #expect(setup.session.binding?.serverId == "00000000-0000-4000-8000-0000000000aa")
}

@MainActor
@Test func onboardingSaysWhatWentWrongAndOffersTheToken() async throws {
    let (setup, transport, done) = try makeSetup()
    defer { done() }
    setup.address = "https://quickr.example"

    transport.answer = .status(403, identity: false)
    await setup.connect()
    guard case .failed(let denied) = setup.state else {
        Issue.record("403 should fail")
        return
    }
    #expect(denied.suggestsAccessToken)
    #expect(setup.showsAccessToken)
    #expect(setup.settings.serverURL == nil)

    transport.answer = .status(200, identity: false)  // a login page
    await setup.connect()
    #expect(
        setup.state
            == .failed(.init(message: ConnectProblem.notQuickr.description, detail: nil, suggestsAccessToken: true)))
}

@MainActor
@Test func routerOpensLinksAndRemembersOnesItCannot() {
    let router = Router()
    let server = URL(string: "https://quickr.example")
    #expect(router.handle(url: URL(string: "quickr://t/water/record")!, serverURL: server))
    #expect(router.path == [.record(TopicLinkRef("water")!)])
    #expect(router.handle(url: URL(string: "https://quickr.example/settings")!, serverURL: server))
    #expect(router.path == [.settings])
    #expect(router.handle(path: "/t/water"))
    #expect(router.path == [.topic(TopicLinkRef("water")!, .overview)])

    #expect(!router.handle(url: URL(string: "quickr://nope")!, serverURL: server))
    #expect(router.path == [.topic(TopicLinkRef("water")!, .overview)])
    #expect(router.unopenedLink == URL(string: "quickr://nope"))
    #expect(router.handle(url: URL(string: "quickr://")!, serverURL: server))
    #expect(router.path.isEmpty)
}

@Test func resetWarningsSayWhatIsLost() {
    #expect(ResetFlow.message(count: 0).contains("Nothing is lost"))
    #expect(ResetFlow.message(count: 3).contains("3 changes haven’t synced"))
    #expect(ResetFlow.lossMessage(count: 3, failedCount: 1).contains("1 of them failed"))
    #expect(ResetFlow.lossLabel(count: 3) == "Delete 3 changes and reset")
    #expect(ResetFlow.lossLabel(count: 1) == "Delete 1 change and reset")
    #expect(!ResetFlow.lossMessage(count: 1, failedCount: 0).contains("failed"))
}

// MARK: - Support

@MainActor
private func makeSetup() throws -> (ServerSetup, RecordingTransport, () -> Void) {
    let location = TestStores.emptyLocation()
    let suite = "settings-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let transport = RecordingTransport()
    let credentials = KeychainAccessCredentials(keychain: InMemoryKeychain())
    let session = try AppSession(
        configuration: .init(location: location, transport: transport, credentials: credentials, notifier: nil))
    let setup = ServerSetup(session: session, settings: AppSettings(defaults: defaults), credentials: credentials)
    return (
        setup, transport,
        {
            Task { await session.shutdown() }
            defaults.removePersistentDomain(forName: suite)
            TestStores.remove(location)
        }
    )
}

/// Records requests and answers with `answer`.
final class RecordingTransport: Transport {
    enum Answer {
        case feed(serverId: String)
        case status(Int, identity: Bool)
    }

    private let state = Mutex<(requests: [HTTPRequest], answer: Answer)>(([], .status(503, identity: false)))

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var answer: Answer {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let answer = state.withLock {
            $0.requests.append(request)
            return $0.answer
        }
        switch answer {
        case .feed(let serverId):
            let headers: HTTPHeaders = [
                QuickrHeader.serverId: serverId, QuickrHeader.epoch: "00000000-0000-4000-8000-0000000000bb",
                "Content-Type": "application/json",
            ]
            let body = #"""
                {"items": [], "deleted": [], "next": 0, "has_more": false, "head": 0,
                 "epoch": "00000000-0000-4000-8000-0000000000bb", "server_id": "\#(serverId)",
                 "server_time": "2026-10-20T12:00:00+00:00"}
                """#
            return HTTPResponse(status: 200, headers: headers, body: Data(body.utf8))
        case .status(let status, let identity):
            var headers: HTTPHeaders = ["Content-Type": "text/html"]
            if identity {
                headers[QuickrHeader.serverId] = "x"
                headers[QuickrHeader.epoch] = "y"
            }
            return HTTPResponse(status: status, headers: headers, body: Data("<html></html>".utf8))
        }
    }
}
