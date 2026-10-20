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

    /// The query and bucket of the last `load`: an answer for an older one is dropped.
    @ObservationIgnored private var current: Request?
    /// The query and bucket on screen (the last `load`'s, once it began).
    @ObservationIgnored private var shown: Request?
    @ObservationIgnored private let loader: @MainActor () -> StatsLoader?
    @ObservationIgnored private let topicId: UUID
    @ObservationIgnored private let ref: String
    @ObservationIgnored private let timeZone: String

    private struct Request: Hashable {
        var query: StatsQuery
        var bucket: QuestionSeries.Bucket
    }

    /// `loader` is the bound store's (`session.stats`); `timeZone` is the reader's, which the
    /// server buckets series in.
    public init(
        topicId: UUID, ref: String, timeZone: TimeZone = .autoupdatingCurrent,
        loader: @escaping @MainActor () -> StatsLoader?
    ) {
        self.topicId = topicId
        self.ref = ref
        self.timeZone = timeZone.identifier
        self.loader = loader
    }

    /// The unfiltered query, for the source filter's choices.
    public static let allTime = StatsQuery(cacheKey: "all", filters: EntryFilters())

    /// Loads the stats for `query`, then each chartable question's series in `bucket`.
    public func load(query: StatsQuery, bucket: QuestionSeries.Bucket) async {
        let request = Request(query: query, bucket: bucket)
        current = request
        guard let loader = loader() else {
            stats = .unavailable(.failed("Not connected to a server."))
            series = [:]
            return
        }
        let topicId = topicId
        let ref = ref
        let timeZone = timeZone
        // A reload (pull to refresh) keeps what's on screen; new filters or a new bucket show the
        // cached answer for them, or loading.
        let reload = shown == request
        shown = request
        if let (cached, fetchedAt) = await loader.cachedStats(topicId: topicId, query: query) {
            guard current == request else { return }
            stats = .loaded(cached, .updating(fetchedAt))
        } else if !reload {
            stats = .loading
        }
        async let sourcesResult = loader.stats(topicId: topicId, ref: ref, query: Self.allTime)
        let result = await loader.stats(topicId: topicId, ref: ref, query: query)
        guard current == request else { return }
        stats = Self.load(result)
        if let all = await sourcesResult.value, current == request { sources = all.sources.map(\.value) }
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
            if let (cached, fetchedAt) = await loader.cachedSeries(
                topicId: topicId, key: key, bucket: bucket, timeZone: timeZone, query: query)
            {
                next[key] = .loaded(cached, .updating(fetchedAt))
            } else {
                next[key] = reload ? series[key] ?? .loading : .loading
            }
        }
        guard current == request else { return }
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
            for await (key, result) in group where current == request {
                series[key] = Self.load(result)
            }
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
