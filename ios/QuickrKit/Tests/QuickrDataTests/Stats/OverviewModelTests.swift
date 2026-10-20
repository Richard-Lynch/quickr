import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
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
            topicId: StatsLoaderTests.topicId, ref: "everything", timeZone: TimeZone(identifier: zone)!,
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
