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
    /// Tests: runs before a new scheduler is bound, to hold a rebind mid-swap.
    @_spi(Testing) @ObservationIgnored public var beforeBindForTesting: (@MainActor () async -> Void)?
    /// The current scene episode. Every activation and every background starts a new generation;
    /// background work holds its `BackgroundEpisode` and acts only while it is current. The pause
    /// state of the scheduler and the coordinator is ordered by generation too, so a stale
    /// episode's pause never lands after a newer resume, and nothing stale ever resumes.
    @ObservationIgnored private var lifecycle: Lifecycle = .foreground
    @ObservationIgnored private var lifecycleGeneration = 0

    private enum Lifecycle: Equatable {
        case foreground
        case background(Int)
    }

    /// One trip to the background, from `beginBackground()` to the next activation.
    public struct BackgroundEpisode: Sendable, Hashable {
        fileprivate let generation: Int
    }

    /// Between `beginBackground()` and the next `didBecomeActive`.
    public var isBackgrounded: Bool { lifecycle != .foreground }

    private func isCurrent(_ episode: BackgroundEpisode) -> Bool { lifecycle == .background(episode.generation) }

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
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lifecycle = .foreground
        configuration.notificationCenter.post(name: Database.resumeNotification, object: nil)
        await coordinator.resume(generation: generation)
        guard started else { return }  // the launch's `start()` does the rest
        await scheduler?.resume(generation: generation)
        await rebind()
        refresh.poke()
        await scheduler?.requestFlush(reason: .activation)
        Task { _ = await coordinator.sync(reason: .activation) }
    }

    /// `scenePhase` → `.background`: starts a background episode. Take it before registering the
    /// background task's expiration handler, and pass it to `didEnterBackground(_:)` and
    /// `backgroundTimeExpiring(_:within:)`, so an old task's callbacks never act on a newer episode.
    public func beginBackground() -> BackgroundEpisode {
        lifecycleGeneration += 1
        lifecycle = .background(lifecycleGeneration)
        return BackgroundEpisode(generation: lifecycleGeneration)
    }

    /// Inside the episode's background task: no new pull starts; release held deletes and flush
    /// (outbox.md §10); then no new flush starts either, the pull in flight ends, and GRDB is
    /// suspended, so no write transaction or lease is open while the process is suspended
    /// (0xDEAD10CC). If the episode stops being current (the app became active, or went to the
    /// background again), it stops, and leaves the pause state to the current episode.
    @discardableResult
    public func didEnterBackground(_ episode: BackgroundEpisode? = nil) async -> OutboxFlushReport? {
        let episode = episode ?? beginBackground()
        guard isCurrent(episode) else { return nil }
        await coordinator.pause(generation: episode.generation)
        let report = await scheduler?.flushNow(reason: .background)
        guard isCurrent(episode) else { return report }
        await scheduler?.pause(generation: episode.generation)
        await coordinator.waitUntilIdle()
        suspendIfCurrent(episode)
        return report
    }

    /// A `BGAppRefreshTask` (sync-protocol.md §9, outbox.md §10): its own background episode
    /// (take it with `beginBackground()` before registering the task's expiration handler, which
    /// calls `backgroundTimeExpiring(_:within:)`). Resumes GRDB and the episode, pulls, then sends
    /// the queue (a forced flush), then stops and suspends GRDB as `didEnterBackground` does. Nil,
    /// and nothing done, when the session hasn't started (`start()` first) or the episode is no
    /// longer current (the app came to the foreground meanwhile).
    @discardableResult
    public func backgroundRefresh(_ episode: BackgroundEpisode) async -> SyncResult? {
        guard started, isCurrent(episode) else { return nil }
        configuration.notificationCenter.post(name: Database.resumeNotification, object: nil)
        await coordinator.resume(generation: episode.generation)
        await scheduler?.resume(generation: episode.generation)
        let result = await coordinator.sync(reason: .background)
        guard isCurrent(episode) else { return result }
        _ = await scheduler?.flushNow(reason: .backgroundRefresh)
        guard isCurrent(episode) else { return result }
        await coordinator.pause(generation: episode.generation)
        await scheduler?.pause(generation: episode.generation)
        await coordinator.waitUntilIdle()
        suspendIfCurrent(episode)
        return result
    }

    /// The episode's background task is expiring: cancel the flush (its item becomes uncertain and
    /// the lease is released) and refuse new flushes and pulls, wait for them to end, but no
    /// longer than `remaining` (what the system still grants), then suspend GRDB. End the
    /// background task after it returns. For an episode that is no longer current it does nothing,
    /// so it never cancels a newer episode's work.
    public func backgroundTimeExpiring(_ episode: BackgroundEpisode, within remaining: Duration = .seconds(3)) async {
        guard isCurrent(episode) else { return }
        let scheduler = scheduler
        let coordinator = coordinator
        await coordinator.pause(generation: episode.generation)
        await scheduler?.pause(generation: episode.generation)  // cancels the flush
        await Self.firstOf(remaining) {
            _ = await scheduler?.waitUntilIdle()
            await coordinator.waitUntilIdle()
        }
        suspendIfCurrent(episode)
    }

    /// Posts GRDB's suspend if `episode` is still current. Nothing can start a flush or a pull in
    /// between: both are paused for this generation, and only a newer activation resumes them.
    private func suspendIfCurrent(_ episode: BackgroundEpisode) {
        guard isCurrent(episode) else { return }
        configuration.notificationCenter.post(name: Database.suspendNotification, object: nil)
    }

    /// Runs `work` and returns when it ends or after `timeout`, whichever is first (the work keeps
    /// running if the timeout wins).
    private static func firstOf(_ timeout: Duration, _ work: @escaping @Sendable () async -> Void) async {
        let done = Mutex(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable () -> Void = {
                let first = done.withLock { finished in
                    defer { finished = true }
                    return !finished
                }
                if first { continuation.resume() }
            }
            Task {
                await work()
                finish()
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
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
    //
    // Each write returns once its outbox item is durably committed (so an undo toast can follow
    // at once), then asks for a flush. Errors: `SessionError.noStore` before onboarding;
    // `OutboxError` from the enqueue rules, notably `.entryDeleted` (C0: the entry was deleted
    // here or on the server; show "This entry was deleted"); `StoreError.retired` if the store was
    // reset meanwhile (retry after `binding` changes).

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
            // Paused until it is published and matched to the scene below, so it starts nothing
            // while the bind waits.
            await scheduler.pause(generation: lifecycleGeneration)
            await beforeBindForTesting?()
            await bridge.bind(scheduler)
            self.store = store
            self.outbox = outbox
            self.scheduler = scheduler
            binding = next
            phase = .ready
            // The scene may have changed while the bind waited (an activation resumed the old
            // scheduler), so match the current episode now. Later scene calls reach this scheduler,
            // and generations order them against this one.
            switch lifecycle {
            case .foreground: await scheduler.resume(generation: lifecycleGeneration)
            case .background(let generation): await scheduler.pause(generation: generation)
            }
            // A request the coordinator made during the swap was dropped; kept items go out now.
            await scheduler.requestFlush(reason: .afterPull)
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
        case .storeReset:
            Task { await rebind() }
        case .bootstrapped:
            break  // only connect and start bootstrap a store, and both rebind themselves
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

/// The topics of whichever store is active. In the app it reads through the session's partitions
/// (their shared pool, never creating a file); in the widget through `ReadOnlyStores` (read-only
/// opens). No store yet reads as no topics.
public struct ActiveStoreTopicRepository: TopicRepository {
    private let open: @Sendable () async throws -> LocalStore?

    /// The app's: the partitions it already writes through.
    public init(partitions: StorePartitions) {
        open = { try await partitions.openActiveStoreIfExists() }
    }

    /// An extension's that only reads.
    public init(readOnly stores: ReadOnlyStores) {
        open = { try stores.activeStore() }
    }

    private func repository() async throws -> GRDBTopicRepository? { try await open()?.topics }

    public func topics() async throws -> [ViewTopic] { try await repository()?.topics() ?? [] }

    public func topic(id: UUID) async throws -> ViewTopic? { try await repository()?.topic(id: id) }

    public func topic(slug: String) async throws -> ViewTopic? { try await repository()?.topic(slug: slug) }
}
