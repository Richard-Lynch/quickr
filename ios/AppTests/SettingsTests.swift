import Foundation
import QuickrCore
import QuickrData
import Security
import Synchronization
import Testing

@testable import QuickR

/// The real Keychain on the simulator, under a throwaway service.
/// Whether this build can use the real Keychain. CI's simulator build is unsigned, so every
/// Keychain call fails with `errSecMissingEntitlement` (-34018); a signed local build works.
enum SystemKeychainProbe {
    static let isAvailable: Bool = {
        let keychain = SystemKeychain(service: "com.bahumia.quickr.tests.probe.\(UUID().uuidString)")
        do {
            try keychain.set(Data("probe".utf8), for: "probe")
            try keychain.delete("probe")
            return true
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            return false
        } catch {
            return true  // any other failure is the test's to report
        }
    }()
}

@Test(.enabled(if: SystemKeychainProbe.isAvailable, "no Keychain entitlement in this (unsigned) build"))
func systemKeychainStoresUpdatesAndDeletes() throws {
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
    try credentials.save(token, serverId: "server-a")
    #expect(try KeychainAccessCredentials(keychain: keychain).stored(serverId: "server-a") == token)
    try credentials.save(nil, serverId: "server-a")
    #expect(try credentials.stored(serverId: "server-a") == nil)
    try keychain.delete("cloudflare-access:server:server-a")
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
        location: location, defaults: defaults, keychain: InMemoryKeychain(), transport: transport,
        categoryCenter: nil)
    let session = try #require(environment.session)
    try await environment.credentials?.save(
        AccessCredentials(clientId: "abc.access", clientSecret: "secret"), for: URL(string: "https://quickr.example")!)

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
    // Filed under the server's id once connected.
    #expect(try setup.credentials?.stored(serverId: "00000000-0000-4000-8000-0000000000aa")?.clientId == "abc.access")
    #expect(transport.requests.allSatisfy { $0.url.host() == "quickr.example" })
    #expect((setup.switcher as? AppSession)?.binding?.serverId == "00000000-0000-4000-8000-0000000000aa")
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

/// sync-protocol.md §8.4: with a change still unsynced, another server at the new address asks
/// first; the same server at a new address doesn't.
@MainActor
@Test func switchingServersWithUnsyncedChangesAsksFirst() async throws {
    let location = try await TestStores.seededLocation()  // server "test-server"
    defer { TestStores.remove(location) }
    let suite = "settings-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // The log stays unsynced: its sends get 503 whatever the address checks are answered, so a
    // flush landing while `answer` is another server's feed can't change the entry's state.
    let transport = RecordingTransport()
    transport.writes = .status(503, identity: false)
    let credentials = KeychainAccessCredentials(keychain: InMemoryKeychain())
    let session = try AppSession(
        configuration: .init(location: location, transport: transport, credentials: credentials, notifier: nil))
    await session.start()
    #expect(session.phase == .ready)
    _ = try await session.log(
        topic: TopicRef(id: PlaceholderTopicRepository.coffee, slug: "coffee", name: "Coffee"), answers: [:], version: 1
    )
    let setup = ServerSetup(session: session, settings: AppSettings(defaults: defaults), credentials: credentials)

    // The same server at another address: no warning, the store stays.
    transport.answer = .feed(serverId: "test-server")
    setup.address = "https://quickr-new.example"
    await setup.connect()
    #expect(setup.state == .connected(note: nil))
    #expect(session.binding?.serverId == "test-server")
    #expect(session.binding?.baseURL == URL(string: "https://quickr-new.example"))

    // Another server: stop and ask, nothing switched yet.
    transport.answer = .feed(serverId: "other-server")
    setup.address = "https://other.example"
    await setup.connect()
    guard case .confirmSwitch(let warning) = setup.state else {
        Issue.record("expected the switch warning, got \(setup.state)")
        await session.shutdown()
        return
    }
    #expect(warning.count == 1 && warning.failedCount == 0)
    #expect(warning.oldServer == "quickr-new.example" && warning.targetServerId == "other-server")
    #expect(session.binding?.serverId == "test-server")

    // Cancel leaves everything as it was; "Switch anyway" switches.
    setup.edit()
    #expect(setup.state == .editing && session.binding?.serverId == "test-server")
    await setup.connect()
    setup.confirmSwitch(syncFirst: false)
    for _ in 0..<50 where setup.isWorking { try await Task.sleep(for: .milliseconds(100)) }
    #expect(setup.state == .connected(note: nil))
    #expect(session.binding?.serverId == "other-server")
    #expect(setup.settings.serverURL == URL(string: "https://other.example"))
    await session.shutdown()
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

    // A link that names its store (a widget's) isn't opened here: AppEnvironment checks it first
    // (notifications.md §7.5).
    let scoped = URL(string: "quickr://t/water/record?scope=0b9e0000-0000-4000-8000-0000000000aa/1")!
    #expect(!router.handle(url: scoped, serverURL: server))
    #expect(router.path.isEmpty)
}

@Test func resetWarningsSayWhatIsLost() {
    #expect(ResetFlow.message(count: 0, failedCount: 0).contains("Nothing is lost"))
    let pending = ResetFlow.message(count: 3, failedCount: 1)
    #expect(pending.contains("3 changes haven’t synced (1 failed)") && pending.contains("Sync first"))
    #expect(ResetFlow.message(count: 1, failedCount: 0, afterSync: true).hasPrefix("Syncing didn’t send everything."))
    #expect(ResetFlow.lossMessage(count: 3, failedCount: 1).contains("1 of them failed"))
    #expect(ResetFlow.lossLabel(count: 3) == "Delete 3 changes and reset")
    #expect(ResetFlow.lossLabel(count: 1) == "Delete 1 change and reset")
    #expect(!ResetFlow.lossMessage(count: 1, failedCount: 0).contains("failed"))
}

// MARK: - Switching servers: the token waits for the confirmed switch (fakes)

private let tokenA = AccessCredentials(clientId: "a.access", clientSecret: "secret-a")
private let tokenB = AccessCredentials(clientId: "b.access", clientSecret: "secret-b")
private let urlA = URL(string: "https://a.example")!
private let urlB = URL(string: "https://b.example")!

/// A registry that knows servers at fixed addresses.
private struct FakeRegistry: RegistryRepository {
    var known: [String: URL]

    func servers() async throws -> [RegisteredServer] {
        known.map { RegisteredServer(id: $0.key, baseURL: $0.value.absoluteString, createdAt: Date()) }
    }

    func server(id: String) async throws -> RegisteredServer? { try await servers().first { $0.id == id } }
    func activeServerId() async throws -> String? { nil }
    func notificationCategories() async throws -> [NotificationCategoryRecord] { [] }
}

@MainActor
@Test func aFailedProbeLeavesTheActiveServersToken() async throws {
    let (setup, switcher, credentials) = try fakeSetup(pending: 2)
    switcher.probeResult = .failure(.accessDenied(status: 403))
    setup.address = "https://b.example"
    setup.clientId = tokenB.clientId
    setup.clientSecret = tokenB.clientSecret
    await setup.connect()
    guard case .failed = setup.state else {
        Issue.record("the probe failed")
        return
    }
    #expect(switcher.probedWith == [tokenB], "the probe used the typed token")
    #expect(try credentials.stored(serverId: "server-a") == tokenA, "A keeps its token")
    #expect(try await credentials.stored(for: urlB) == nil, "nothing stored for B")
    #expect(switcher.connected.isEmpty)
}

@MainActor
@Test func cancellingTheSwitchLeavesTheActiveServersToken() async throws {
    let (setup, switcher, credentials) = try fakeSetup(pending: 2)
    setup.address = "https://b.example"
    setup.clientId = tokenB.clientId
    setup.clientSecret = tokenB.clientSecret
    await setup.connect()
    guard case .confirmSwitch(let warning) = setup.state else {
        Issue.record("expected the switch warning, got \(setup.state)")
        return
    }
    #expect(warning.count == 2 && warning.failedCount == 1 && warning.oldServer == "a.example")
    #expect(try credentials.stored(serverId: "server-a") == tokenA)
    setup.edit()
    #expect(try credentials.stored(serverId: "server-a") == tokenA)
    #expect(try await credentials.stored(for: urlB) == nil)
    #expect(switcher.connected.isEmpty && switcher.flushes.isEmpty)
}

@MainActor
@Test func syncNowFlushesWithTheActiveServersTokenThenSwitches() async throws {
    let (setup, switcher, credentials) = try fakeSetup(pending: 2)
    setup.address = urlB.absoluteString
    setup.clientId = tokenB.clientId
    setup.clientSecret = tokenB.clientSecret
    await setup.connect()
    setup.confirmSwitch(syncFirst: true)
    try await settle(setup)
    #expect(switcher.flushes == [tokenA], "the flush to A carried A's token")
    #expect(switcher.connected == [urlB])
    // During B's connect, a background flush to A still gets A's token; B's connect gets B's.
    #expect(switcher.atConnect.map(\.toA) == [tokenA])
    #expect(switcher.atConnect.map(\.toB) == [tokenB])
    #expect(setup.state == .connected(note: nil))
    #expect(try credentials.stored(serverId: "server-b") == tokenB, "filed under B's id")
    #expect(try credentials.stored(serverId: "server-a") == tokenA, "A's untouched")
}

@MainActor
@Test func aFailedConnectLeavesBothTokens() async throws {
    let (setup, switcher, credentials) = try fakeSetup(pending: 2)
    switcher.connectResult = .failed(.unreachable("timed out"))
    setup.address = urlB.absoluteString
    setup.clientId = tokenB.clientId
    setup.clientSecret = tokenB.clientSecret
    await setup.connect()
    setup.confirmSwitch(syncFirst: false)
    try await settle(setup)
    #expect(switcher.atConnect.map(\.toA) == [tokenA])
    guard case .failed = setup.state else {
        Issue.record("the connect failed")
        return
    }
    #expect(try credentials.stored(serverId: "server-a") == tokenA)
    #expect(try await credentials.stored(for: urlB) == tokenB, "kept under B's address for a retry")
    #expect(setup.settings.serverURL == nil)
}

@MainActor
@Test func aWarningThatCantBeReadStopsTheSwitch() async throws {
    let (setup, switcher, credentials) = try fakeSetup(pending: 2)
    switcher.warningError = KeychainError(-1)
    setup.address = "https://b.example"
    await setup.connect()
    guard case .failed(let failure) = setup.state else {
        Issue.record("expected a failure, got \(setup.state)")
        return
    }
    #expect(failure.message.contains("nothing was switched"))
    #expect(switcher.connected.isEmpty)
    #expect(try credentials.stored(serverId: "server-a") == tokenA)
}

@MainActor
@Test func nothingTypedProbesWithTheTargetsOwnToken() async throws {
    let (setup, switcher, credentials) = try fakeSetup(pending: 0)
    setup.address = urlB.absoluteString
    await setup.connect()
    try await settle(setup)
    #expect(switcher.probedWith == [nil], "never A's token for B")
    #expect(switcher.connected == [urlB])

    // A token saved earlier for B's address (a failed attempt) is B's to use.
    try await credentials.save(tokenB, for: URL(string: "https://c.example")!)
    setup.address = "https://c.example"
    await setup.connect()
    try await settle(setup)
    #expect(switcher.probedWith.last == tokenB)
}

// MARK: - Reset (fakes)

@MainActor
@Test func resetWithNothingPendingNeedsOneConfirmation() async throws {
    let reset = FakeReset(counts: [0])
    let flow = ResetFlow(reset: reset)
    await flow.begin()
    flow.confirmed()
    try await settle(flow)
    #expect(reset.performed.map(\.count) == [0])
    #expect(flow.state == .done("Done. Everything was reloaded from the server."))
}

@MainActor
@Test func syncFirstThatSendsEverythingResets() async throws {
    let reset = FakeReset(counts: [3, 0])
    let flow = ResetFlow(reset: reset)
    await flow.begin()
    guard case .confirm(let warning, false) = flow.state else {
        Issue.record("expected the warning")
        return
    }
    #expect(warning.count == 3)
    flow.confirmed()  // "Reset" isn't offered with changes pending
    #expect(reset.performed.isEmpty)
    flow.syncFirst()
    try await settle(flow)
    #expect(reset.flushes == 1)
    #expect(reset.performed.map(\.count) == [0], "reset with the fresh, empty warning")
    guard case .done = flow.state else {
        Issue.record("expected done, got \(flow.state)")
        return
    }
}

@MainActor
@Test func syncFirstThatLeavesChangesAsksAgain() async throws {
    let reset = FakeReset(counts: [3, 1])
    let flow = ResetFlow(reset: reset)
    await flow.begin()
    flow.syncFirst()
    try await settle(flow)
    #expect(reset.flushes == 1 && reset.performed.isEmpty)
    guard case .confirm(let warning, true) = flow.state else {
        Issue.record("expected the warning again, got \(flow.state)")
        return
    }
    #expect(warning.count == 1)
    // "Reset anyway" asks once more, destructively, then resets.
    flow.resetAnyway()
    guard case .confirmLoss = flow.state else {
        Issue.record("expected the destructive confirmation")
        return
    }
    #expect(reset.performed.isEmpty)
    flow.confirmedLoss()
    try await settle(flow)
    #expect(reset.performed.map(\.count) == [1])
}

@MainActor
@Test func writesDuringTheResetAskAgain() async throws {
    let reset = FakeReset(counts: [0])
    reset.outcome = .writesArrived(
        SyncCoordinator.ResetWarning(serverId: "s", storeGen: 1, count: 2, failedCount: 0, maxSeq: 7))
    let flow = ResetFlow(reset: reset)
    await flow.begin()
    flow.confirmed()
    try await settle(flow)
    guard case .confirm(let warning, false) = flow.state else {
        Issue.record("expected the new warning, got \(flow.state)")
        return
    }
    #expect(warning.count == 2)
}

@MainActor
@Test func aWarningThatCantBeReadResetsNothing() async throws {
    let reset = FakeReset(counts: [])
    reset.warningError = KeychainError(-1)
    let flow = ResetFlow(reset: reset)
    await flow.begin()
    guard case .failed(let message) = flow.state else {
        Issue.record("expected a failure")
        return
    }
    #expect(message.contains("nothing was reset"))
    #expect(reset.performed.isEmpty)
}

// MARK: - Support

/// Waits (up to 5 s) until the setup or flow has stopped working.
@MainActor
private func settle(_ setup: ServerSetup) async throws {
    for _ in 0..<50 where setup.isWorking { try await Task.sleep(for: .milliseconds(100)) }
}

@MainActor
private func settle(_ flow: ResetFlow) async throws {
    for _ in 0..<50 where flow.isBusy { try await Task.sleep(for: .milliseconds(100)) }
}

/// Server A active with `pending` unsynced changes (one failed), token A stored; probes answer
/// server B.
@MainActor
private func fakeSetup(pending: Int) throws -> (ServerSetup, FakeSwitcher, KeychainAccessCredentials) {
    let directory = ServerDirectory()
    directory.attach(FakeRegistry(known: ["server-a": urlA]))
    let credentials = KeychainAccessCredentials(keychain: InMemoryKeychain(), directory: directory)
    try credentials.save(tokenA, serverId: "server-a")
    let switcher = FakeSwitcher(credentials: credentials, pending: pending)
    let defaults = try #require(UserDefaults(suiteName: "settings-fake-\(UUID().uuidString)"))
    return (
        ServerSetup(switcher: switcher, settings: AppSettings(defaults: defaults), credentials: credentials), switcher,
        credentials
    )
}

@MainActor
private final class FakeSwitcher: ServerSwitcher {
    let credentials: KeychainAccessCredentials
    let pending: Int
    var probeResult: Result<String, ConnectProblem> = .success("server-b")
    var connectResult: ConnectOutcome = .connected(serverId: "server-b", isNew: true, note: nil)
    var warningError: (any Error)?
    private(set) var probedWith: [AccessCredentials?] = []
    /// The token a request to A gets at each flush.
    private(set) var flushes: [AccessCredentials?] = []
    /// What requests to A (a background flush) and to the target get, during each connect.
    private(set) var atConnect: [(toA: AccessCredentials?, toB: AccessCredentials?)] = []
    private(set) var connected: [URL] = []

    init(credentials: KeychainAccessCredentials, pending: Int) {
        self.credentials = credentials
        self.pending = pending
    }

    var activeServer: (id: String, baseURL: URL)? { ("server-a", urlA) }

    func probe(_ url: URL, credentials: any AccessCredentialsProvider) async -> Result<String, ConnectProblem> {
        probedWith.append(try? await credentials.accessCredentials(for: url))
        return probeResult
    }

    func unsyncedChanges() async throws -> (count: Int, failed: Int)? {
        if let warningError { throw warningError }
        return (pending, pending > 0 ? 1 : 0)
    }

    func flush() async {
        flushes.append(try? await credentials.accessCredentials(for: urlA))
    }

    func connect(_ url: URL) async -> ConnectOutcome {
        let toA = try? await credentials.accessCredentials(for: urlA)
        let toB = try? await credentials.accessCredentials(for: url)
        atConnect.append((toA, toB))
        connected.append(url)
        guard case .connected = connectResult, case .success(let id) = probeResult else { return connectResult }
        return .connected(serverId: id, isNew: true, note: nil)
    }
}

/// Warnings with the counts in `counts`, one per read (the last repeats).
@MainActor
private final class FakeReset: LocalReset {
    private var counts: [Int]
    var warningError: (any Error)?
    var outcome: SyncCoordinator.ResetOutcome = .completed(storeGen: 2, bootstrap: .synced)
    private(set) var flushes = 0
    private(set) var performed: [SyncCoordinator.ResetWarning] = []

    init(counts: [Int]) { self.counts = counts }

    func resetWarning() async throws -> SyncCoordinator.ResetWarning? {
        if let warningError { throw warningError }
        let count = counts.count > 1 ? counts.removeFirst() : counts.first ?? 0
        return SyncCoordinator.ResetWarning(
            serverId: "s", storeGen: 1, count: count, failedCount: count > 0 ? 1 : 0, maxSeq: Int64(count))
    }

    func flushForReset() async { flushes += 1 }

    func performReset(confirmed: SyncCoordinator.ResetWarning) async throws -> SyncCoordinator.ResetOutcome {
        performed.append(confirmed)
        return outcome
    }
}

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

/// Records requests and answers with `answer`; writes (anything but GET) with `writes` when set.
final class RecordingTransport: Transport {
    enum Answer {
        case feed(serverId: String)
        case status(Int, identity: Bool)
    }

    private let state = Mutex<(requests: [HTTPRequest], answer: Answer, writes: Answer?)>(
        ([], .status(503, identity: false), nil))

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var answer: Answer {
        get { state.withLock { $0.answer } }
        set { state.withLock { $0.answer = newValue } }
    }
    var writes: Answer? {
        get { state.withLock { $0.writes } }
        set { state.withLock { $0.writes = newValue } }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let answer = state.withLock {
            $0.requests.append(request)
            return request.method != .get ? $0.writes ?? $0.answer : $0.answer
        }
        switch answer {
        case .feed(let serverId):
            let headers: HTTPHeaders = [
                QuickrHeader.serverId: serverId, QuickrHeader.epoch: "00000000-0000-4000-8000-0000000000bb",
                "Content-Type": "application/json",
            ]
            // The server's clock is the device's (no skew). A fixed time would drift: a day after
            // it, every entry logged now is more than 24 h ahead of the server and fails as
            // future_time (`OutboxFlush.capturedAtMaxFutureHours`), which made the switch warning
            // count a failed change.
            let now = Date().formatted(.iso8601)
            let body = #"""
                {"items": [], "deleted": [], "next": 0, "has_more": false, "head": 0,
                 "epoch": "00000000-0000-4000-8000-0000000000bb", "server_id": "\#(serverId)",
                 "server_time": "\#(now)"}
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
