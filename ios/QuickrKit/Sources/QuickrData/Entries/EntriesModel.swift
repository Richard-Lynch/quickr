import Foundation
import Observation
import QuickrCore

/// A topic's entries screen (the PWA's `EntriesPage`), over the active store: the entries the
/// server has, filtered and ordered like `GET /topics/{ref}/entries` (`EntryListing`), and above
/// them, pinned in outbox order and never filtered, the ones only this device has so far
/// (queued or failed creates).
///
/// Drive it from the view: `observe()` in a `.task(id:)` keyed by `session.binding` and
/// `attempt`, so a server switch or reset starts over; `tick(_:)` on activation, for the range.
@MainActor @Observable
public final class EntriesModel {
    public enum Phase: Equatable, Sendable {
        case loading
        /// No server yet.
        case noServer
        /// The topic isn't in this store (deleted, or a link to another server's topic).
        case missing
        case failed(String)
        case ready
    }

    /// The topic, by slug or id (a link's `TopicLinkRef`).
    public let topicRef: String
    public var filters = EntryListFilters() {
        didSet { if filters != oldValue { relist() } }
    }
    /// The clock the range starts from.
    public private(set) var now: Date

    public private(set) var topic: ViewTopic?
    /// Every entry the store shows for the topic (the list's input).
    public private(set) var entries: [ViewEntry] = []
    public private(set) var versions: [TopicVersion] = []
    /// Only on this device so far, oldest first: pinned above the list, whatever the filters.
    public private(set) var pinned: [ViewEntry] = []
    /// The server's entries (edited ones included), filtered and in the server's order.
    public private(set) var rows: [ViewEntry] = []
    /// The source filter's choices, from every entry the server has (unfiltered).
    public private(set) var sources: [(value: String, count: Int)] = []
    /// The answer columns: current questions, then keys only older versions have.
    public private(set) var columns: [Question] = []
    public private(set) var loaded = false
    public private(set) var loadError: String?
    /// Bumped by `retry()`: key the observing task by it too.
    public private(set) var attempt = 0

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var generation = 0

    public init(session: AppSession, topicRef: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.session = session
        self.topicRef = topicRef
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Derived

    public var phase: Phase {
        switch session.phase {
        case .starting: return .loading
        case .noServer: return .noServer
        case .failed(let message): return .failed(message)
        case .ready:
            if let loadError { return .failed(loadError) }
            guard loaded else { return .loading }
            return topic == nil ? .missing : .ready
        }
    }

    /// The version filter shows only when the topic has had more than one version: newest first.
    public var versionChoices: [Int] {
        let current = topic?.topic.currentVersion ?? 1
        return current > 1 ? Array((1...current).reversed()) : []
    }

    /// The source filter shows when there's a choice to make, or one is selected.
    public var showsSourceFilter: Bool { sources.count > 1 || filters.source != nil }

    /// "No entries yet" (nothing logged at all) rather than "No entries match".
    public var hasNoEntriesAtAll: Bool { entries.isEmpty }

    // MARK: - Inputs

    public func tick(_ now: Date = Date()) {
        self.now = now
        relist()
    }

    public func retry() async {
        loadError = nil
        if case .failed = session.phase { await session.rebind(force: true) }
        attempt += 1
    }

    /// Reads the topic, its versions and its entries until cancelled; starts over from nothing,
    /// and drops a superseded observation's late values.
    public func observe() async {
        generation += 1
        let generation = generation
        topic = nil
        entries = []
        versions = []
        loaded = false
        loadError = nil
        relist()
        guard let store = session.store else { return }
        do {
            let topic = try await Self.find(topicRef, in: store)
            guard isCurrent(generation) else { return }
            guard let topic else {
                loaded = true
                return
            }
            let topicId = topic.topic.id
            // Before the entries arrive, so the first list has every column.
            let versions = try await store.versions.versions(topicId: topicId)
            guard isCurrent(generation) else { return }
            self.topic = topic
            self.versions = versions
            relist()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.observeTopic(store, topicId, generation) }
                group.addTask { await self.observeEntries(store, topicId, generation) }
            }
        } catch is CancellationError {
        } catch {
            if isCurrent(generation) { loadError = String(describing: error) }
        }
    }

    private func isCurrent(_ observation: Int) -> Bool { observation == generation && !Task.isCancelled }

    static func find(_ ref: String, in store: LocalStore) async throws -> ViewTopic? {
        if let id = UUID(uuidString: ref) { return try await store.topics.topic(id: id) }
        return try await store.topics.topic(slug: ref)
    }

    private func observeTopic(_ store: LocalStore, _ topicId: UUID, _ observation: Int) async {
        do {
            for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                guard isCurrent(observation) else { return }
                let topic = topics.first { $0.topic.id == topicId }
                // A new version brings new questions: read the versions again.
                if topic?.topic.currentVersion != self.topic?.topic.currentVersion || versions.isEmpty {
                    let versions = try await store.versions.versions(topicId: topicId)
                    guard isCurrent(observation) else { return }
                    self.versions = versions
                }
                self.topic = topic
                relist()
            }
        } catch {
            if isCurrent(observation), !(error is CancellationError) { loadError = String(describing: error) }
        }
    }

    private func observeEntries(_ store: LocalStore, _ topicId: UUID, _ observation: Int) async {
        do {
            for try await entries in store.observeEntries(topicId: topicId, refresh: session.refresh.stream()) {
                guard isCurrent(observation) else { return }
                self.entries = entries
                loaded = true
                loadError = nil
                relist()
            }
        } catch {
            if isCurrent(observation), !(error is CancellationError) { loadError = String(describing: error) }
        }
    }

    private func relist() {
        let server = entries.filter { !$0.isLocalOnly }
        pinned = entries.filter(\.isLocalOnly).sorted { ($0.createSeq ?? 0) < ($1.createSeq ?? 0) }
        rows = EntryListing.list(
            server, entry: \.entry, capturedFrom: filters.range.start(now: now, calendar: calendar),
            version: filters.version, source: filters.source)
        sources = EntryListing.sources(server.map(\.entry))
        columns = EntryListing.columns(current: topic?.topic.questions ?? [], versions: versions)
    }
}
