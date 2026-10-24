import Foundation
import Observation
import QuickrCore

/// The home screen's state (the PWA's `TopicsPage`), over the active store: every topic from
/// `observeTopics`, listed on the device like the server's `GET /topics` (`TopicListing`), with
/// the PWA's search debounce, status filter, sort, sections and due badge.
///
/// Drive it from the view: `observe()` in a `.task(id: session.binding)`, so it restarts on a
/// server switch or a reset; `tick(_:)` every 30 s and on activation (the PWA's `useNow`).
@MainActor @Observable
public final class HomeModel {
    /// What the screen shows instead of (or above) the list.
    public enum Phase: Equatable, Sendable {
        /// No topics read yet.
        case loading
        /// Nothing stored and the first sync can't reach the server ("You're offline").
        case offline
        /// No server yet: onboarding.
        case noServer
        /// The session or the store failed.
        case failed(String)
        case ready
    }

    public typealias Row = TopicListing.Item<ViewTopic>

    /// The search field's text. The list follows it 250 ms after the last change, trimmed.
    public var search = "" {
        didSet { scheduleQuery() }
    }
    /// The search the list shows (`search`, trimmed and debounced).
    public private(set) var query = ""
    public var status: TopicStatusFilter = .active {
        didSet { if status != oldValue { relist() } }
    }
    public var sort: TopicSort = .due {
        didSet { if sort != oldValue { relist() } }
    }
    /// The device clock: one instant for the whole list ("… ago" text). Due state uses `serverNow`.
    public private(set) var now: Date
    /// The bound store's server clock (sync-protocol.md §10), from its sync state.
    public private(set) var clock = ServerClock.device
    /// `now` on the server's clock: what the due states, order, sections and badge use.
    public var serverNow: Date { clock.now(at: now) }

    /// Every topic in the store (the list's input).
    public private(set) var topics: [ViewTopic] = []
    /// The filtered, searched and sorted list.
    public private(set) var rows: [Row] = []
    /// `rows` in sections, when `isSectioned`.
    public private(set) var sections = TopicListing.Sections<Row>()
    /// Active topics due now, whatever the search or filter: the app badge.
    public private(set) var badgeCount = 0
    /// Topics read from the store at least once since the last bind.
    public private(set) var loaded = false
    /// The latest observation failure, cleared by a successful read.
    public private(set) var loadError: String?
    /// The bound store finished its first bootstrap (`sync_state.bootstrap_complete`).
    public private(set) var bootstrapped = false

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    /// Tests: replaces the store's sync-state observation, to hold it back while the topics load.
    @_spi(Testing) @ObservationIgnored public var syncStatesForTesting:
        (@MainActor (LocalStore) -> AsyncThrowingStream<SyncState?, any Error>)?

    public init(session: AppSession, now: Date = Date(), debounce: Duration = .milliseconds(250)) {
        self.session = session
        self.now = now
        self.debounce = debounce
    }

    // MARK: - Derived

    /// A search or a non-default status: the empty state reads "No matches", not "Track anything".
    public var isFiltered: Bool { !query.isEmpty || status != .active }
    /// The default view (due first, active, no search) shows sections; anything else, one list.
    public var isSectioned: Bool { TopicListing.isSectioned(status: status, sort: sort, query: query) }
    /// The filter panel's button is highlighted when anything is not the default.
    public var hasNonDefaultFilter: Bool { status != .active || sort != .due }

    public var phase: Phase {
        switch session.phase {
        case .starting: return .loading
        case .noServer: return .noServer
        case .failed(let message): return .failed(message)
        case .ready:
            // Nothing stored and the first sync can't reach the server: "You're offline", even
            // once the (empty) store has been read.
            if isOfflineWithoutData { return .offline }
            if loaded { return .ready }
            if let loadError { return .failed(loadError) }
            return .loading
        }
    }

    /// "You're offline": nothing stored, the store never finished a bootstrap, and the sync can't
    /// reach the server. (An empty store that did bootstrap reads "Track anything", offline or not.)
    public var isOfflineWithoutData: Bool {
        guard topics.isEmpty, !bootstrapped else { return false }
        if case .unreachable = session.syncStatus.lastFailure { return true }
        return false
    }

    // MARK: - Inputs

    /// Moves the clock (every 30 s, and on activation).
    public func tick(_ now: Date = Date()) {
        self.now = now
        relist()
    }

    /// Reads the active store's topics and sync state until cancelled (the sync pill is SYNC-UX's). Run it keyed by
    /// `session.binding`: a new store starts over from nothing (loading, then its topics), and an
    /// earlier observation's late values are dropped.
    public func observe() async {
        generation += 1
        let generation = generation
        topics = []
        bootstrapped = false
        clock = .device
        loaded = false
        loadError = nil
        relist()
        guard let store = session.store else { return }
        // The store's clock before its first list, so it never shows on the device clock; the
        // sync state's observation follows it from then on.
        let clock = (try? await store.syncState.syncState())?.serverClock ?? .device
        guard isCurrent(generation) else { return }
        self.clock = clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeTopics(store, generation) }
            group.addTask { await self.observeSyncState(store, generation) }
        }
    }

    /// The latest `observe()`; only its values are published.
    @ObservationIgnored private var generation = 0

    private func isCurrent(_ observation: Int) -> Bool { observation == generation && !Task.isCancelled }

    private func observeTopics(_ store: LocalStore, _ observation: Int) async {
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                guard isCurrent(observation) else { return }
                self.topics = topics
                loaded = true
                loadError = nil
                relist()
            }
        } catch is CancellationError {
        } catch {
            if isCurrent(observation) { loadError = String(describing: error) }
        }
    }

    private func observeSyncState(_ store: LocalStore, _ observation: Int) async {
        do {
            let states = syncStatesForTesting?(store) ?? store.observeSyncState(refresh: session.refresh.stream())
            for try await state in states {
                guard isCurrent(observation) else { return }
                bootstrapped = state?.bootstrapComplete ?? false
                let clock = state?.serverClock ?? .device
                if clock != self.clock {
                    self.clock = clock
                    relist()
                }
            }
        } catch {
            // As above: the topics' observation reports store failures.
        }
    }

    /// Bumped by `retry()`: key the observing task by it too, so a retry restarts `observe()`.
    public private(set) var attempt = 0

    /// "Retry": rebinds a failed session, or reads the store again.
    public func retry() async {
        loadError = nil
        if case .failed = session.phase {
            await session.rebind(force: true)
        }
        attempt += 1
    }

    private func scheduleQuery() {
        queryTask?.cancel()
        let next = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard debounce > .zero else {
            applyQuery(next)
            return
        }
        queryTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.applyQuery(next)
        }
    }

    private func applyQuery(_ next: String) {
        guard next != query else { return }
        query = next
        relist()
    }

    private func relist() {
        let now = serverNow
        rows = TopicListing.list(
            topics, topic: \.topic, now: now, status: status, sort: sort, query: query)
        sections = TopicListing.sections(rows, now: now, openRuns: TopicListing.noOpenRuns)
        badgeCount = TopicListing.dueCount(topics.map(\.topic), now: now, openRuns: TopicListing.noOpenRuns)
    }
}
