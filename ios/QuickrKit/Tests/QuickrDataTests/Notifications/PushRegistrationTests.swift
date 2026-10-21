import Foundation
import GRDB
import Observation
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// N11 (notifications.md §9.1): the APNs environment of a provisioning profile.
@Suite(.timeLimit(.minutes(5))) struct ProvisioningProfileTests {
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
@MainActor @Suite(.timeLimit(.minutes(5))) struct PushRegistrationTests {
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

    /// Holds the next request to one path until the test releases it: a response still on its way.
    final class Gate: Sendable {
        private let state = Mutex<(path: String?, parked: CheckedContinuation<Void, Never>?)>((nil, nil))

        func hold(_ path: String) { state.withLock { $0.path = path } }
        var isHolding: Bool { state.withLock { $0.parked != nil } }

        func release() {
            let parked = state.withLock { state in
                defer { state.parked = nil }
                return state.parked
            }
            parked?.resume()
        }

        func pass(_ request: HTTPRequest) async {
            guard state.withLock({ $0.path == request.url.path }) else { return }
            await withCheckedContinuation { continuation in
                state.withLock {
                    $0.path = nil
                    $0.parked = continuation
                }
            }
        }
    }

    final class GatedTransport: Transport {
        let inner: FakeTransport
        let gate: Gate

        init(_ inner: FakeTransport, gate: Gate) {
            self.inner = inner
            self.gate = gate
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            await gate.pass(request)
            return try await inner.send(request)
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
        let gate = Gate()
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
                    registry: registry, transport: GatedTransport(transport, gate: gate),
                    environment: { environment.withLock { $0 } },
                    authorization: { authorization.withLock { $0 } }, requestToken: { requests.withLock { $0 += 1 } },
                    bundleId: "com.bahumia.quickr", appVersion: "1.0 (7)", deviceName: "Test iPhone", wallClock: wall,
                    leaseClock: lease, random: { 0.5 }))
        }

        func devices(_ server: PushRegistration.Server) -> Set<String> {
            servers.with(server.baseURL.host!) { $0.devices }
        }

        var calls: [String] { transport.requests.map { "\($0.url.host!)\($0.url.path)" } }
        var state: PushRegistration.ApnsState { get async throws { try await registration.readState() } }
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

    /// The rebuild didn't succeed: no retry and no second rebuild; the registration is owed, with
    /// the backoff.
    @Test func anEpochMismatchWhoseRebuildFailsWaitsOutTheBackoff() async throws {
        let w = try await World()
        w.servers.with(Self.a.baseURL.host!) { $0.epoch = "EA2" }
        let rebuilds = Box(0)
        w.registration.recoverActiveEpoch = {
            rebuilds.withLock { $0 += 1 }
            return nil
        }
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(rebuilds.withLock { $0 } == 1 && w.transport.requests.count == 1 && w.devices(Self.a).isEmpty)
        if case .failed = w.registration.status {} else { Issue.record("failed, not \(w.registration.status)") }
        #expect(try await w.state.registerAttempts == 1)
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 0, "backing off, not looping")
    }

    @Test func anEpochMismatchIsRetriedOnceAfterTheRebuild() async throws {
        let w = try await World()
        w.servers.with(Self.a.baseURL.host!) { $0.epoch = "EA2" }
        let rebuilds = Box(0)
        var rebuilt = Self.a
        rebuilt.identity.epoch = "EA2"
        w.registration.recoverActiveEpoch = { [rebuilt] in
            rebuilds.withLock { $0 += 1 }
            return rebuilt
        }
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(rebuilds.withLock { $0 } == 1 && w.devices(Self.a) == ["abcd0102030405060708"])
        #expect(w.transport.requests.map { $0.headers[QuickrHeader.expectEpoch] } == ["EA", "EA2"])
        #expect(w.registration.status == .registered(serverId: Self.a.identity.serverId))
    }

    /// The epoch moved again while rebuilding: the retry fails too, and stops there.
    @Test func theRetryAfterARebuildDoesntRebuildAgain() async throws {
        let w = try await World()
        w.servers.with(Self.a.baseURL.host!) { $0.epoch = "EA3" }
        let rebuilds = Box(0)
        var rebuilt = Self.a
        rebuilt.identity.epoch = "EA2"
        w.registration.recoverActiveEpoch = { [rebuilt] in
            rebuilds.withLock { $0 += 1 }
            return rebuilt
        }
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        #expect(rebuilds.withLock { $0 } == 1 && w.transport.requests.count == 2 && w.devices(Self.a).isEmpty)
        #expect(try await w.state.registerAttempts == 1)
    }

    /// A rotation whose registration failed is retried at an activation after the backoff, not
    /// 24 h later.
    @Test func aFailedRegistrationIsRetriedAfterTheBackoff() async throws {
        let w = try await World()
        let host = Self.a.baseURL.host!
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        let a = try #require(w.servers.state.withLock { $0.removeValue(forKey: host) })  // unreachable
        await w.registration.didRegister(token: Self.token2, active: Self.a)
        #expect(try await w.state.registerAttempts == 1)
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 0, "not due yet")

        w.servers.state.withLock { $0[host] = a }
        w.lease.advance(by: .seconds(3))  // the first backoff: 2 s × U(0.8, 1.2)
        await w.registration.activated(active: Self.a, coldLaunch: false)
        #expect(w.requests.withLock { $0 } == 1 && w.registration.status == .requested)
        await w.registration.didRegister(token: Self.token2, active: Self.a)
        #expect(w.devices(Self.a) == ["feed1122334455667788"])
        let state = try await w.state
        #expect(state.registerAttempts == 0 && state.registerDue == nil)
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

    /// The usual order: registered earlier, then an activation asks again, then the system fails.
    @Test func aTokenFailureDoesntUndoARegistration() async throws {
        let w = try await World()
        struct NoToken: Error {}
        await w.registration.didFailToRegister(NoToken())
        if case .failed = w.registration.status {} else { Issue.record("failed before any registration") }
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        await w.registration.activated(active: Self.a, coldLaunch: true)
        #expect(w.registration.status == .requested)
        await w.registration.didFailToRegister(NoToken())
        #expect(w.registration.status == .registered(serverId: Self.a.identity.serverId))
    }

    @Test func theStatusIsObservable() async throws {
        let w = try await World()
        let changed = Box(false)
        withObservationTracking {
            _ = w.registration.status
        } onChange: {
            changed.withLock { $0 = true }
        }
        await w.registration.activated(active: Self.a, coldLaunch: true)
        #expect(changed.withLock { $0 })
    }

    // MARK: - Ordering

    /// A → B while A is unreachable leaves a deletion owed to A; back to A, registering there
    /// cancels it, so a later retry doesn't delete the registration just made.
    @Test func switchingBackToAServerKeepsTheRenewedRegistration() async throws {
        let w = try await World()
        let host = Self.a.baseURL.host!
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        let a = try #require(w.servers.state.withLock { $0.removeValue(forKey: host) })
        await w.registration.serverSwitched(from: Self.a)
        await w.registration.didRegister(token: Self.token1, active: Self.b)
        #expect(try await w.owed.map(\.serverId) == [Self.a.identity.serverId])

        w.servers.state.withLock { $0[host] = a }
        await w.registration.serverSwitched(from: Self.b)
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        w.lease.advance(by: .seconds(600))
        await w.registration.retryOwed()
        #expect(w.devices(Self.a) == ["abcd0102030405060708"] && w.devices(Self.b).isEmpty)
        #expect(try await w.owed.isEmpty)
        #expect(w.registration.status == .registered(serverId: Self.a.identity.serverId))
    }

    /// A's registration is still waiting for its response when the app switches to B: it is
    /// recorded first, then deleted from A by the switch.
    @Test func aRegistrationInFlightDuringASwitchIsDeletedFromTheOldServer() async throws {
        let w = try await World()
        w.gate.hold("/api/v1/push/apns/devices")
        let registering = Task { await w.registration.didRegister(token: Self.token1, active: Self.a) }
        while !w.gate.isHolding { await Task.yield() }
        let switched = Box(false)
        let switching = Task {
            await w.registration.serverSwitched(from: Self.a)
            switched.withLock { $0 = true }
        }
        // The switch has either run already or is waiting behind the registration.
        while !switched.withLock({ $0 }) && w.registration.inFlight < 2 { await Task.yield() }
        w.gate.release()
        await registering.value
        await switching.value
        #expect(w.devices(Self.a).isEmpty, "the late registration was deleted from A")
        #expect(try await w.owed.isEmpty)
        #expect(try await w.state.registeredServerId == nil)
    }

    /// The app reports A → B late: B's token arrives first. Registering with B owes A the
    /// deletion (its epoch learnt from the 409); the late switch report finds nothing more to do.
    @Test func aTokenForTheNewServerBeforeTheSwitchReportDeletesFromTheOld() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        await w.registration.didRegister(token: Self.token1, active: Self.b)
        #expect(w.devices(Self.a).isEmpty && w.devices(Self.b) == ["abcd0102030405060708"])
        await w.registration.serverSwitched(from: Self.a)
        #expect(try await w.owed.isEmpty)
        #expect(w.registration.status == .registered(serverId: Self.b.identity.serverId))
    }

    /// An activation on B arrives before the switch report: it reconciles too, and asks for the
    /// token for B.
    @Test func anActivationOnTheNewServerDeletesFromTheOld() async throws {
        let w = try await World()
        await w.registration.didRegister(token: Self.token1, active: Self.a)
        await w.registration.activated(active: Self.b, coldLaunch: false)
        #expect(w.devices(Self.a).isEmpty && w.requests.withLock { $0 } == 1)
        #expect(try await w.state.registeredServerId == nil)
        #expect(try await w.owed.isEmpty)
    }

    /// A switch reported while the rebuild runs waits for the registration (no deadlock), then
    /// sees it.
    @Test func anEventDuringTheEpochRecoveryRunsAfterIt() async throws {
        let w = try await World()
        w.servers.with(Self.a.baseURL.host!) { $0.epoch = "EA2" }
        var rebuilt = Self.a
        rebuilt.identity.epoch = "EA2"
        let switching = Box<Task<Void, Never>?>(nil)
        let registration = w.registration
        registration.recoverActiveEpoch = { [rebuilt] in
            switching.withLock { $0 = Task { await registration.serverSwitched(from: rebuilt) } }
            return rebuilt
        }
        await registration.didRegister(token: Self.token1, active: Self.a)
        #expect(w.devices(Self.a) == ["abcd0102030405060708"], "registered before the switch ran")
        await switching.withLock { $0 }?.value
        let owed = try await w.owed
        #expect(w.devices(Self.a).isEmpty && owed.isEmpty)
        #expect(try await w.state.registeredServerId == nil)
    }

    /// A caller that stops waiting doesn't stop its event: it still runs, in order.
    @Test func aCancelledCallerStillRunsItsEvent() async throws {
        let w = try await World()
        w.gate.hold("/api/v1/push/apns/devices")
        let first = Task { await w.registration.didRegister(token: Self.token1, active: Self.a) }
        while !w.gate.isHolding { await Task.yield() }
        let second = Task { await w.registration.didRegister(token: Self.token2, active: Self.a) }
        while w.registration.inFlight < 2 { await Task.yield() }
        second.cancel()
        w.gate.release()
        await first.value
        await second.value
        while w.registration.inFlight > 0 { await Task.yield() }
        #expect(w.devices(Self.a) == ["feed1122334455667788"], "rotated: the second ran after the first")
        #expect(try await w.state.token == "feed1122334455667788")
    }

    /// A registry with a registration from v1 keeps it through v2, with nothing owed.
    @Test func theV2MigrationKeepsAnExistingRegistration() async throws {
        let queue = try DatabaseQueue()
        var migrator = RegistrySchema.migrator()
        try migrator.migrate(queue, upTo: "v1")
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO apns_state (id, token, environment, registered_server_id, last_registered_at)
                    VALUES (1, 'abcd', 'sandbox', 'server-a', 1000)
                    """)
        }
        migrator = RegistrySchema.migrator()
        try migrator.migrate(queue)
        let registration = PushRegistration(
            dependencies: .init(
                registry: Registry(writer: queue), transport: FakeTransport(), environment: { .success(.sandbox) },
                authorization: { .authorized }, requestToken: {}))
        let state = try await registration.readState()
        #expect(state.token == "abcd" && state.environment == .sandbox && state.registeredServerId == "server-a")
        #expect(state.lastRegisteredAt == Date(timeIntervalSince1970: 1000))
        #expect(state.registerAttempts == 0 && state.registerDue == nil)
    }

    @Test func tokensAreRedactedForLogs() {
        let token = PushRegistration.hex(Self.token1)
        #expect(PushRegistration.redacted(token) == "abcd…0708")
        #expect(PushRegistration.redacted("short") == "<redacted>")
    }
}
