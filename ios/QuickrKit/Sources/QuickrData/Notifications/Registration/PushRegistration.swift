import Foundation
import GRDB
import QuickrCore

/// The APNs token lifecycle (notifications.md §9.2), app process only. Its state lives in the
/// registry (app-global): `apns_state` (the token, its environment, where it is registered and
/// when) and `pending_unregister` (deletions still owed to a server, retried for 30 days).
///
/// The app reports events; this decides the calls:
/// - ``activated(active:coldLaunch:)``: launch or `scenePhase → active`. Checks the environment
///   (§9.1) and the permission: denied deletes the token; allowed asks for a token when this is a
///   cold launch, 24 h have passed, or the token isn't registered with the active server. Then
///   retries owed deletions.
/// - ``didRegister(token:active:)``: registers (an upsert) with the active server; a token that
///   changed deletes the old one.
/// - ``serverSwitched(from:)``: deletes the token from the old server, with the old store's epoch.
/// - ``testThisDevice(active:)``: "Test this device".
///
/// Every call is a mutation and carries both Expect headers. The token is never logged in full
/// (``redacted(_:)``).
@MainActor
public final class PushRegistration {
    /// The server a call goes to.
    public struct Server: Sendable, Hashable {
        public var identity: ServerIdentity
        public var baseURL: URL

        public init(identity: ServerIdentity, baseURL: URL) {
            self.identity = identity
            self.baseURL = baseURL
        }
    }

    public struct Dependencies: Sendable {
        public var registry: Registry
        public var transport: any Transport
        public var credentials: any AccessCredentialsProvider
        /// This build's APNs environment (§9.1; the app answers `sandbox` on the simulator).
        public var environment: @Sendable () -> Result<ApnsEnvironment, ProvisioningProfile.Failure>
        public var authorization: @Sendable () async -> NotificationAuthorization
        /// `UIApplication.registerForRemoteNotifications()`; the token comes back through
        /// ``didRegister(token:active:)``.
        public var requestToken: @MainActor @Sendable () -> Void
        public var bundleId: String?
        public var appVersion: String?
        /// The user-visible device name (never a serial or a MAC).
        public var deviceName: String?
        public var wallClock: any WallClock
        public var leaseClock: any LeaseClock
        /// In `[0, 1)`, for the backoff jitter.
        public var random: @Sendable () -> Double

        public init(
            registry: Registry, transport: any Transport,
            credentials: any AccessCredentialsProvider = StaticAccessCredentials(nil),
            environment: @escaping @Sendable () -> Result<ApnsEnvironment, ProvisioningProfile.Failure>,
            authorization: @escaping @Sendable () async -> NotificationAuthorization,
            requestToken: @escaping @MainActor @Sendable () -> Void, bundleId: String? = nil, appVersion: String? = nil,
            deviceName: String? = nil, wallClock: any WallClock = SystemWallClock(),
            leaseClock: any LeaseClock = SystemLeaseClock(),
            random: @escaping @Sendable () -> Double = { .random(in: 0..<1) }
        ) {
            self.registry = registry
            self.transport = transport
            self.credentials = credentials
            self.environment = environment
            self.authorization = authorization
            self.requestToken = requestToken
            self.bundleId = bundleId
            self.appVersion = appVersion
            self.deviceName = deviceName
            self.wallClock = wallClock
            self.leaseClock = leaseClock
            self.random = random
        }
    }

    public enum Status: Sendable, Hashable {
        /// Nothing done yet this run.
        case idle
        /// Waiting for the system's token.
        case requested
        case registered(serverId: String)
        /// Not allowed to notify: nothing is registered.
        case denied
        /// §9.1: the profile has no valid APNs environment. Nothing is registered.
        case environmentError(ProvisioningProfile.Failure)
        /// The last call failed; it is retried at the next activation.
        case failed(String)
    }

    /// Re-registered at the first activation after this long (§9.2).
    public static let refreshInterval: TimeInterval = 24 * 3600
    /// An owed deletion is given up after this long.
    public static let pendingLifetime: TimeInterval = 30 * 24 * 3600

    public private(set) var status: Status = .idle
    /// Called when registering with the active server got `epoch_mismatch`: the coordinator
    /// rebuilds (sync-protocol.md §7), and the next activation registers again.
    public var onActiveEpochMismatch: (@MainActor () -> Void)?

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Events

    /// Launch or `scenePhase → active`. `active` is the bound store's server, nil before one.
    public func activated(active: Server?, coldLaunch: Bool) async {
        guard case .success = dependencies.environment() else {
            if case .failure(let failure) = dependencies.environment() { status = .environmentError(failure) }
            return
        }
        let authorization = await dependencies.authorization()
        let state = (try? await readState()) ?? ApnsState()
        if authorization == .denied {
            // Delete the token wherever it is registered; register again when permission returns.
            if let token = state.token, let serverId = state.registeredServerId {
                let epoch = active?.identity.serverId == serverId ? active?.identity.epoch : nil
                try? await owe(serverId: serverId, token: token, epoch: epoch)
                try? await writeState { $0.registeredServerId = nil }
            }
            status = .denied
        } else if authorization.allowsDelivery, let active {
            let stale =
                state.lastRegisteredAt.map {
                    dependencies.wallClock.now().timeIntervalSince($0) > Self.refreshInterval
                } ?? true
            if coldLaunch || stale || state.registeredServerId != active.identity.serverId || state.token == nil {
                status = .requested
                dependencies.requestToken()
            }
        }
        await retryOwed()
    }

    /// `didRegisterForRemoteNotificationsWithDeviceToken`: registers the token with the active
    /// server. A different stored token is deleted from the server it was registered with.
    public func didRegister(token data: Data, active: Server?) async {
        let token = Self.hex(data)
        let environment: ApnsEnvironment
        switch dependencies.environment() {
        case .success(let value): environment = value
        case .failure(let failure):
            status = .environmentError(failure)
            return
        }
        guard let active else { return }
        let body = ApnsDeviceInDTO(
            token: token, environment: environment, bundleId: dependencies.bundleId,
            appVersion: dependencies.appVersion, deviceName: dependencies.deviceName)
        let outcome: APIOutcome<ApnsDevice>
        do {
            outcome = try await client(active.baseURL).registerApnsDevice(
                body, options: RequestOptions(expecting: active.identity)
            ).outcome
        } catch {
            status = .failed(String(describing: error))
            return
        }
        switch outcome {
        case .success:
            let previous = (try? await readState()) ?? ApnsState()
            if let old = previous.token, old != token, let oldServer = previous.registeredServerId {
                // Rotation: the new token first, then the old one deleted (§9.2).
                let epoch = oldServer == active.identity.serverId ? active.identity.epoch : nil
                try? await owe(serverId: oldServer, token: old, epoch: epoch)
            }
            let now = dependencies.wallClock.now()
            try? await writeState {
                $0.token = token
                $0.environment = environment
                $0.registeredServerId = active.identity.serverId
                $0.lastRegisteredAt = now
            }
            status = .registered(serverId: active.identity.serverId)
            await retryOwed()
        case .epochMismatch:
            status = .failed("The server's data changed; registering again after the next sync")
            onActiveEpochMismatch?()
        case .identityMismatch:
            status = .failed("This address now answers as another server")
        default:
            status = .failed(outcome.problem?.detail ?? "Couldn't register this device for reminders")
        }
    }

    /// `didFailToRegisterForRemoteNotificationsWithError` (no entitlement, no network).
    public func didFailToRegister(_ error: any Error) {
        status = .failed("Couldn't get a push token: \(error.localizedDescription)")
    }

    /// A server switch: the token is deleted from the old server with the old store's identity
    /// (§9.2, sync-protocol.md §8.4). The next activation registers it with the new one.
    public func serverSwitched(from old: Server) async {
        let state = (try? await readState()) ?? ApnsState()
        if let token = state.token, state.registeredServerId == old.identity.serverId {
            try? await owe(serverId: old.identity.serverId, token: token, epoch: old.identity.epoch)
            try? await writeState { $0.registeredServerId = nil }
        }
        await retryOwed()
    }

    public enum TestOutcome: Sendable, Hashable {
        case sent
        /// No token yet, or not registered with this server.
        case notRegistered
        case disabled
        case offline
        case failed(String)
    }

    /// "Test this device" (online only): a test push to this device's token.
    public func testThisDevice(active: Server) async -> TestOutcome {
        guard let token = (try? await readState())?.token else { return .notRegistered }
        let outcome: APIOutcome<PushTestResult>
        do {
            outcome = try await client(active.baseURL).sendApnsTestPush(
                ApnsDeviceRefDTO(token: token), options: RequestOptions(expecting: active.identity)
            ).outcome
        } catch {
            return .failed(String(describing: error))
        }
        switch outcome {
        case .success(let result):
            return result.sent > 0 ? .sent : .failed("The test notification couldn't be delivered")
        case .notFound: return .notRegistered
        case .terminal(409, let problem) where problem?.code.rawValue == "apns_disabled": return .disabled
        case .retryable(.noResponse), .uncertain(.noResponse): return .offline
        default: return .failed(outcome.problem?.detail ?? "The test couldn't be sent")
        }
    }

    // MARK: - Owed deletions

    /// Retries every due deletion (§9.2): done on success or 404; one retry with the server's own
    /// epoch on `epoch_mismatch` (the registration belongs to the server, not to an epoch); dropped
    /// on `server_mismatch` (the old server is gone from that URL), on a refusal, or after 30
    /// days; otherwise retried later with the outbox backoff.
    public func retryOwed() async {
        let now = dependencies.leaseClock.now()
        let wall = dependencies.wallClock.now()
        guard let rows = try? await owedRows() else { return }
        for row in rows where row.due.map(now.hasPassed(deadline:)) ?? true {
            guard wall.timeIntervalSince(row.firstAttemptAt) <= Self.pendingLifetime,
                let server = try? await dependencies.registry.repository.server(id: row.serverId),
                let baseURL = URL(string: server.baseURL)
            else {
                try? await forget(row)
                continue
            }
            // An unknown epoch (an interrupted switch) is learnt from the 409 below.
            var identity = ServerIdentity(serverId: row.serverId, epoch: row.expectEpoch ?? "unknown")
            var outcome = await delete(row.token, at: baseURL, identity: identity)
            if case .epochMismatch(.preconditionRejected(let observed)) = outcome,
                observed.serverId == row.serverId
            {
                identity.epoch = observed.epoch
                outcome = await delete(row.token, at: baseURL, identity: identity)
            }
            switch outcome {
            case .success, .notFound:
                try? await forget(row)
            case .identityMismatch, .terminal:
                try? await forget(row)
            case .retryable, .uncertain, .epochMismatch, .none, .entryDeleted, .staleRevision:
                let delay = OutboxBackoff.delay(attempts: row.attempts + 1, random: dependencies.random())
                try? await reschedule(row, due: now.adding(delay), epoch: identity.epoch)
            }
        }
    }

    private func delete(_ token: String, at baseURL: URL, identity: ServerIdentity) async -> APIOutcome<EmptyBody>? {
        try? await client(baseURL).deleteApnsDevice(
            ApnsDeviceRefDTO(token: token), options: RequestOptions(expecting: identity)
        ).outcome
    }

    private func client(_ baseURL: URL) -> APIClient {
        APIClient(
            baseURL: baseURL, transport: dependencies.transport, identity: StaticServerIdentity(nil),
            credentials: dependencies.credentials, origin: .app)
    }

    // MARK: - Registry

    struct ApnsState: Sendable, Hashable {
        var token: String?
        var environment: ApnsEnvironment?
        var registeredServerId: String?
        var lastRegisteredAt: Date?
    }

    struct Owed: Sendable, Hashable {
        var serverId: String
        var token: String
        var expectEpoch: String?
        var firstAttemptAt: Date
        var attempts: Int
        var due: LeaseInstant?
    }

    func readState() async throws -> ApnsState {
        try await dependencies.registry.writer.read { db in try Self.state(db) }
    }

    nonisolated private static func state(_ db: Database) throws -> ApnsState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM apns_state WHERE id = 1") else { return ApnsState() }
        return ApnsState(
            token: row["token"], environment: (row["environment"] as String?).flatMap(ApnsEnvironment.init(rawValue:)),
            registeredServerId: row["registered_server_id"],
            lastRegisteredAt: (row["last_registered_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }

    private func writeState(_ change: @escaping @Sendable (inout ApnsState) -> Void) async throws {
        try await dependencies.registry.writer.write { db in
            var state = try Self.state(db)
            change(&state)
            try db.execute(
                sql: """
                    INSERT INTO apns_state (id, token, environment, registered_server_id, last_registered_at)
                    VALUES (1, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET token = excluded.token, environment = excluded.environment,
                      registered_server_id = excluded.registered_server_id,
                      last_registered_at = excluded.last_registered_at
                    """,
                arguments: [
                    state.token, state.environment?.rawValue, state.registeredServerId,
                    state.lastRegisteredAt?.timeIntervalSince1970,
                ])
        }
    }

    /// Records a deletion owed to `serverId` (kept if already owed).
    private func owe(serverId: String, token: String, epoch: String?) async throws {
        let now = dependencies.wallClock.now().timeIntervalSince1970
        try await dependencies.registry.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_unregister (server_id, token, expect_epoch, first_attempt_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (server_id, token) DO UPDATE
                      SET expect_epoch = COALESCE(excluded.expect_epoch, pending_unregister.expect_epoch)
                    """,
                arguments: [serverId, token, epoch, now])
        }
    }

    func owedRows() async throws -> [Owed] {
        try await dependencies.registry.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_unregister ORDER BY first_attempt_at").map { row in
                let bootId: String? = row["due_boot_id"]
                let ct: Int64? = row["due_ct"]
                return Owed(
                    serverId: row["server_id"], token: row["token"], expectEpoch: row["expect_epoch"],
                    firstAttemptAt: Date(timeIntervalSince1970: row["first_attempt_at"]), attempts: row["attempts"],
                    due: bootId.flatMap { boot in ct.map { LeaseInstant(bootId: boot, ct: $0) } })
            }
        }
    }

    private func forget(_ row: Owed) async throws {
        try await dependencies.registry.writer.write { db in
            try db.execute(
                sql: "DELETE FROM pending_unregister WHERE server_id = ? AND token = ?",
                arguments: [row.serverId, row.token])
        }
    }

    private func reschedule(_ row: Owed, due: LeaseInstant, epoch: String) async throws {
        try await dependencies.registry.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE pending_unregister SET attempts = attempts + 1, due_boot_id = ?, due_ct = ?,
                      expect_epoch = ?
                    WHERE server_id = ? AND token = ?
                    """,
                arguments: [due.bootId, due.ct, epoch == "unknown" ? row.expectEpoch : epoch, row.serverId, row.token])
        }
    }

    // MARK: - Tokens

    /// Lowercase hex, as the server stores it.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// A token as logs may show it: its first and last 4 characters only.
    public static func redacted(_ token: String) -> String {
        guard token.count > 12 else { return "<redacted>" }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }
}
