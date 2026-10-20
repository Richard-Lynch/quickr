import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// `StatsLoader`: fetch, the epoch-checked `stats_cache` (sync-protocol.md §11, S20), and stale
/// results offline. The responses are the real ones in `stats-vectors.json`.
@Suite struct StatsLoaderTests {
    static let base = URL(string: "https://quickr.example")!
    static let topicId = UUID(uuidString: "5a7c0000-0000-4000-8000-000000000001")!

    /// A bootstrapped store (server-1, epoch E1) and a fake server answering with `body`.
    final class Harness: Sendable {
        let directory: TempDirectory
        let store: LocalStore
        let transport = FakeTransport()
        let wall = FakeClock(Date(timeIntervalSince1970: 1_760_000_000))
        private let syncRequests = Mutex(0)

        init() throws {
            directory = try TempDirectory()
            let url = directory.url.appending(path: "store.sqlite")
            let pool = try StoreDatabase.openPool(at: url)
            try pool.write { db in
                try LocalStore.createSyncState(db, serverId: "server-1", baseURL: StatsLoaderTests.base.absoluteString)
                try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            }
            store = LocalStore(
                serverId: "server-1", storeGen: 1, url: url, writer: pool, leaseClock: FakeLeaseClock(), wallClock: wall
            )
        }

        deinit { directory.cleanup() }

        var loader: StatsLoader {
            let client = APIClient(
                baseURL: StatsLoaderTests.base, transport: transport, identity: StaticServerIdentity(nil))
            return StatsLoader(
                store: store, client: client, requestSync: { self.syncRequests.withLock { $0 += 1 } },
                now: { self.wall.now() })
        }

        var syncsRequested: Int { syncRequests.withLock { $0 } }

        /// Every request answers 200 with `body`, from `server-1` at `epoch`.
        func answer(_ body: Data, epoch: String = "E1", before: (@Sendable () throws -> Void)? = nil) {
            transport.reset()
            transport.stub(
                where: { _ in true },
                { _ in
                    try before?()
                    return HTTPResponse(
                        status: 200, headers: [QuickrHeader.serverId: "server-1", QuickrHeader.epoch: epoch], body: body
                    )
                })
        }

        func offline() {
            transport.reset()
            transport.stub(where: { _ in true }, { _ in throw TransportError.unreachable("offline") })
        }

        func execute(_ sql: String) throws { try store.writer.write { db in try db.execute(sql: sql) } }

        func rows() throws -> [Row] {
            try store.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM stats_cache ORDER BY key") }
        }

        func flag(_ column: String) throws -> Bool {
            try store.writer.read { db in try Bool.fetchOne(db, sql: "SELECT \(column) FROM sync_state") ?? false }
        }
    }

    // MARK: - Fixtures

    static let input: StatsChartVectorTests.Input = StatsChartVectorTests.load("stats-vectors.json")

    static func response<T: WireResponse>(_ type: T.Type, _ name: String) throws -> T.Domain {
        try T.decode(body(name), using: WireCoding.decoder()).toDomain()
    }

    static func body(_ name: String) throws -> Data {
        let input = try #require(Self.input.cases.first { $0.name == name })
        return try JSONEncoder().encode(input.response)
    }

    static let thirtyDays = StatsQuery(
        cacheKey: "range=30d", filters: EntryFilters(capturedFrom: Date(timeIntervalSince1970: 1_757_000_000)))

    // MARK: - Requests

    /// Each case's request carries the case's query: the filters, and for a series the bucket and
    /// zone (the server's defaults are never relied on).
    @Test func requestsCarryTheQuery() async throws {
        let h = try Harness()
        for c in Self.input.cases {
            h.answer(try JSONEncoder().encode(c.response))
            var filters = EntryFilters()
            if let from = c.query["captured_from"] { filters.capturedFrom = try #require(WireDate.parse(from)) }
            filters.version = c.query["version"].flatMap(Int.init)
            filters.source = c.query["source"]
            let query = StatsQuery(cacheKey: c.name, filters: filters)
            let result: Bool
            if c.kind == "stats" {
                result = await h.loader.stats(topicId: Self.topicId, ref: c.topic, query: query).value != nil
            } else {
                let raw = c.query["bucket"] ?? ""
                let bucket = try #require(QuestionSeries.Bucket(rawValue: raw))
                result =
                    await h.loader.series(
                        topicId: Self.topicId, ref: c.topic, key: try #require(c.question), bucket: bucket,
                        timeZone: try #require(c.query["tz"]), query: query
                    ).value != nil
            }
            #expect(result, "\(c.name) loads")
            let request = try #require(h.transport.requests.last)
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var sent = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            var expected = c.query
            // The same instant: the PWA sends local offsets, the client UTC.
            if let from = sent.removeValue(forKey: "captured_from") {
                let wanted = expected.removeValue(forKey: "captured_from")
                #expect(WireDate.parse(from) == wanted.flatMap(WireDate.parse), "\(c.name) captured_from")
            }
            #expect(sent == expected, "\(c.name)")
            let path =
                c.kind == "stats"
                ? "/api/v1/topics/\(c.topic)/stats" : "/api/v1/topics/\(c.topic)/questions/\(c.question ?? "")/series"
            #expect(request.url.path == path)
        }
    }

    /// The topic page's filters: `captured_from` is the range's start at `now`; the cache key
    /// names the range, version and source, so it stays the same from one day to the next.
    @Test func aQueryFromTheTopicFilters() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let now = try #require(WireDate.parse("2025-10-26T12:00:00Z"))
        let filters = EntryListFilters(range: .sevenDays, version: 2, source: "web")
        let query = StatsQuery(filters, now: now, calendar: calendar)
        #expect(query.cacheKey == "range=7d&version=2&source=web")
        #expect(
            query.filters
                == EntryFilters(
                    capturedFrom: filters.range.start(now: now, calendar: calendar), version: 2, source: "web"))
        #expect(query.filters.capturedFrom == WireDate.parse("2025-10-20T00:00:00+01:00"))
        let tomorrow = StatsQuery(filters, now: now.addingTimeInterval(86_400), calendar: calendar)
        #expect(tomorrow.cacheKey == query.cacheKey && tomorrow.filters.capturedFrom != query.filters.capturedFrom)
        let all = StatsQuery(EntryListFilters(range: .all), now: now, calendar: calendar)
        #expect(all.cacheKey == "range=all" && all.filters == EntryFilters())
    }

    // MARK: - Cache

    @Test func aFetchIsCachedUnderTheStoresEpoch() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        let result = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        guard case .fresh(let stats, let fetchedAt) = result else {
            Issue.record("expected fresh, got \(result)")
            return
        }
        #expect(stats.entryCount == 12 && fetchedAt == h.wall.now())
        let rows = try h.rows()
        #expect(rows.count == 1)
        #expect(rows.first?["epoch"] == "E1" && rows.first?["topic_id"] == Self.topicId.wireString)
        let cached = await h.loader.cachedStats(topicId: Self.topicId, query: Self.thirtyDays)
        #expect(cached?.0 == stats && cached?.fetchedAt == fetchedAt)
    }

    /// Offline the last answer shows, stale, with when it was fetched; the same range on a later
    /// day (another `captured_from`) is the same cached answer.
    @Test func offlineShowsTheCachedAnswerAsStale() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        let stats = try #require(
            await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays).value)
        h.answer(try Self.body("series everything glasses day Europe/London"))
        let fetched = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "Europe/London",
            query: Self.thirtyDays)
        let series = try #require(fetched.value)
        let fetchedAt = h.wall.now()
        h.wall.advance(by: 86_400)
        h.offline()
        let tomorrow = StatsQuery(
            cacheKey: "range=30d", filters: EntryFilters(capturedFrom: Date(timeIntervalSince1970: 1_757_086_400)))
        let offline = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "Europe/London",
            query: tomorrow)
        #expect(offline == .stale(series, fetchedAt: fetchedAt, .offline))
        let offlineStats = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: tomorrow)
        #expect(offlineStats == .stale(stats, fetchedAt: fetchedAt, .offline))
        // Another bucket, zone or range was never fetched: nothing to show.
        let week = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .week, timeZone: "Europe/London",
            query: tomorrow)
        #expect(week == .unavailable(.offline))
        let otherZone = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "UTC", query: tomorrow)
        #expect(otherZone == .unavailable(.offline))
        let allTime = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "Europe/London",
            query: StatsQuery(cacheKey: "range=all", filters: EntryFilters()))
        #expect(allTime == .unavailable(.offline))
    }

    /// The key names the store (server and generation) and the whole query: range, version,
    /// source, and for a series the question, bucket and zone.
    @Test func theKeyNamesTheStoreTheQueryAndTheZone() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        let query = StatsQuery(cacheKey: "range=7d&source=web", filters: EntryFilters(source: "web"))
        _ = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: query)
        h.answer(try Self.body("series everything glasses week America/Santiago"))
        _ = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .week, timeZone: "America/Santiago",
            query: query)
        let id = Self.topicId.wireString
        #expect(
            try h.rows().map { $0["key"] as String } == [
                "server-1/1|series|\(id)|glasses|week|America/Santiago|range=7d&source=web",
                "server-1/1|stats|\(id)|range=7d&source=web",
            ])
    }

    /// The reader's zone changed: the old zone's buckets are another answer. Online the new zone's
    /// are fetched (nothing of the old shows meanwhile); offline there is nothing to show.
    @Test func aZoneChangeNeverServesTheOldZonesBuckets() async throws {
        let h = try Harness()
        let london = try Self.response(QuestionSeriesDTO.self, "series everything glasses day Europe/London")
        let santiago = try Self.response(QuestionSeriesDTO.self, "series everything glasses day America/Santiago")
        #expect(london != santiago)
        h.answer(try Self.body("series everything glasses day Europe/London"))
        _ = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "Europe/London",
            query: Self.thirtyDays)
        #expect(
            await h.loader.cachedSeries(
                topicId: Self.topicId, key: "glasses", bucket: .day, timeZone: "America/Santiago",
                query: Self.thirtyDays)
                == nil)
        h.offline()
        #expect(
            await h.loader.series(
                topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "America/Santiago",
                query: Self.thirtyDays) == .unavailable(.offline))
        h.answer(try Self.body("series everything glasses day America/Santiago"))
        let fresh = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "glasses", bucket: .day, timeZone: "America/Santiago",
            query: Self.thirtyDays)
        #expect(fresh.value == santiago)
    }

    /// S20: a response from another epoch is discarded (not shown, not cached), the store is
    /// marked `epoch_suspect` and the coordinator is asked to run.
    @Test func anotherEpochIsDiscardedAndStartsAResync() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        let first = try #require(
            await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays).value)
        let before = try h.rows()
        h.answer(try Self.body("stats everything source web"), epoch: "E2")
        let result = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        guard case .stale(let shown, _, .resyncing) = result else {
            Issue.record("expected stale (resyncing), got \(result)")
            return
        }
        #expect(shown == first)
        #expect(try h.rows() == before)
        #expect(try h.flag("epoch_suspect"))
        #expect(h.syncsRequested == 1)
    }

    /// Rows are shown only under the epoch they were fetched in: after a rebuild to E2 the E1
    /// answer is gone, and the first E2 write drops it.
    @Test func aNewEpochHidesAndDropsTheOldRows() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        _ = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        try h.execute("UPDATE sync_state SET epoch = 'E2', layer_gen = layer_gen + 1")
        #expect(await h.loader.cachedStats(topicId: Self.topicId, query: Self.thirtyDays) == nil)
        h.offline()
        #expect(
            await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
                == .unavailable(.offline))
        h.answer(try Self.body("series everything mood day UTC"), epoch: "E2")
        _ = await h.loader.series(
            topicId: Self.topicId, ref: "everything", key: "mood", bucket: .day, timeZone: "UTC", query: Self.thirtyDays
        )
        #expect(try h.rows().map { $0["epoch"] as String } == ["E2"])
    }

    /// A swap while the request is in flight: the context no longer holds, so the answer is
    /// neither cached nor shown.
    @Test func aSwapInFlightDiscardsTheAnswer() async throws {
        let h = try Harness()
        let store = h.store
        h.answer(try Self.body("stats everything all")) {
            try store.writer.write { db in try db.execute(sql: "UPDATE sync_state SET layer_gen = layer_gen + 1") }
        }
        let result = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        #expect(result == .unavailable(.resyncing))
        #expect(try h.rows().isEmpty)
    }

    /// Another server behind the address: nothing shown, and a resync.
    @Test func anotherServerStartsAResync() async throws {
        let h = try Harness()
        h.transport.stub(
            where: { _ in true },
            { _ in
                HTTPResponse(
                    status: 200, headers: [QuickrHeader.serverId: "server-2", QuickrHeader.epoch: "E1"],
                    body: try Self.body("stats everything all"))
            })
        let result = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        #expect(result == .unavailable(.resyncing))
        #expect(h.syncsRequested == 1)
        #expect(try h.rows().isEmpty)
    }

    /// A server error shows the cached answer with the server's message.
    @Test func aServerErrorKeepsTheCachedAnswer() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        let first = try #require(
            await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays).value)
        h.transport.reset()
        h.transport.stub(
            where: { _ in true },
            { _ in
                HTTPResponse(
                    status: 500, headers: [QuickrHeader.serverId: "server-1", QuickrHeader.epoch: "E1"],
                    body: Data(#"{"code":"internal","detail":"boom","errors":[]}"#.utf8))
            })
        let result = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        guard case .stale(let shown, _, .failed(let message)) = result else {
            Issue.record("expected stale (failed), got \(result)")
            return
        }
        #expect(shown == first && !message.isEmpty)
    }

    /// A topic tombstone takes its cached stats with it.
    @Test func aDeletedTopicsRowsGo() async throws {
        let h = try Harness()
        h.answer(try Self.body("stats everything all"))
        _ = await h.loader.stats(topicId: Self.topicId, ref: "everything", query: Self.thirtyDays)
        try await h.store.writer.write { db in
            try ServerLayer.applyDeletion(db, kind: .topic, id: Self.topicId, topicId: Self.topicId, seq: 1)
        }
        #expect(try h.rows().isEmpty)
    }
}
