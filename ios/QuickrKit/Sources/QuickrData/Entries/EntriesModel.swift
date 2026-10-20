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
    /// The store the topic and rows come from (taken with it when `observe()` starts). Writes on
    /// a row go to this store: after a rebind, a row still on screen belongs to the old one.
    public private(set) var binding: AppSession.Binding?
    /// The topic list has been read: `topic` nil now means it isn't in this store (yet).
    public private(set) var topicResolved = false
    /// The entries have been read.
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
            guard topicResolved else { return .loading }
            guard topic != nil else { return .missing }
            return loaded ? .ready : .loading
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
    /// and drops a superseded observation's late values. A topic that isn't there yet (a link
    /// opened before the first sync) is waited for: the list appears when it arrives.
    public func observe() async {
        generation += 1
        let generation = generation
        topic = nil
        entries = []
        versions = []
        topicResolved = false
        loaded = false
        loadError = nil
        binding = session.binding
        relist()
        guard let store = session.store else { return }
        await withTaskGroup(of: Void.self) { group in
            var watching: UUID?
            do {
                for try await topics in store.observeTopics(refresh: session.refresh.stream()) {
                    guard isCurrent(generation) else { break }
                    // By id once found: a slug can change.
                    let found = topics.first { topic in watching.map { topic.topic.id == $0 } ?? self.matches(topic) }
                    // A new version brings new questions: read the versions (before the entries
                    // arrive the first time, so the first list has every column).
                    if let found, found.topic.currentVersion != topic?.topic.currentVersion || versions.isEmpty {
                        let versions = try await store.versions.versions(topicId: found.topic.id)
                        guard isCurrent(generation) else { break }
                        self.versions = versions
                    }
                    topic = found
                    topicResolved = true
                    if let found, watching == nil {
                        watching = found.topic.id
                        group.addTask { await self.observeEntries(store, found.topic.id, generation) }
                    }
                    relist()
                }
            } catch {
                if isCurrent(generation), !(error is CancellationError) { loadError = String(describing: error) }
            }
            group.cancelAll()
        }
    }

    private func isCurrent(_ observation: Int) -> Bool { observation == generation && !Task.isCancelled }

    /// `topicRef` names this topic: its id, or its slug.
    private func matches(_ topic: ViewTopic) -> Bool {
        if let id = UUID(uuidString: topicRef) { return topic.topic.id == id }
        return topic.topic.slug == topicRef
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
