import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// `OverviewModel` over a real `StatsLoader` and store, answering with `stats-vectors.json`.
@MainActor @Suite struct OverviewModelTests {
    typealias Harness = StatsLoaderTests.Harness

    /// Answers each request with the vector response for the same path and query.
    nonisolated static func serve(_ h: Harness, epoch: String = "E1") {
        h.transport.reset()
        h.transport.stub(
            where: { _ in true },
            { request in
                let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                var query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
                query.removeValue(forKey: "captured_from")
                let parts = request.url.pathComponents  // ["/", "api", "v1", "topics", ref, ...]
                let topic = parts[4]
                let match = StatsLoaderTests.input.cases.first { c in
                    c.topic == topic && c.query == query
                        && (parts.count == 6 ? c.kind == "stats" : c.kind == "series" && c.question == parts[6])
                }
                guard let match else { return HTTPResponse(status: 404, headers: identity(epoch)) }
                return HTTPResponse(
                    status: 200, headers: identity(epoch), body: try JSONEncoder().encode(match.response))
            })
    }

    nonisolated static func identity(_ epoch: String) -> HTTPHeaders {
        [QuickrHeader.serverId: "server-1", QuickrHeader.epoch: epoch]
    }

    static let query = StatsQuery(cacheKey: "range=all", filters: EntryFilters())

    /// Not "UTC": Foundation names that zone "GMT", which the fixtures don't have.
    func model(_ h: Harness, zone: String = "Europe/London") -> OverviewModel {
        let loader = h.loader
        return OverviewModel(
            topicId: StatsLoaderTests.topicId, ref: "everything", timeZone: { TimeZone(identifier: zone)! },
            loader: { loader })
    }

    @Test func loadsTheStatsTheSourcesAndEachChartableSeries() async throws {
        let h = try Harness()
        Self.serve(h)
        let model = model(h, zone: "Europe/London")
        await model.load(query: Self.query, bucket: .week)
        guard case .loaded(let stats, .fresh) = model.stats else {
            Issue.record("expected fresh stats, got \(model.stats)")
            return
        }
        #expect(stats.entryCount == 12)
        #expect(model.sources == ["ios", "web", "mcp"])
        // int, double and enum questions have a series; the str one doesn't.
        #expect(Set(model.series.keys) == ["glasses", "hours", "mood", "tags", "old"])
        for (key, load) in model.series {
            guard case .loaded(let series, .fresh) = load else {
                Issue.record("\(key): \(load)")
                continue
            }
            #expect(series.bucket == .week && series.key == key)
        }
        // Series are bucketed in the reader's zone.
        let request = try #require(h.transport.requests.first { $0.url.path.hasSuffix("/glasses/series") })
        #expect(request.url.query?.contains("tz=Europe/London") == true)
    }

    @Test func offlineTheCachedAnswersShowStale() async throws {
        let h = try Harness()
        Self.serve(h)
        let model = model(h)
        await model.load(query: Self.query, bucket: .day)
        let fetchedAt = h.wall.now()
        h.wall.advance(by: 3600)
        h.offline()
        let later = self.model(h)
        await later.load(query: Self.query, bucket: .day)
        guard case .loaded(_, .stale(let at, .offline)) = later.stats else {
            Issue.record("expected stale stats, got \(later.stats)")
            return
        }
        #expect(at == fetchedAt)
        #expect(
            later.series.values.allSatisfy {
                if case .loaded(_, .stale(fetchedAt, .offline)) = $0 { true } else { false }
            })
        // A bucket never fetched: the stats show, its series can't.
        await later.load(query: Self.query, bucket: .month)
        #expect(later.stats.value != nil)
        #expect(later.series.values.allSatisfy { if case .unavailable(.offline) = $0 { true } else { false } })
    }

    /// A cancelled reload (SwiftUI ends a refresh, the view goes away) leaves what was on screen;
    /// its failed reads don't turn into errors.
    @Test func aCancelledReloadKeepsWhatWasShown() async throws {
        let h = try Harness()
        Self.serve(h)
        let model = model(h)
        await model.load(query: Self.query, bucket: .day)
        let stats = try #require(model.stats.value)
        let series = model.series.mapValues(\.value)
        h.offline()
        let reload = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(query: Self.query, bucket: .day)
        }
        await reload.value
        guard case .loaded(let shown, .fresh) = model.stats else {
            Issue.record("expected the fresh stats still, got \(model.stats)")
            return
        }
        #expect(shown == stats)
        #expect(model.series.mapValues(\.value) == series)
        #expect(model.series.values.allSatisfy { if case .loaded(_, .fresh) = $0 { true } else { false } })
    }

    /// A rebind while a refresh is in flight: the old store's answer is not published (what was
    /// on screen stays), even though it arrives.
    @Test func aRebindMidRefreshPublishesNothing() async throws {
        let a = try Harness()
        let b = try Harness(serverId: "server-2")
        Self.serve(a)
        let rebound = Mutex(false)
        let loaders = (a.loader, b.loader)
        let model = OverviewModel(
            topicId: StatsLoaderTests.topicId, ref: "everything", timeZone: { TimeZone(identifier: "Europe/London")! },
            loader: { rebound.withLock { $0 } ? loaders.1 : loaders.0 })
        await model.load(query: Self.query, bucket: .day)
        let stats = try #require(model.stats.value)
        let series = model.series.mapValues(\.value)
        // The refresh's request is answered (with other stats) as the session rebinds.
        let other = try StatsLoaderTests.body("stats everything source web")
        a.transport.reset()
        a.transport.stub(
            where: { _ in true },
            { _ in
                rebound.withLock { $0 = true }
                return HTTPResponse(status: 200, headers: Self.identity("E1"), body: other)
            })
        await model.load(query: Self.query, bucket: .day)
        guard case .loaded(let shown, .fresh) = model.stats else {
            Issue.record("expected the earlier stats, got \(model.stats)")
            return
        }
        #expect(shown == stats)
        #expect(model.series.mapValues(\.value) == series)
        #expect(b.transport.requests.isEmpty)
    }

    /// The device's zone changes while the screen is open: the next load asks for, and reads the
    /// cache under, the new zone. Offline, a chart cached only for the old zone says why it can't
    /// show.
    @Test func aZoneChangeReachesTheSameModel() async throws {
        let h = try Harness()
        Self.serve(h)
        let zone = Mutex("Europe/London")
        let loader = h.loader
        let model = OverviewModel(
            topicId: StatsLoaderTests.topicId, ref: "everything",
            timeZone: { TimeZone(identifier: zone.withLock { $0 })! }, loader: { loader })
        await model.load(query: Self.query, bucket: .day)
        #expect(model.series["glasses"]?.value != nil)

        zone.withLock { $0 = "America/Santiago" }
        h.offline()
        await model.load(query: Self.query, bucket: .day)
        guard case .unavailable(.zoneChanged) = model.series["glasses"] else {
            Issue.record("expected zoneChanged, got \(String(describing: model.series["glasses"]))")
            return
        }

        Self.serve(h)
        await model.load(query: Self.query, bucket: .day)
        let request = try #require(h.transport.requests.last { $0.url.path.hasSuffix("/glasses/series") })
        #expect(request.url.query?.contains("tz=America/Santiago") == true)
        let santiago = try StatsLoaderTests.response(
            QuestionSeriesDTO.self, "series everything glasses day America/Santiago")
        #expect(model.series["glasses"]?.value == santiago)
    }

    /// Two loads of the same query overlap (the first load and a pull to refresh) and the older one
    /// finishes last: only the newer one's answer shows.
    @Test func anOlderIdenticalLoadFinishingLastPublishesNothing() async throws {
        let h = try Harness()
        let gate = StatsGate()
        let older = try StatsLoaderTests.body("stats everything source web")
        let newer = try StatsLoaderTests.body("stats everything all")
        let loader = StatsLoader(
            store: h.store,
            client: APIClient(baseURL: StatsLoaderTests.base, transport: gate, identity: StaticServerIdentity(nil)),
            requestSync: {})
        let model = OverviewModel(
            topicId: StatsLoaderTests.topicId, ref: "everything", timeZone: { TimeZone(identifier: "Europe/London")! },
            loader: { loader })
        // Each load sends two stats requests (the query's and the sources'); series are answered.
        let first = Task { @MainActor in await model.load(query: Self.query, bucket: .day) }
        try await eventually("the first load's requests wait") { gate.waiting == 2 }
        let second = Task { @MainActor in await model.load(query: Self.query, bucket: .day) }
        try await eventually("the second load's requests wait") { gate.waiting == 4 }
        gate.release(last: 2, body: newer)
        await second.value
        let shown = try #require(model.stats.value)
        gate.release(last: 2, body: older)
        await first.value
        #expect(model.stats.value == shown)
        #expect(shown.entryCount == 12)
    }

    /// A series whose own fetch failed shows its cached chart as stale, while the summary is fresh.
    @Test func aSeriesCanBeStaleWhileTheSummaryIsFresh() async throws {
        let h = try Harness()
        Self.serve(h)
        let model = model(h)
        await model.load(query: Self.query, bucket: .day)
        let served = h.transport
        let stats = try StatsLoaderTests.body("stats everything all")
        served.reset()
        served.stub(
            where: { $0.url.path.hasSuffix("/stats") },
            { _ in HTTPResponse(status: 200, headers: Self.identity("E1"), body: stats) })
        served.stub(
            where: { $0.url.path.hasSuffix("/series") },
            { _ in
                HTTPResponse(
                    status: 500, headers: Self.identity("E1"),
                    body: Data(#"{"code":"internal","detail":"boom","errors":[]}"#.utf8))
            })
        await model.load(query: Self.query, bucket: .day)
        guard case .loaded(_, .fresh) = model.stats else {
            Issue.record("expected fresh stats, got \(model.stats)")
            return
        }
        #expect(
            model.series.values.allSatisfy {
                if case .loaded(_, .stale(_, .failed)) = $0 { true } else { false }
            })
    }

    @Test func offlineWithNothingCachedIsUnavailable() async throws {
        let h = try Harness()
        h.offline()
        let model = model(h)
        await model.load(query: Self.query, bucket: .day)
        guard case .unavailable(.offline) = model.stats else {
            Issue.record("expected unavailable, got \(model.stats)")
            return
        }
        #expect(model.series.isEmpty)
    }

    @Test func withoutAServerNothingLoads() async {
        let model = OverviewModel(topicId: StatsLoaderTests.topicId, ref: "everything", loader: { nil })
        await model.load(query: Self.query, bucket: .day)
        guard case .unavailable(.failed) = model.stats else {
            Issue.record("expected unavailable, got \(model.stats)")
            return
        }
    }

    /// The server's data changed under the store: nothing from that answer shows.
    @Test func anotherEpochShowsNothingNew() async throws {
        let h = try Harness()
        Self.serve(h, epoch: "E2")
        let model = model(h)
        await model.load(query: Self.query, bucket: .day)
        guard case .unavailable(.resyncing) = model.stats else {
            Issue.record("expected resyncing, got \(model.stats)")
            return
        }
        #expect(h.syncsRequested >= 1)
    }
}

/// Holds `/stats` requests until released, answering the rest from `stats-vectors.json`.
final class StatsGate: Transport {
    private let state = Mutex<[CheckedContinuation<Data, Never>]>([])

    var waiting: Int { state.withLock { $0.count } }

    /// Answers the `count` most recent held requests with `body`.
    func release(last count: Int, body: Data) {
        let released = state.withLock { held in
            let tail = Array(held.suffix(count))
            held.removeLast(count)
            return tail
        }
        for continuation in released { continuation.resume(returning: body) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let headers: HTTPHeaders = [QuickrHeader.serverId: "server-1", QuickrHeader.epoch: "E1"]
        guard request.url.path.hasSuffix("/stats") else {
            let key = request.url.pathComponents.dropLast().last ?? ""
            let name = "series everything \(key) day Europe/London"
            let body = try StatsLoaderTests.body(name)
            return HTTPResponse(status: 200, headers: headers, body: body)
        }
        let body = await withCheckedContinuation { continuation in state.withLock { $0.append(continuation) } }
        return HTTPResponse(status: 200, headers: headers, body: body)
    }
}
