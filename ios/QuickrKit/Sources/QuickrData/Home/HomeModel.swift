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
    /// The clock the due states and labels use: one instant for the whole list.
    public private(set) var now: Date

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
    /// Outbox counts for the sync pill.
    public private(set) var pendingCount = 0
    public private(set) var failedCount = 0

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var queryTask: Task<Void, Never>?

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
            if loaded { return .ready }
            if let loadError { return .failed(loadError) }
            return .loading
        }
    }

    /// "You're offline": nothing to show and the first sync can't reach the server.
    public var isOfflineWithoutData: Bool {
        guard topics.isEmpty, !session.syncStatus.bootstrapComplete else { return false }
        if case .unreachable = session.syncStatus.lastFailure { return true }
        return false
    }

    /// The sync pill's connection state (a placeholder until SYNC-UX): offline while the last
    /// sync couldn't reach the server.
    public var isOnline: Bool {
        if case .unreachable = session.syncStatus.lastFailure { return false }
        return true
    }

    // MARK: - Inputs

    /// Moves the clock (every 30 s, and on activation).
    public func tick(_ now: Date = Date()) {
        self.now = now
        relist()
    }

    /// Reads the active store's topics and outbox until cancelled. Run it keyed by
    /// `session.binding`: a new store starts over (loading, then its topics).
    public func observe() async {
        loaded = false
        loadError = nil
        guard let store = session.store else {
            topics = []
            relist()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeTopics(store) }
            group.addTask { await self.observeOutbox(store) }
        }
    }

    private func observeTopics(_ store: LocalStore) async {
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                self.topics = topics
                loaded = true
                loadError = nil
                relist()
            }
        } catch is CancellationError {
        } catch {
            loadError = String(describing: error)
        }
    }

    private func observeOutbox(_ store: LocalStore) async {
        do {
            for try await items in store.observeOutbox(refresh: session.refresh.stream()) {
                failedCount = items.count { $0.state == .failed }
                pendingCount = items.count { $0.state != .failed && $0.state != .held }
            }
        } catch {
            // The pill is a placeholder; the topics' observation reports store failures.
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
        rows = TopicListing.list(
            topics, topic: \.topic, now: now, status: status, sort: sort, query: query)
        sections = TopicListing.sections(rows, now: now)
        badgeCount = TopicListing.badgeCount(topics.map(\.topic), now: now)
    }
}
