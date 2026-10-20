import Foundation
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// N11 (notifications.md §9.1): the APNs environment of a provisioning profile.
@Suite(.timeLimit(.minutes(2))) struct ProvisioningProfileTests {
    static func profile(_ name: String) throws -> Data { try Fixtures.data("provisioning/\(name).mobileprovision") }

    @Test func noProfileIsAnAppStoreBuild() {
        #expect(ProvisioningProfile.apnsEnvironment(profile: nil) == .success(.production))
    }

    @Test func theProfilesEnvironmentIsRead() throws {
        #expect(ProvisioningProfile.apnsEnvironment(profile: try Self.profile("development")) == .success(.sandbox))
        #expect(ProvisioningProfile.apnsEnvironment(profile: try Self.profile("production")) == .success(.production))
    }

    @Test(arguments: [
        ("garbage", ProvisioningProfile.Failure.noPlist),
        ("no-plist-end", .noPlist),
        ("not-a-plist", .invalidPlist),
        ("no-entitlements", .noEntitlements),
        ("no-aps-environment", .noApsEnvironment),
        ("staging", .unknownEnvironment("staging")),
        ("not-a-string", .unknownEnvironment("__NSCFNumber")),
    ])
    func everyOtherProfileIsAnExplicitError(_ name: String, _ failure: ProvisioningProfile.Failure) throws {
        let result = ProvisioningProfile.apnsEnvironment(profile: try Self.profile(name))
        if case .unknownEnvironment = failure, case .failure(.unknownEnvironment(let value)) = result {
            #expect(name == "staging" ? value == "staging" : value != "production" && value != "development")
        } else {
            #expect(result == .failure(failure), "\(name)")
        }
    }
}

/// The token lifecycle (notifications.md §9.2; N12, N13) against fake servers that check the
/// Expect headers the way the backend does.
@MainActor @Suite(.timeLimit(.minutes(2))) struct PushRegistrationTests {
    /// A value the test and the dependencies' closures share.
    final class Box<T: Sendable>: Sendable {
        private let value: Mutex<T>
        init(_ value: T) { self.value = Mutex(value) }
        func withLock<R>(_ body: (inout T) -> R) -> R { value.withLock { body(&$0) } }
    }

    /// One quickR server per host: its identity, the devices it knows, and the Expect checks.
    final class Servers: Sendable {
        struct Server {
            var serverId: String
            var epoch: String
            var devices: Set<String> = []
            var apnsEnabled = true
        }

        let state = Mutex<[String: Server]>([:])

        func with<T>(_ host: String, _ body: (inout Server) -> T) -> T { state.withLock { body(&$0[host]!) } }

        func respond(_ request: HTTPRequest) throws -> HTTPResponse {
            let host = request.url.host!
            return try state.withLock { servers in
                guard var server = servers[host] else { throw TransportError.unreachable("no server") }
                defer { servers[host] = server }
                func reply(_ status: Int, _ json: Any?) -> HTTPResponse {
                    HTTPResponse(
                        status: status,
                        headers: [
                            "Content-Type": "application/json", QuickrHeader.serverId: server.serverId,
                            QuickrHeader.epoch: server.epoch,
                        ],
                        body: json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
                }
                func problem(_ status: Int, _ code: String) -> HTTPResponse {
                    reply(status, ["code": code, "detail": code, "errors": []])
                }
                // ExpectIdentity (B6): the server id first, then the epoch.
                guard request.headers[QuickrHeader.expectServerId] == server.serverId else {
                    return problem(409, "server_mismatch")
                }
                guard request.headers[QuickrHeader.expectEpoch] == server.epoch else {
                    return problem(409, "epoch_mismatch")
                }
                let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
                let token = body?["token"] as? String ?? ""
                switch request.url.path {
                case "/api/v1/push/apns/devices":
                    server.devices.insert(token)
                    return reply(
                        201,
                        [
                            "id": UUID().uuidString.lowercased(), "token": token,
                            "environment": body?["environment"] ?? "",
                            "bundle_id": body?["bundle_id"] ?? NSNull(),
                            "app_version": body?["app_version"] ?? NSNull(),
                            "device_name": body?["device_name"] ?? NSNull(), "created_at": "2026-03-04T12:00:00Z",
                            "updated_at": "2026-03-04T12:00:00Z",
                        ])
                case "/api/v1/push/apns/devices/delete":
                    server.devices.remove(token)
                    return reply(204, nil)
                case "/api/v1/push/apns/devices/test":
                    guard server.apnsEnabled else { return problem(409, "apns_disabled") }
                    guard server.devices.contains(token) else { return problem(404, "not_found") }
                    return reply(200, ["sent": 1, "failed": 0])
                default:
                    return problem(404, "not_found")
                }
            }
        }
    }

    static let a = PushRegistration.Server(
        identity: ServerIdentity(serverId: "00000000-0000-4000-8000-0000000000aa", epoch: "EA"),
        baseURL: URL(string: "https://a.quickr.example")!)
    static let b = PushRegistration.Server(
        identity: ServerIdentity(serverId: "00000000-0000-4000-8000-0000000000bb", epoch: "EB"),
        baseURL: URL(string: "https://b.quickr.example")!)
    static let token1 = Data([0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    static let token2 = Data([0xFE, 0xED, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

    @MainActor struct World {
        let registry = Registry(writer: try! TestDatabase.registry())
        let transport = FakeTransport()
        let servers = Servers()
        let wall = FakeClock()
        let lease = FakeLeaseClock()
        let authorization = Box(NotificationAuthorization.authorized)
        let environment = Box(Result<ApnsEnvironment, ProvisioningProfile.Failure>.success(.sandbox))
        let requests = Box(0)
        let registration: PushRegistration

        init() async throws {
            let (servers, authorization, environment, requests) = (servers, authorization, environment, requests)
            transport.stub(where: { _ in true }, { try servers.respond($0) })
            for server in [PushRegistrationTests.a, PushRegistrationTests.b] {
                servers.state.withLock {
                    $0[server.baseURL.host!] = .init(serverId: server.identity.serverId, epoch: server.identity.epoch)
                }
                _ = try await registry.register(
                    serverId: server.identity.serverId, baseURL: server.baseURL.absoluteString, now: wall.now())
            }
            registration = PushRegistration(
                dependencies: .init(
                    registry: registry, transport: transport, environment: { environment.withLock { $0 } },
                    authorization: { authorization.withLock { $0 } }, requestToken: { requests.withLock { $0 += 1 } },
                    bundleId: "com.bahumia.quickr", appVersion: "1.0 (7)", deviceName: "Test iPhone", wallClock: wall,
                    leaseClock: lease, random: { 0.5 }))
        }

        func devices(_ server: PushRegistration.Server) -> Set<String> {
            servers.with(server.baseURL.host!) { $0.devices }
        }

        var calls: [String] { transport.requests.map { "\($0.url.host!)\($0.url.path)" } }
        var owed: [PushRegistration.Owed] { get async throws { try await registration.owedRows() } }
    }

    // MARK: - N12

    @Test func launchAsksForATokenAndRegistersItWithBothExpectHeaders() async throws {
        let w = try await World()
        await w.registration.activated(active: Self.a, coldLaunch: true)
        #expect(w.requests.withLock { $0 } == 1 && w.registration.status == .requested)
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(w.registration.status == .registered(serverId: Self.a.identity.serverId))
        #expect(w.devices(Self.a) == ["abcd0102030405060708"], "lowercase hex")
        let request = try #require(w.transport.requests.last)
        #expect(request.headers[QuickrHeader.expectServerId] == Self.a.identity.serverId)
        #expect(request.headers[QuickrHeader.expectEpoch] == Self.a.identity.epoch)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(body["environment"] as? String == "sandbox" && body["device_name"] as? String == "Test iPhone")
        #expect(body["app_version"] as? String == "1.0 (7)" && body["bundle_id"] as? String == "com.bahumia.quickr")
    }

    @Test func aRotatedTokenIsRegisteredThenTheOldOneDeleted() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        await w.registration.didRegister(token: Self.token2, active: Self.a)
        #expect(w.devices(Self.a) == ["feed1122334455667788"])
        #expect(
            Array(w.calls.suffix(2)) == [
                "a.quickr.example/api/v1/push/apns/devices", "a.quickr.example/api/v1/push/apns/devices/delete",
            ])
        #expect(try await w.owed.isEmpty)
        for request in w.transport.requests {
            #expect(
                request.headers[QuickrHeader.expectServerId] != nil && request.headers[QuickrHeader.expectEpoch] != nil)
        }
    }

    @Test func denyingPermissionDeletesTheTokenAndAllowingAgainRegisters() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.authorization.withLock { $0 = .denied }
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.registration.status == .denied && w.devices(Self.a).isEmpty)
        #expect(try await w.registration.readState().registeredServerId == nil)
        #expect(w.requests.withLock { $0 } == 0)

        w.authorization.withLock { $0 = .authorized }
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 1, "not registered anywhere: ask for the token again")
    }

    @Test func aWarmActivationReRegistersOnlyAfterTwentyFourHours() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.wall.advance(by: 23 * 3600)
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 0)
        w.wall.advance(by: 2 * 3600)
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 1)
        await w.registration.activated(active: Self.b, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 2, "not registered with the active server")
    }

    @Test func anEnvironmentErrorRegistersNothing() async throws {
        let w = try await World()
        w.environment.withLock { $0 = .failure(.unknownEnvironment("staging")) }
        await w.registration.activated(active: Self.a, coldLaunch: true)
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(w.registration.status == .environmentError(.unknownEnvironment("staging")))
        #expect(w.requests.withLock { $0 } == 0 && w.transport.requests.isEmpty)
    }

    @Test func registeringWithTheActiveStoreAfterItsEpochRotatedAsksForARebuild() async throws {
        let w = try await World()
        w.servers.with(Self.a.baseURL.host!) { $0.epoch = "EA2" }
        let rebuilds = Mutex(0)
        w.registration.onActiveEpochMismatch = { rebuilds.withLock { $0 += 1 } }
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(rebuilds.withLock { $0 } == 1 && w.devices(Self.a).isEmpty)
        if case .failed = w.registration.status {} else { Issue.record("failed, not \(w.registration.status)") }
    }

    // MARK: - N13

    /// The old server rotated its epoch since the switch: `epoch_mismatch`, one retry with the
    /// header's epoch (same server id), done.
    @Test func unregisteringFromAnOldServerRetriesOnceWithItsNewEpoch() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.servers.with(Self.a.baseURL.host!) { $0.epoch = "EA2" }
        let before = w.transport.requests.count
        await w.registration.serverSwitched(from: Self.a)
        let deletes = w.transport.requests.dropFirst(before)
        #expect(deletes.count == 2)
        #expect(deletes.map { $0.headers[QuickrHeader.expectEpoch] } == ["EA", "EA2"])
        #expect(deletes.allSatisfy { $0.headers[QuickrHeader.expectServerId] == Self.a.identity.serverId })
        let owed = try await w.owed
        #expect(w.devices(Self.a).isEmpty && owed.isEmpty)
    }

    @Test func serverMismatchDropsTheOwedDeletion() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.servers.with(Self.a.baseURL.host!) { $0.serverId = "00000000-0000-4000-8000-0000000000cc" }
        let before = w.transport.requests.count
        await w.registration.serverSwitched(from: Self.a)
        #expect(w.transport.requests.count == before + 1, "never retried against that URL")
        #expect(try await w.owed.isEmpty)
    }

    @Test func aFailedDeletionIsRetriedWithBackoffForThirtyDays() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.servers.state.withLock { $0.removeValue(forKey: Self.a.baseURL.host!) }  // unreachable
        await w.registration.serverSwitched(from: Self.a)
        let owed = try #require(try await w.owed.first)
        #expect(owed.attempts == 1 && owed.due != nil)

        let calls = w.transport.requests.count
        await w.registration.retryOwed()
        #expect(w.transport.requests.count == calls, "not due yet")
        w.lease.advance(by: .seconds(3))  // the first backoff: 2 s × U(0.8, 1.2)
        await w.registration.retryOwed()
        #expect(w.transport.requests.count == calls + 1)
        #expect(try await w.owed.first?.attempts == 2)

        w.wall.advance(by: PushRegistration.pendingLifetime + 1)
        w.lease.advance(by: .seconds(600))
        await w.registration.retryOwed()
        #expect(try await w.owed.isEmpty, "given up after 30 days")
    }

    @Test func anInterruptedSwitchLearnsTheOldServersEpoch() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        // Registered with A, but B is active now and A's epoch was never recorded: deny forces the
        // deletion from A without one.
        w.authorization.withLock { $0 = .denied }
        await w.registration.activated(active: Self.b, coldLaunch: false)
        let owed = try await w.owed
        #expect(w.devices(Self.a).isEmpty && owed.isEmpty)
    }

    // MARK: - Test this device

    @Test func testThisDeviceReportsEachOutcome() async throws {
        let w = try await World()
        #expect(await w.registration.testThisDevice(active: Self.a) == .notRegistered, "no token yet")
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(await w.registration.testThisDevice(active: Self.a) == .sent)
        #expect(await w.registration.testThisDevice(active: Self.b) == .notRegistered, "B doesn't know it")
        w.servers.with(Self.a.baseURL.host!) { $0.apnsEnabled = false }
        #expect(await w.registration.testThisDevice(active: Self.a) == .disabled)
        w.servers.state.withLock { $0.removeValue(forKey: Self.a.baseURL.host!) }
        #expect(await w.registration.testThisDevice(active: Self.a) == .offline)
    }

    @Test func aLateTokenFailureDoesntUndoARegistration() async throws {
        let w = try await World()
        struct NoToken: Error {}
        w.registration.didFailToRegister(NoToken())
        if case .failed = w.registration.status {} else { Issue.record("failed before any registration") }
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.registration.didFailToRegister(NoToken())
        #expect(w.registration.status == .registered(serverId: Self.a.identity.serverId))
    }

    @Test func tokensAreRedactedForLogs() {
        let token = PushRegistration.hex(Self.token1)
        #expect(PushRegistration.redacted(token) == "abcd…0708")
        #expect(PushRegistration.redacted("short") == "<redacted>")
    }
}
