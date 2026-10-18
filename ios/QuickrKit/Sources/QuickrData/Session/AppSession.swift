import Foundation
import GRDB
import Observation
import QuickrCore
import Synchronization

/// The app's composition root (DAG M2 "WIRE"): one per app process, on the main actor. It opens
/// the store partitions, runs the coordinator and its listeners, and keeps the active store's
/// outbox, flush scheduler and sender bound to the coordinator's flush bridge, rebinding whenever
/// the active (server, generation, base URL) changes: on connect, after a reset, on
/// `registry-changed` and when the app becomes active.
///
/// Screens read the active store through `store` (observe with `refresh.stream()`, keyed by
/// `binding`), and write through the façade (`log`, `update`, `delete`, `undo…`), which enqueues
/// through `Outbox` and requests a flush. Nothing else should build an `Outbox` in the app.
@MainActor @Observable
public final class AppSession {
    public struct Configuration: Sendable {
        public var location: StoreLocation
        /// How requests leave the device (`URLSessionTransport` in the app).
        public var transport: any Transport
        /// Cloudflare Access headers for the active server (SETTINGS: the Keychain).
        public var credentials: any AccessCredentialsProvider
        /// Cross-process signals (`DarwinNotifier` in the app).
        public var notifier: (any ChangeNotifier)?
        public var leaseClock: any LeaseClock
        public var wallClock: any WallClock
        public var launchId: UUID
        public var coordinator: SyncCoordinator.Configuration
        /// Posts the GRDB suspension notifications (`NotificationCenter.default` in the app).
        public var notificationCenter: NotificationCenter

        public init(
            location: StoreLocation, transport: any Transport,
            credentials: any AccessCredentialsProvider = StaticAccessCredentials(nil),
            notifier: (any ChangeNotifier)? = DarwinNotifier(), leaseClock: any LeaseClock = SystemLeaseClock(),
            wallClock: any WallClock = SystemWallClock(), launchId: UUID = UUID(),
            coordinator: SyncCoordinator.Configuration = .init(), notificationCenter: NotificationCenter = .default
        ) {
            self.location = location
            self.transport = transport
            self.credentials = credentials
            self.notifier = notifier
            self.leaseClock = leaseClock
            self.wallClock = wallClock
            self.launchId = launchId
            self.coordinator = coordinator
            self.notificationCenter = notificationCenter
        }
    }

    public enum Phase: Sendable, Hashable {
        case starting
        /// No server is configured yet (onboarding).
        case noServer
        case ready
        case failed(String)
    }

    /// What the outbox is bound to right now.
    public struct Binding: Sendable, Hashable {
        public var serverId: String
        public var storeGen: Int
        public var baseURL: URL
    }

    public enum SessionError: Error, Sendable, Hashable {
        /// A write before any store is bound (no server yet).
        case noStore
    }

    public let configuration: Configuration
    public let partitions: StorePartitions
    public let coordinator: SyncCoordinator
    /// Re-fetch trigger for the screens' observations: other processes' commits, and activation.
    public let refresh: RefreshSignal
    /// Reads the active store's topics (App Intents, widgets, screens before a store is bound).
    public let topics: ActiveStoreTopicRepository

    public private(set) var phase: Phase = .starting
    public private(set) var binding: Binding?
    public private(set) var store: LocalStore?
    public private(set) var outbox: Outbox?
    public private(set) var scheduler: OutboxFlushScheduler?
    public private(set) var syncStatus: SyncStatus

    @ObservationIgnored private let bridge: OutboxFlushBridge
    @ObservationIgnored private let owner: String
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var rebinding: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        partitions = try StorePartitions.open(
            at: configuration.location, leaseClock: configuration.leaseClock, wallClock: configuration.wallClock,
            notifier: configuration.notifier)
        owner = LeaseClaim.owner(kind: "app", launchId: configuration.launchId)
        let bridge = OutboxFlushBridge()
        self.bridge = bridge
        let events = SessionEvents()
        let transport = configuration.transport
        let credentials = configuration.credentials
        coordinator = SyncCoordinator(
            partitions: partitions,
            feed: { url in
                APIClient(
                    baseURL: url, transport: transport, identity: StaticServerIdentity(nil), credentials: credentials)
            },
            flush: bridge, events: events, owner: owner, configuration: configuration.coordinator)
        refresh = RefreshSignal(notifier: configuration.notifier)
        topics = ActiveStoreTopicRepository(partitions: partitions)
        syncStatus = coordinator.status
        events.session = self
    }

    // MARK: - Lifecycle

    /// Launch, from the root view's task: resumes an interrupted reset and finishes a bootstrap
    /// (`bootstrapIfNeeded`), or connects to `serverURL` when no server is active yet, then binds
    /// the outbox and starts listening. Idempotent.
    public func start(serverURL: URL? = nil) async {
        guard !started else { return }
        started = true
        startListening()
        _ = await coordinator.bootstrapIfNeeded()
        let active = try? await partitions.registry.repository.activeServerId()
        if active == nil, let serverURL {
            _ = await connect(baseURL: serverURL)
            return
        }
        await rebind()
    }

    /// Onboarding or Settings: connect to `baseURL` (a new server, or a known one at a new
    /// address) and rebind, rebuilding the sender for the URL now in use.
    @discardableResult
    public func connect(baseURL: URL) async -> SyncCoordinator.ConnectResult {
        let result = await coordinator.connect(baseURL: baseURL)
        await rebind(force: true)
        return result
    }

    /// `scenePhase` → `.active`: resume GRDB, pick up a store another process reset or switched,
    /// refresh the screens, flush and pull.
    public func didBecomeActive() async {
        configuration.notificationCenter.post(name: Database.resumeNotification, object: nil)
        await rebind()
        refresh.poke()
        await scheduler?.requestFlush(reason: .activation)
        Task { _ = await coordinator.sync(reason: .activation) }
    }

    /// `scenePhase` → `.background`, inside the app's background task: release held deletes and
    /// flush (outbox.md §10), then suspend GRDB so no lock is held while suspended (0xDEAD10CC).
    @discardableResult
    public func didEnterBackground() async -> OutboxFlushReport? {
        let report = await scheduler?.flushNow(reason: .background)
        configuration.notificationCenter.post(name: Database.suspendNotification, object: nil)
        return report
    }

    /// The background task's expiration handler: cancel the flush (its item becomes uncertain and
    /// the lease is released) and suspend GRDB. Returns at once.
    public func backgroundTimeExpiring() {
        let scheduler = scheduler
        Task { await scheduler?.cancel() }
        configuration.notificationCenter.post(name: Database.suspendNotification, object: nil)
    }

    /// Stops listening and unbinds (retiring the scheduler). For tests and teardown.
    public func shutdown() async {
        for listener in listeners { listener.cancel() }
        listeners = []
        await rebinding?.value
        await bridge.bind(nil)
        store = nil
        outbox = nil
        scheduler = nil
        binding = nil
    }

    // MARK: - Writes (TILES, RECORD, the entry screens)

    /// Logs an entry and asks for a flush. Returns the new entry's id (also its outbox item id).
    @discardableResult
    public func log(
        topic: TopicRef, answers: [String: AnswerValue], capturedAt: Date? = nil, notes: String? = nil,
        version: Int, origin: OutboxOrigin = .app
    ) async throws -> UUID {
        let outbox = try requireOutbox()
        let id = UUID()
        let body = EntryCreateDTO(
            id: nil, answers: answers, source: nil, capturedAt: capturedAt ?? configuration.wallClock.now(),
            notes: notes, version: version)
        try await outbox.createEntry(id: id, topic: topic, body: body, origin: origin)
        await scheduler?.requestFlush(reason: .enqueue)
        return id
    }

    /// Edits an entry (`baseRevision`: the server revision under the view the user edited).
    public func update(entryId: UUID, topicId: UUID, patch: EntryUpdateDTO, baseRevision: Int? = nil) async throws {
        try await requireOutbox().updateEntry(
            id: entryId, topicId: topicId, patch: patch, baseRevision: baseRevision, origin: .app)
        await scheduler?.requestFlush(reason: .enqueue)
    }

    /// Deletes an entry; `undoable` holds it for the undo window (6 s) before it can be sent.
    public func delete(entryId: UUID, topicId: UUID, undoable: Bool = true) async throws {
        try await requireOutbox().deleteEntry(id: entryId, topicId: topicId, undoable: undoable, origin: .app)
        await scheduler?.requestFlush(reason: .enqueue)
    }

    /// Undo of a held delete.
    @discardableResult
    public func undoDelete(entryId: UUID) async throws -> OutboxUndoDeleteResult {
        try await requireOutbox().undoDelete(entryId: entryId)
    }

    /// Undo of a log (`cancelCreate`): removes it, or queues a DELETE if it may have been sent.
    @discardableResult
    public func undoLog(entryId: UUID) async throws -> OutboxUndoLogResult {
        let result = try await requireOutbox().undoLog(entryId: entryId, origin: .app)
        await scheduler?.requestFlush(reason: .enqueue)
        return result
    }

    private func requireOutbox() throws -> Outbox {
        guard let outbox else { throw SessionError.noStore }
        return outbox
    }

    // MARK: - Binding

    /// Rebinds to the active store if (server, generation, base URL) changed, or always with
    /// `force`. Calls run one after another.
    public func rebind(force: Bool = false) async {
        let previous = rebinding
        let task = Task { @MainActor in
            await previous?.value
            await self.performRebind(force: force)
        }
        rebinding = task
        await task.value
    }

    private func performRebind(force: Bool) async {
        do {
            guard let store = try await partitions.openActiveStore(role: .app)?.store else {
                await unbind(phase: .noServer)
                return
            }
            let state = try await store.syncState.syncState()
            guard let state, let baseURL = URL(string: state.baseURL) else {
                await unbind(phase: .failed("the active store has no server URL"))
                return
            }
            let next = Binding(serverId: store.serverId, storeGen: store.storeGen, baseURL: baseURL)
            if !force, next == binding, self.store != nil {
                phase = .ready
                return
            }
            let sender = APIClient(
                baseURL: baseURL, transport: configuration.transport, identity: StaticServerIdentity(nil),
                credentials: configuration.credentials, origin: .app)
            let outbox = Outbox(
                store: store, sender: sender, owner: owner, onSignal: coordinator.outboxSignalHandler)
            let scheduler = OutboxFlushScheduler(outbox: outbox)
            await bridge.bind(scheduler)
            self.store = store
            self.outbox = outbox
            self.scheduler = scheduler
            binding = next
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func unbind(phase: Phase) async {
        await bridge.bind(nil)
        store = nil
        outbox = nil
        scheduler = nil
        binding = nil
        self.phase = phase
    }

    private func startListening() {
        var listeners: [Task<Void, Never>] = []
        if let notifier = configuration.notifier {
            listeners.append(coordinator.listen(to: notifier))
            let signals = notifier.signals(.registryChanged)
            listeners.append(
                Task { [weak self] in
                    for await _ in signals {
                        guard let self else { return }
                        await self.rebind()
                    }
                })
        }
        let updates = coordinator.statusUpdates()
        listeners.append(
            Task { [weak self] in
                for await status in updates {
                    guard let self else { return }
                    self.syncStatus = status
                }
            })
        self.listeners = listeners
    }

    /// The coordinator's events that change what the session is bound to.
    fileprivate func handle(_ event: SyncEvent) {
        switch event {
        case .storeReset, .bootstrapped:
            Task { await rebind() }
        case .layerSwapped, .layerChanged, .topicsDeleted:
            refresh.poke()
        }
    }
}

/// Forwards the coordinator's events to the session on the main actor, holding it weakly.
private final class SessionEvents: SyncEventSink, @unchecked Sendable {
    @MainActor weak var session: AppSession?

    func handle(_ event: SyncEvent) {
        Task { @MainActor [weak self] in self?.session?.handle(event) }
    }
}

/// The topics of whichever store is active, read through the partitions' shared pool: what App
/// Intents and the widget read (the widget's partitions are its own process's).
public struct ActiveStoreTopicRepository: TopicRepository {
    public let partitions: StorePartitions

    public init(partitions: StorePartitions) { self.partitions = partitions }

    private func repository() async throws -> GRDBTopicRepository? {
        try await partitions.openActiveStore(role: .extension)?.store.topics
    }

    public func topics() async throws -> [ViewTopic] { try await repository()?.topics() ?? [] }

    public func topic(id: UUID) async throws -> ViewTopic? { try await repository()?.topic(id: id) }

    public func topic(slug: String) async throws -> ViewTopic? { try await repository()?.topic(slug: slug) }
}
