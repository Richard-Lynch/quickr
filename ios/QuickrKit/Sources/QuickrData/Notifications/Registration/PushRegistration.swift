import Foundation
import GRDB
import Observation
import QuickrCore

/// The APNs token lifecycle (notifications.md §9.2), app process only. Its state lives in the
/// registry (app-global): `apns_state` (the token, its environment, where it is registered and
/// when, and a registration still owed) and `pending_unregister` (deletions still owed to a
/// server, retried for 30 days).
///
/// The app reports events; this decides the calls:
/// - ``activated(active:coldLaunch:)``: launch or `scenePhase → active`. Checks the environment
///   (§9.1) and the permission: denied deletes the token; allowed asks for a token when this is a
///   cold launch, 24 h have passed, the token isn't registered with the active server, or a failed
///   registration is due again (outbox backoff). Then retries owed deletions.
/// - ``didRegister(token:active:)``: registers (an upsert) with the active server; a token that
///   changed deletes the old one.
/// - ``serverSwitched(from:)``: deletes the token from the old server, with the old store's epoch.
/// - ``testThisDevice(active:)``: "Test this device".
///
/// The events run one at a time, in the order they arrive: a registration still waiting for its
/// response finishes (and is recorded) before a server switch looks at where the token is
/// registered, and no owed deletion is in flight while a registration runs. And whichever event
/// first meets a new active server reconciles from the stored state: a token registered with
/// another server is owed a deletion there (its epoch learnt from the 409 when no switch reported
/// it), so the order the app reports a switch and a token in doesn't matter.
///
/// Every call is a mutation and carries both Expect headers. The token is never logged in full
/// (``redacted(_:)``).
@MainActor @Observable
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
        /// Where a server's responses leave their run-event offset samples (timers.md §5.1): its
        /// store's, when the app has it open. Nil keeps none.
        public var serverOffset: @Sendable (_ serverId: String) async -> (any ServerOffsetRecorder)?

        public init(
            registry: Registry, transport: any Transport,
            credentials: any AccessCredentialsProvider = StaticAccessCredentials(nil),
            environment: @escaping @Sendable () -> Result<ApnsEnvironment, ProvisioningProfile.Failure>,
            authorization: @escaping @Sendable () async -> NotificationAuthorization,
            requestToken: @escaping @MainActor @Sendable () -> Void, bundleId: String? = nil, appVersion: String? = nil,
            deviceName: String? = nil, wallClock: any WallClock = SystemWallClock(),
            leaseClock: any LeaseClock = SystemLeaseClock(),
            random: @escaping @Sendable () -> Double = { .random(in: 0..<1) },
            serverOffset: @escaping @Sendable (_ serverId: String) async -> (any ServerOffsetRecorder)? = { _ in nil }
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
            self.serverOffset = serverOffset
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
    /// Registering with the active server got `epoch_mismatch`: the coordinator rebuilds
    /// (sync-protocol.md §7) and answers the active server afterwards, or nil when the rebuild
    /// didn't succeed. A rebuild that moved the epoch retries the registration once; otherwise it
    /// is owed, with the backoff.
    @ObservationIgnored public var recoverActiveEpoch: (@MainActor () async -> Server?)?

    @ObservationIgnored private let dependencies: Dependencies
    /// The last event's work: the next one starts after it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Events started or waiting (for tests).
    @ObservationIgnored private(set) var inFlight = 0

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Events

    /// Launch or `scenePhase → active`. `active` is the bound store's server, nil before one.
    public func activated(active: Server?, coldLaunch: Bool) async {
        await serially { await self.performActivated(active: active, coldLaunch: coldLaunch) }
    }

    /// `didRegisterForRemoteNotificationsWithDeviceToken`: registers the token with the active
    /// server. A different stored token is deleted from the server it was registered with.
    public func didRegister(token data: Data, active: Server?) async {
        await serially { await self.performDidRegister(token: data, active: active) }
    }

    /// `didFailToRegisterForRemoteNotificationsWithError` (no entitlement, no network). A token
    /// already registered stays so: the server still has it.
    public func didFailToRegister(_ error: any Error) async {
        let message = "Couldn't get a push token: \(error.localizedDescription)"
        await serially {
            let state = (try? await self.readState()) ?? ApnsState()
            if state.token != nil, let serverId = state.registeredServerId {
                self.status = .registered(serverId: serverId)
            } else {
                self.status = .failed(message)
            }
        }
    }

    /// A server switch: the token is deleted from the old server with the old store's identity
    /// (§9.2, sync-protocol.md §8.4). The next activation registers it with the new one.
    public func serverSwitched(from old: Server) async {
        await serially { await self.performServerSwitched(from: old) }
    }

    /// Retries every due deletion (see ``performRetryOwed()``).
    public func retryOwed() async {
        await serially { await self.performRetryOwed() }
    }

    private func serially(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        inFlight += 1
        let task = Task { @MainActor in
            await previous?.value
            await operation()
            self.inFlight -= 1
        }
        tail = task
        await task.value
    }

    private func performActivated(active: Server?, coldLaunch: Bool) async {
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
            }
            try? await writeState {
                $0.registeredServerId = nil
                $0.registerAttempts = 0
                $0.registerDue = nil
            }
            status = .denied
        } else if authorization.allowsDelivery, let active {
            var state = state
            if let token = state.token, let other = state.registeredServerId, other != active.identity.serverId {
                // Registered with the previous server, which no switch has reported yet.
                try? await owe(serverId: other, token: token, epoch: nil)
                try? await writeState { $0.registeredServerId = nil }
                state.registeredServerId = nil
            }
            let stale =
                state.lastRegisteredAt.map {
                    dependencies.wallClock.now().timeIntervalSince($0) > Self.refreshInterval
                } ?? true
            let wanted = stale || state.registeredServerId != active.identity.serverId || state.token == nil
            // A failed registration waits out its backoff; a cold launch asks regardless.
            let owedNow =
                state.registerAttempts > 0
                ? state.registerDue.map(dependencies.leaseClock.now().hasPassed(deadline:)) ?? true : wanted
            if coldLaunch || owedNow {
                status = .requested
                dependencies.requestToken()
            }
        }
        await performRetryOwed()
    }

    private func performDidRegister(token data: Data, active: Server?) async {
        let token = Self.hex(data)
        let environment: ApnsEnvironment
        switch dependencies.environment() {
        case .success(let value): environment = value
        case .failure(let failure):
            status = .environmentError(failure)
            return
        }
        guard let active else { return }
        await register(token, environment: environment, with: active, recovering: true)
    }

    private func register(_ token: String, environment: ApnsEnvironment, with active: Server, recovering: Bool) async {
        let body = ApnsDeviceInDTO(
            token: token, environment: environment, bundleId: dependencies.bundleId,
            appVersion: dependencies.appVersion, deviceName: dependencies.deviceName)
        let outcome: APIOutcome<ApnsDevice>
        do {
            outcome = try await client(active.baseURL, serverId: active.identity.serverId).registerApnsDevice(
                body, options: RequestOptions(expecting: active.identity)
            ).outcome
        } catch {
            status = .failed(String(describing: error))
            await oweRegistration()
            return
        }
        switch outcome {
        case .success:
            let previous = (try? await readState()) ?? ApnsState()
            if let old = previous.token, let oldServer = previous.registeredServerId,
                old != token || oldServer != active.identity.serverId
            {
                // Rotation, or a registration with the previous server no switch has reported
                // yet: the new one first, then the old one deleted (§9.2).
                let epoch = oldServer == active.identity.serverId ? active.identity.epoch : nil
                try? await owe(serverId: oldServer, token: old, epoch: epoch)
            }
            try? await recordRegistration(token, environment: environment, serverId: active.identity.serverId)
            status = .registered(serverId: active.identity.serverId)
            await performRetryOwed()
        case .epochMismatch:
            // One rebuild per registration; the retry after it doesn't rebuild again.
            if recovering, let recover = recoverActiveEpoch, let rebuilt = await recover(),
                rebuilt.identity.serverId == active.identity.serverId, rebuilt.identity.epoch != active.identity.epoch
            {
                await register(token, environment: environment, with: rebuilt, recovering: false)
                return
            }
            status = .failed("The server's data changed; registering again after the next sync")
            await oweRegistration()
        case .identityMismatch:
            status = .failed("This address now answers as another server")
        case .retryable, .uncertain:
            status = .failed(outcome.problem?.detail ?? "Couldn't register this device for reminders")
            await oweRegistration()
        default:
            status = .failed(outcome.problem?.detail ?? "Couldn't register this device for reminders")
        }
    }

    private func performServerSwitched(from old: Server) async {
        let state = (try? await readState()) ?? ApnsState()
        if let token = state.token, state.registeredServerId == old.identity.serverId {
            try? await owe(serverId: old.identity.serverId, token: token, epoch: old.identity.epoch)
        }
        // A registration owed to the old server isn't owed to the new one.
        try? await writeState {
            if $0.registeredServerId == old.identity.serverId { $0.registeredServerId = nil }
            $0.registerAttempts = 0
            $0.registerDue = nil
        }
        await performRetryOwed()
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
            outcome = try await client(active.baseURL, serverId: active.identity.serverId).sendApnsTestPush(
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
    private func performRetryOwed() async {
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
        try? await client(baseURL, serverId: identity.serverId).deleteApnsDevice(
            ApnsDeviceRefDTO(token: token), options: RequestOptions(expecting: identity)
        ).outcome
    }

    private func client(_ baseURL: URL, serverId: String) async -> APIClient {
        APIClient(
            baseURL: baseURL, transport: dependencies.transport, identity: StaticServerIdentity(nil),
            credentials: dependencies.credentials, origin: .app, serverOffset: await dependencies.serverOffset(serverId)
        )
    }

    // MARK: - Registry

    struct ApnsState: Sendable, Hashable {
        var token: String?
        var environment: ApnsEnvironment?
        var registeredServerId: String?
        var lastRegisteredAt: Date?
        /// Failed registrations since the last success; the next is due at `registerDue`.
        var registerAttempts = 0
        var registerDue: LeaseInstant?
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
            lastRegisteredAt: (row["last_registered_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            registerAttempts: row["register_attempts"],
            registerDue: (row["register_due_boot_id"] as String?).flatMap { boot in
                (row["register_due_ct"] as Int64?).map { LeaseInstant(bootId: boot, ct: $0) }
            })
    }

    /// Changes the state, and runs `also` in the same transaction.
    private func writeState(
        also: @escaping @Sendable (Database) throws -> Void = { _ in },
        _ change: @escaping @Sendable (inout ApnsState) -> Void
    ) async throws {
        try await dependencies.registry.writer.write { db in
            var state = try Self.state(db)
            change(&state)
            try db.execute(
                sql: """
                    INSERT INTO apns_state (id, token, environment, registered_server_id, last_registered_at,
                      register_attempts, register_due_boot_id, register_due_ct)
                    VALUES (1, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET token = excluded.token, environment = excluded.environment,
                      registered_server_id = excluded.registered_server_id,
                      last_registered_at = excluded.last_registered_at,
                      register_attempts = excluded.register_attempts,
                      register_due_boot_id = excluded.register_due_boot_id, register_due_ct = excluded.register_due_ct
                    """,
                arguments: [
                    state.token, state.environment?.rawValue, state.registeredServerId,
                    state.lastRegisteredAt?.timeIntervalSince1970, state.registerAttempts, state.registerDue?.bootId,
                    state.registerDue?.ct,
                ])
            try also(db)
        }
    }

    /// A successful registration: the state, and no deletion of this token still owed to this
    /// server (one left from an earlier switch or denial would delete the registration just made).
    private func recordRegistration(_ token: String, environment: ApnsEnvironment, serverId: String) async throws {
        let now = dependencies.wallClock.now()
        let cancelOwed: @Sendable (Database) throws -> Void = { db in
            try db.execute(
                sql: "DELETE FROM pending_unregister WHERE server_id = ? AND token = ?", arguments: [serverId, token])
        }
        try await writeState(also: cancelOwed) {
            $0.token = token
            $0.environment = environment
            $0.registeredServerId = serverId
            $0.lastRegisteredAt = now
            $0.registerAttempts = 0
            $0.registerDue = nil
        }
    }

    /// A failed registration (§9.2: network error or 5xx): retried at an activation after the
    /// outbox backoff.
    private func oweRegistration() async {
        let now = dependencies.leaseClock.now()
        let random = dependencies.random()
        try? await writeState {
            $0.registerAttempts += 1
            $0.registerDue = now.adding(OutboxBackoff.delay(attempts: $0.registerAttempts, random: random))
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
