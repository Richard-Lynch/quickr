import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
import Synchronization
import Testing

@testable import QuickR

/// REG's app glue (notifications.md §9.2): the live environment's push lifecycle registers the
/// token the app delegate hands over, with both Expect headers, and stores it in the registry.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5))) struct PushLifecycleTests {
    /// Answers the APNs device calls as the seeded server; everything else is unreachable.
    final class PushServer: Transport {
        let calls = Mutex<[HTTPRequest]>([])
        let serverId: String
        let epoch: String

        init(serverId: String, epoch: String) {
            self.serverId = serverId
            self.epoch = epoch
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            guard request.url.path.hasPrefix("/api/v1/push/apns/devices") else {
                throw TransportError.unreachable("offline")
            }
            calls.withLock { $0.append(request) }
            let headers: HTTPHeaders = [
                "Content-Type": "application/json", QuickrHeader.serverId: serverId, QuickrHeader.epoch: epoch,
            ]
            guard request.url.path == "/api/v1/push/apns/devices" else {
                return HTTPResponse(status: 204, headers: headers)
            }
            let sent = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
            let body: [String: Any] = [
                "id": UUID().uuidString.lowercased(), "token": sent["token"] ?? "",
                "environment": sent["environment"] ?? "",
                "bundle_id": sent["bundle_id"] ?? NSNull(), "app_version": sent["app_version"] ?? NSNull(),
                "device_name": sent["device_name"] ?? NSNull(), "created_at": "2026-03-04T12:00:00Z",
                "updated_at": "2026-03-04T12:00:00Z",
            ]
            return HTTPResponse(status: 201, headers: headers, body: try JSONSerialization.data(withJSONObject: body))
        }
    }

    @Test func aTokenFromTheAppDelegateIsRegisteredWithTheActiveServer() async throws {
        let location = try await TestStores.seededLocation()
        defer { TestStores.remove(location) }
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        try await store.writer.write { db in try db.execute(sql: "UPDATE sync_state SET epoch = 'E1'") }

        let server = PushServer(serverId: "test-server", epoch: "E1")
        let suite = "reg-tests-\(UUID().uuidString)"
        // An in-memory Keychain: this is about registration, and CI's unsigned build has no Keychain.
        // No category center (the system's is shared with SystemNotificationCenterTests'
        // SystemCategoriesLock) and a private notification center (GRDB's suspension is
        // process-wide on the default one).
        let environment = AppEnvironment.live(
            location: location, defaults: UserDefaults(suiteName: suite)!, keychain: InMemoryKeychain(),
            transport: server, categoryCenter: nil, notificationCenter: NotificationCenter())
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await environment.start()
        let push = try #require(environment.push, "the live environment has push")
        let session = try #require(environment.session)
        defer { Task { await session.shutdown() } }

        // What `didRegisterForRemoteNotificationsWithDeviceToken` hands over (through
        // `RemoteNotificationTokens`, whose receiver other suites' live environments may claim while
        // tests run in parallel, so this hands it to this environment's lifecycle directly).
        await push.didRegister(token: Data([0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89]))

        let call = try #require(server.calls.withLock { $0.first })
        #expect(call.url.path == "/api/v1/push/apns/devices")
        #expect(call.headers[QuickrHeader.expectServerId] == "test-server")
        #expect(call.headers[QuickrHeader.expectEpoch] == "E1")
        let body = try #require(try JSONSerialization.jsonObject(with: call.body ?? Data()) as? [String: Any])
        #expect(body["token"] as? String == "abcdef0123456789" && body["environment"] as? String == "sandbox")
        #expect(push.status == .registered(serverId: "test-server"))
        let stored = try await partitions.registry.writer.read { db in
            try String.fetchOne(db, sql: "SELECT token FROM apns_state WHERE id = 1")
        }
        #expect(stored == "abcdef0123456789")
    }
}
