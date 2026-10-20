import Foundation
import Observation
import QuickrCore

/// A topic's Overview (the PWA's `OverviewPage`): the stats for the filters, each chartable
/// question's series in the chosen bucket, and the topic's sources for the filter bar. Cached
/// answers show at once; fresh ones replace them. Offline, or when a fetch fails, the cached
/// answer stays, stale, with when it was fetched.
@MainActor @Observable
public final class OverviewModel {
    /// How current a shown answer is.
    public enum Freshness: Sendable, Hashable {
        /// Fetched just now.
        case fresh(Date)
        /// From the cache, while a fetch is in flight.
        case updating(Date)
        /// From the cache; the fetch didn't succeed.
        case stale(Date, StatsLoader.Reason)

        /// When the shown answer was fetched.
        public var fetchedAt: Date {
            switch self {
            case .fresh(let date), .updating(let date), .stale(let date, _): date
            }
        }
    }

    public enum Load<Value: Sendable>: Sendable {
        case loading
        case loaded(Value, Freshness)
        case unavailable(StatsLoader.Reason)

        public var value: Value? {
            if case .loaded(let value, _) = self { return value }
            return nil
        }
    }

    public private(set) var stats: Load<TopicStats> = .loading
    /// By question key; only int, double and enum questions have one.
    public private(set) var series: [String: Load<QuestionSeries>] = [:]
    /// Every source the topic's entries have (unfiltered), for the source filter.
    public private(set) var sources: [String] = []

    /// Counts `load` calls: only the latest one publishes, or puts back what it replaced. Two
    /// loads of the same query (the first load and a pull to refresh) are told apart by it.
    @ObservationIgnored private var generation = 0
    /// The query, bucket and zone on screen (the last `load`'s, once it began).
    @ObservationIgnored private var shown: Request?
    @ObservationIgnored private let loader: @MainActor () -> StatsLoader?
    @ObservationIgnored private let topicId: UUID
    @ObservationIgnored private let ref: String
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone

    private struct Request: Hashable {
        var query: StatsQuery
        var bucket: QuestionSeries.Bucket
        var timeZone: String
    }

    /// `loader` is the bound store's (`session.stats`); `timeZone` is the reader's, which the
    /// server buckets series in. It is read at every load: the device's zone can change while the
    /// screen is open.
    public init(
        topicId: UUID, ref: String, timeZone: @escaping @MainActor () -> TimeZone = { TimeZone.current },
        loader: @escaping @MainActor () -> StatsLoader?
    ) {
        self.topicId = topicId
        self.ref = ref
        self.timeZone = timeZone
        self.loader = loader
    }

    /// The unfiltered query, for the source filter's choices.
    public static let allTime = StatsQuery(cacheKey: "all", filters: EntryFilters())

    /// Loads the stats for `query`, then each chartable question's series in `bucket`.
    public func load(query: StatsQuery, bucket: QuestionSeries.Bucket) async {
        let timeZone = timeZone().identifier
        let request = Request(query: query, bucket: bucket, timeZone: timeZone)
        generation += 1
        let mine = generation
        guard let loader = loader() else {
            stats = .unavailable(.failed("Not connected to a server."))
            series = [:]
            return
        }
        let topicId = topicId
        let ref = ref
        // A reload (pull to refresh) keeps what's on screen; new filters or a new bucket show the
        // cached answer for them, or loading.
        let reload = shown == request
        shown = request
        // Cancelled (the view went away, or SwiftUI ended a refresh) or rebound: what was on
        // screen stays.
        // A cancelled task's reads fail, so its results would read as errors.
        let before = (stats: stats, series: series)
        let scope = loader.scope
        // Another store bound meanwhile (a server switch, a reset): this answer belongs to the old
        // one and isn't published either.
        func abandoned() -> Bool {
            // A newer load owns the screen: this one neither publishes nor puts anything back.
            guard generation == mine else { return true }
            guard Task.isCancelled || self.loader()?.scope != scope else { return false }
            restore(before)
            return true
        }
        // After every await: a newer load may own the screen by now (a write here would overwrite
        // its answer, or leave "loading" behind), or this one was cancelled or rebound.
        let cached = await loader.cachedStats(topicId: topicId, query: query)
        guard !abandoned() else { return }
        if let (cached, fetchedAt) = cached {
            stats = .loaded(cached, .updating(fetchedAt))
        } else if !reload {
            stats = .loading
        }
        async let sourcesResult = loader.stats(topicId: topicId, ref: ref, query: Self.allTime)
        let result = await loader.stats(topicId: topicId, ref: ref, query: query)
        guard !abandoned() else { return }
        stats = Self.load(result)
        let all = await sourcesResult.value
        guard !abandoned() else { return }
        if let all { sources = all.sources.map(\.value) }
        guard let shown = stats.value else {
            series = [:]
            return
        }
        let keys = shown.questions.compactMap { question -> String? in
            switch question {
            case .numeric, .choice: question.key
            case .text: nil
            }
        }
        var next: [String: Load<QuestionSeries>] = [:]
        for key in keys {
            let cached = await loader.cachedSeries(
                topicId: topicId, key: key, bucket: bucket, timeZone: timeZone, query: query)
            guard !abandoned() else { return }
            if let (cached, fetchedAt) = cached {
                next[key] = .loaded(cached, .updating(fetchedAt))
            } else {
                next[key] = reload ? series[key] ?? .loading : .loading
            }
        }
        guard !abandoned() else { return }
        series = next
        await withTaskGroup(of: (String, StatsResult<QuestionSeries>).self) { group in
            for key in keys {
                group.addTask {
                    (
                        key,
                        await loader.series(
                            topicId: topicId, ref: ref, key: key, bucket: bucket, timeZone: timeZone, query: query)
                    )
                }
            }
            for await (key, result) in group {
                guard !abandoned() else { return }
                series[key] = Self.load(result)
            }
        }
    }

    /// Puts back what an abandoned load replaced: anything still loading or updating.
    private func restore(_ before: (stats: Load<TopicStats>, series: [String: Load<QuestionSeries>])) {
        if Self.isPending(stats) { stats = before.stats }
        for (key, load) in series where Self.isPending(load) {
            series[key] = before.series[key] ?? load
        }
    }

    private static func isPending<Value>(_ load: Load<Value>) -> Bool {
        switch load {
        case .loading, .loaded(_, .updating): true
        default: false
        }
    }

    static func load<Value>(_ result: StatsResult<Value>) -> Load<Value> {
        switch result {
        case .fresh(let value, let fetchedAt): .loaded(value, .fresh(fetchedAt))
        case .stale(let value, let fetchedAt, let reason): .loaded(value, .stale(fetchedAt, reason))
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}
