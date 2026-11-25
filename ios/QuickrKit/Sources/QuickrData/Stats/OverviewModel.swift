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
    /// getTopicTiming for the same filters (timers.md §9.2): zero runs for an untimed topic.
    public private(set) var timing: Load<TopicTimingDTO> = .loading
    /// By question key; only int, double and enum questions have one.
    public private(set) var series: [String: Load<QuestionSeries>] = [:]
    /// Every source the topic's entries have (unfiltered), for the source filter.
    public private(set) var sources: [String] = []
    /// The last 12 weeks' entries per local day (content-display.md §4.2), from the store: it
    /// ignores the range and the filters, so it shows above "Nothing in this range" too.
    public private(set) var activity: Load<ActivityStrip> = .loading
    /// Each numeric question's trend (§4.3): its series in the range's default bucket, which is
    /// the chart's series when the chart is in that bucket. By question key.
    public private(set) var sparklines: [String: Load<QuestionSeries>] = [:]

    /// Counts `load` calls: only the latest one publishes, or puts back what it replaced. Two
    /// loads of the same query (the first load and a pull to refresh) are told apart by it.
    @ObservationIgnored private var generation = 0
    /// The query, bucket and zone on screen (the last `load`'s, once it began).
    @ObservationIgnored private var shown: Request?
    @ObservationIgnored private let loader: @MainActor () -> StatsLoader?
    @ObservationIgnored private let topicId: UUID
    @ObservationIgnored private let ref: String
    @ObservationIgnored private let timeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let now: @MainActor () -> Date

    private struct Request: Hashable {
        var query: StatsQuery
        var bucket: QuestionSeries.Bucket
        var sparkBucket: QuestionSeries.Bucket
        var timeZone: String
    }

    /// `loader` is the bound store's (`session.stats`); `timeZone` is the reader's, which the
    /// server buckets series in and the activity strip's days are in. It is read at every load:
    /// the device's zone can change while the screen is open. `now` gives the strip's today.
    public init(
        topicId: UUID, ref: String, timeZone: @escaping @MainActor () -> TimeZone = { TimeZone.current },
        now: @escaping @MainActor () -> Date = { Date() },
        loader: @escaping @MainActor () -> StatsLoader?
    ) {
        self.topicId = topicId
        self.ref = ref
        self.timeZone = timeZone
        self.now = now
        self.loader = loader
    }

    /// The unfiltered query, for the source filter's choices.
    public static let allTime = StatsQuery(cacheKey: "all", filters: EntryFilters())

    /// Loads the activity strip and the stats for `query`, then each chartable question's series
    /// in `bucket`, then the numeric questions' trends in `sparkBucket` (the range's default
    /// bucket; nil: `bucket`). In `bucket` they are the charts' series, not fetched twice.
    public func load(query: StatsQuery, bucket: QuestionSeries.Bucket, sparkBucket: QuestionSeries.Bucket? = nil)
        async
    {
        let zone = timeZone()
        let timeZone = zone.identifier
        let sparkBucket = sparkBucket ?? bucket
        let request = Request(query: query, bucket: bucket, sparkBucket: sparkBucket, timeZone: timeZone)
        generation += 1
        let mine = generation
        guard let loader = loader() else {
            stats = .unavailable(.failed("Not connected to a server."))
            series = [:]
            sparklines = [:]
            activity = .unavailable(.failed("Not connected to a server."))
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
        let before = (stats: stats, series: series, sparklines: sparklines)
        let timingBefore = timing
        let scope = loader.scope
        // Another store bound meanwhile (a server switch, a reset): this answer belongs to the old
        // one and isn't published either.
        func abandoned() -> Bool {
            // A newer load owns the screen: this one neither publishes nor puts anything back.
            guard generation == mine else { return true }
            guard Task.isCancelled || self.loader()?.scope != scope else { return false }
            restore(before)
            if Self.isPending(timing) { timing = timingBefore }
            return true
        }
        // After every await: a newer load may own the screen by now (a write here would overwrite
        // its answer, or leave "loading" behind), or this one was cancelled or rebound.
        let readAt = now()
        let strip = await Self.activity(
            loader.store, topicId: topicId, today: ActivityStrip.localDay(readAt, timeZone: zone), timeZone: zone,
            at: readAt)
        guard !abandoned() else { return }
        activity = strip
        let cached = await loader.cachedStats(topicId: topicId, query: query)
        guard !abandoned() else { return }
        if let (cached, fetchedAt) = cached {
            stats = .loaded(cached, .updating(fetchedAt))
        } else if !reload {
            stats = .loading
        }
        let cachedTiming = await loader.cachedTiming(topicId: topicId, query: query)
        guard !abandoned() else { return }
        if let (cachedTiming, fetchedAt) = cachedTiming {
            timing = .loaded(cachedTiming, .updating(fetchedAt))
        } else if !reload {
            timing = .loading
        }
        async let sourcesResult = loader.stats(topicId: topicId, ref: ref, query: Self.allTime)
        async let timingResult = loader.timing(topicId: topicId, ref: ref, query: query)
        let result = await loader.stats(topicId: topicId, ref: ref, query: query)
        guard !abandoned() else { return }
        stats = Self.load(result)
        let timed = await timingResult
        guard !abandoned() else { return }
        timing = Self.load(timed)
        let all = await sourcesResult.value
        guard !abandoned() else { return }
        if let all { sources = all.sources.map(\.value) }
        guard let shown = stats.value else {
            series = [:]
            sparklines = [:]
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
        let numeric = Set(shown.questions.compactMap { question -> String? in
            if case .numeric = question { question.key } else { nil }
        })
        let shared = sparkBucket == bucket
        // In another bucket they load after the charts' series: until then, what a reload had, or
        // loading.
        sparklines =
            shared
            ? next.filter { numeric.contains($0.key) }
            : Dictionary(uniqueKeysWithValues: numeric.map { ($0, reload ? sparklines[$0] ?? .loading : .loading) })
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
                if shared, numeric.contains(key) { sparklines[key] = series[key] }
            }
        }
        guard !abandoned(), !shared else { return }
        await loadSparklines(
            numeric.sorted(), loader: loader, query: query, sparkBucket: sparkBucket, timeZone: timeZone,
            reload: reload, abandoned: abandoned)
    }

    /// The numeric questions' trends in `sparkBucket` (not the charts' bucket), after the charts'
    /// series (§4.3): the cached ones at once, then each fetched.
    private func loadSparklines(
        _ keys: [String], loader: StatsLoader, query: StatsQuery, sparkBucket: QuestionSeries.Bucket,
        timeZone: String, reload: Bool, abandoned: () -> Bool
    ) async {
        let topicId = topicId
        let ref = ref
        var next: [String: Load<QuestionSeries>] = [:]
        for key in keys {
            let cached = await loader.cachedSeries(
                topicId: topicId, key: key, bucket: sparkBucket, timeZone: timeZone, query: query)
            guard !abandoned() else { return }
            if let (cached, fetchedAt) = cached {
                next[key] = .loaded(cached, .updating(fetchedAt))
            } else {
                next[key] = reload ? sparklines[key] ?? .loading : .loading
            }
        }
        guard !abandoned() else { return }
        sparklines = next
        await withTaskGroup(of: (String, StatsResult<QuestionSeries>).self) { group in
            for key in keys {
                group.addTask {
                    (
                        key,
                        await loader.series(
                            topicId: topicId, ref: ref, key: key, bucket: sparkBucket, timeZone: timeZone,
                            query: query)
                    )
                }
            }
            for await (key, result) in group {
                guard !abandoned() else { return }
                sparklines[key] = Self.load(result)
            }
        }
    }

    /// The strip from the store's entries since the first cell's local midnight (§4.2).
    static func activity(_ store: LocalStore, topicId: UUID, today: String, timeZone: TimeZone, at: Date) async
        -> Load<ActivityStrip>
    {
        let from = ActivityStrip.localMidnight(ActivityStrip.firstDay(today: today), timeZone: timeZone)
        do {
            let entries = try await store.entries(topicId: topicId, from: from)
            let strip = ActivityStrip(capturedAt: entries.map(\.entry.capturedAt), today: today, timeZone: timeZone)
            return .loaded(strip, .fresh(at))
        } catch {
            return .unavailable(.failed("Could not read this topic's entries."))
        }
    }

    /// Puts back what an abandoned load replaced: anything still loading or updating.
    private func restore(
        _ before: (
            stats: Load<TopicStats>, series: [String: Load<QuestionSeries>],
            sparklines: [String: Load<QuestionSeries>]
        )
    ) {
        if Self.isPending(stats) { stats = before.stats }
        for (key, load) in series where Self.isPending(load) {
            series[key] = before.series[key] ?? load
        }
        for (key, load) in sparklines where Self.isPending(load) {
            sparklines[key] = before.sparklines[key] ?? load
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
