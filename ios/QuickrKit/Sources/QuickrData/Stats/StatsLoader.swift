import Foundation
import GRDB
import QuickrCore

/// Which stats a screen asks for: the filters as sent, and what they mean for the cache.
public struct StatsQuery: Sendable, Hashable {
    /// The filters' meaning, for the cache key (for example `range=30d&source=web`). The sent
    /// `captured_from` moves every day; this doesn't, so yesterday's "30 days" still shows offline.
    public var cacheKey: String
    public var filters: EntryFilters

    public init(cacheKey: String, filters: EntryFilters) {
        self.cacheKey = cacheKey
        self.filters = filters
    }

    /// The topic page's filters (`filterQuery`): `captured_from` from the range at `now`, and the
    /// version and source as they are. The cache key names the range, not its start.
    public init(_ filters: EntryListFilters, now: Date, calendar: Calendar) {
        let parts = [
            "range=\(filters.range.rawValue)", filters.version.map { "version=\($0)" },
            filters.source.map { "source=\($0)" },
        ]
        self.init(
            cacheKey: parts.compactMap { $0 }.joined(separator: "&"),
            filters: EntryFilters(
                capturedFrom: filters.range.start(now: now, calendar: calendar), version: filters.version,
                source: filters.source))
    }
}

/// What a stats or series load came to (PLAN: "server-computed and cached; offline they show as
/// stale with a Last updated label").
public enum StatsResult<Value: Sendable>: Sendable {
    /// Just fetched, and cached.
    case fresh(Value, fetchedAt: Date)
    /// The fetch didn't succeed; the last cached answer for the same query, from `fetchedAt`.
    case stale(Value, fetchedAt: Date, StatsLoader.Reason)
    /// The fetch didn't succeed and nothing is cached.
    case unavailable(StatsLoader.Reason)

    public var value: Value? {
        switch self {
        case .fresh(let value, _), .stale(let value, _, _): value
        case .unavailable: nil
        }
    }
}

extension StatsResult: Equatable where Value: Equatable {}

/// Fetches a topic's stats and its questions' series, and caches them in the store's
/// `stats_cache` (sync-protocol.md §11): a response is cached and shown only if its epoch is the
/// store's. One whose epoch differs is discarded; the store is marked `epoch_suspect` and the
/// coordinator runs (S20). Cached rows are read only under the epoch they were fetched in; a
/// topic's rows go with its tombstone, and another server or a reset is another store file.
public struct StatsLoader: Sendable {
    public enum Reason: Sendable, Hashable {
        /// No connection.
        case offline
        /// The server's data changed under the store (another epoch, another server): the
        /// coordinator is resyncing; try again after it.
        case resyncing
        case failed(String)

        public var message: String {
            switch self {
            case .offline: "Stats need a connection."
            case .resyncing: "quickR is resyncing, try again in a moment."
            case .failed(let message): message
            }
        }
    }

    let store: LocalStore
    let client: APIClient
    let requestSync: @Sendable () async -> Void
    let now: @Sendable () -> Date

    /// `requestSync` asks the coordinator for a run (after an epoch or identity mismatch).
    public init(
        store: LocalStore, client: APIClient, requestSync: @escaping @Sendable () async -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.client = client
        self.requestSync = requestSync
        self.now = now
    }

    // MARK: - Keys

    /// `{server_id}/{store_gen}|stats|{topic}|{range&version&source}`. The store file already
    /// belongs to one server and generation; the key says so too.
    func statsKey(topicId: UUID, query: StatsQuery) -> String {
        "\(store.scope.id)|stats|\(topicId.wireString)|\(query.cacheKey)"
    }

    /// `...|series|{topic}|{question}|{bucket}|{tz}|{range&version&source}`: another bucket or
    /// zone is another answer, never served for this one.
    func seriesKey(
        topicId: UUID, key: String, bucket: QuestionSeries.Bucket, timeZone: String, query: StatsQuery
    ) -> String {
        "\(store.scope.id)|series|\(topicId.wireString)|\(key)|\(bucket.rawValue)|\(timeZone)|\(query.cacheKey)"
    }

    // MARK: - Loads

    /// The cached stats for `query`, if any (to show while fetching).
    public func cachedStats(topicId: UUID, query: StatsQuery) async -> (TopicStats, fetchedAt: Date)? {
        await cached(TopicStatsDTO.self, key: statsKey(topicId: topicId, query: query))
    }

    public func stats(topicId: UUID, ref: String, query: StatsQuery) async -> StatsResult<TopicStats> {
        await load(TopicStatsDTO.self, key: statsKey(topicId: topicId, query: query), topicId: topicId) {
            options in
            try await client.getTopicStats(ref: ref, filters: query.filters, options: options)
        }
    }

    /// The cached series, if any (to show while fetching).
    public func cachedSeries(
        topicId: UUID, key: String, bucket: QuestionSeries.Bucket, timeZone: String, query: StatsQuery
    ) async -> (QuestionSeries, fetchedAt: Date)? {
        await cached(
            QuestionSeriesDTO.self,
            key: seriesKey(topicId: topicId, key: key, bucket: bucket, timeZone: timeZone, query: query))
    }

    /// `timeZone` is the IANA zone the server buckets in (the reader's).
    public func series(
        topicId: UUID, ref: String, key: String, bucket: QuestionSeries.Bucket, timeZone: String, query: StatsQuery
    ) async -> StatsResult<QuestionSeries> {
        let cacheKey = seriesKey(topicId: topicId, key: key, bucket: bucket, timeZone: timeZone, query: query)
        return await load(QuestionSeriesDTO.self, key: cacheKey, topicId: topicId) { options in
            try await client.getQuestionSeries(
                ref: ref, key: key, bucket: bucket, timezone: timeZone, filters: query.filters, options: options)
        }
    }

    // MARK: - Machinery

    private func load<DTO: WireResponse>(
        _ type: DTO.Type, key: String, topicId: UUID,
        fetch: (RequestOptions) async throws -> APIResponse<DTO.Domain>
    ) async -> StatsResult<DTO.Domain> where DTO.Domain: Sendable {
        let context: RequestContext
        do {
            context = try await store.requestContext()
        } catch {
            return await fallback(type, key: key, .failed("Stats aren't available yet."))
        }
        let response: APIResponse<DTO.Domain>
        do {
            response = try await fetch(RequestOptions(expecting: context.identity))
        } catch {
            return await fallback(type, key: key, .failed("\(error)"))
        }
        switch response.outcome {
        case .success(let value):
            let fetchedAt = now()
            guard let epoch = context.epoch else { return .fresh(value, fetchedAt: fetchedAt) }
            let payload = String(decoding: response.body, as: UTF8.self)
            let written = try? await store.applyFenced(context) { db in
                try Self.write(db, key: key, topicId: topicId, epoch: epoch, payload: payload, fetchedAt: fetchedAt)
            }
            // The store moved on (a swap or a reset) while it was in flight: its epoch may not be
            // this response's any more, so it isn't shown either (§11).
            guard case .success = written else { return await fallback(type, key: key, .resyncing) }
            return .fresh(value, fetchedAt: fetchedAt)
        case .epochMismatch:
            let clock = store.leaseClock
            _ = try? await store.writer.write { db in
                try SyncTransactions.setEpochSuspect(db, conditions: context.conditions, now: clock.now())
            }
            await requestSync()
            return await fallback(type, key: key, .resyncing)
        case .identityMismatch:
            await requestSync()
            return await fallback(type, key: key, .resyncing)
        case .retryable(.noResponse), .uncertain(.noResponse):
            return await fallback(type, key: key, .offline)
        default:
            return await fallback(type, key: key, .failed(response.message ?? "Could not load stats"))
        }
    }

    private func fallback<DTO: WireResponse>(_ type: DTO.Type, key: String, _ reason: Reason) async
        -> StatsResult<DTO.Domain> where DTO.Domain: Sendable
    {
        guard let (value, fetchedAt) = await cached(type, key: key) else { return .unavailable(reason) }
        return .stale(value, fetchedAt: fetchedAt, reason)
    }

    private func cached<DTO: WireResponse>(_ type: DTO.Type, key: String) async -> (DTO.Domain, fetchedAt: Date)?
    where DTO.Domain: Sendable {
        let row = try? await store.writer.read { db in try Self.read(db, key: key) }
        guard let row = row ?? nil,
            let value = try? DTO.decode(Data(row.payload.utf8), using: WireCoding.decoder()).toDomain()
        else { return nil }
        return (value, row.fetchedAt)
    }

    // MARK: - SQL

    /// The row for `key`, only if it was fetched under the store's current epoch.
    static func read(_ db: Database, key: String) throws -> (payload: String, fetchedAt: Date)? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT payload_json, fetched_at FROM stats_cache
                WHERE key = ? AND epoch = (SELECT epoch FROM sync_state WHERE id = 1)
                """,
            arguments: [key])
        guard let row else { return nil }
        return (row["payload_json"], Date(timeIntervalSince1970: row["fetched_at"]))
    }

    /// Stores the row, and drops rows of other epochs (they can't be shown again).
    static func write(_ db: Database, key: String, topicId: UUID, epoch: String, payload: String, fetchedAt: Date)
        throws
    {
        try db.execute(sql: "DELETE FROM stats_cache WHERE epoch <> ?", arguments: [epoch])
        try db.execute(
            sql: """
                INSERT INTO stats_cache (key, topic_id, epoch, payload_json, fetched_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET
                  topic_id = excluded.topic_id, epoch = excluded.epoch, payload_json = excluded.payload_json,
                  fetched_at = excluded.fetched_at
                """,
            arguments: [key, topicId.wireString, epoch, payload, fetchedAt.timeIntervalSince1970])
    }
}
