import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// PERF: the paths a heavy user waits on, over the 10,000-entry seed (`PerfSeed`). Real time, so
/// they run alone (`make ios-timing-test`). The bounds are ceilings with room for a loaded Mac and
/// a debug build; each test prints what it measured. The simulator's cold start to the first Home
/// render (target < 1 s) is `PerfLaunchUITests`; device numbers come at M4-DEV.
extension TimingTests {
    @MainActor @Suite struct Perf {
        /// A seeded store, and a session over it that can't reach the server (the network never
        /// gates a first render).
        struct World {
            let directory: TempDirectory
            let location: StoreLocation

            init() async throws {
                directory = try TempDirectory()
                location = StoreLocation(root: directory.url)
                _ = try await PerfSeed.seed(at: location)
            }

            @MainActor func session() throws -> AppSession {
                let offline = FakeTransport()
                offline.stub(where: { _ in true }, { _ in throw TransportError.unreachable("perf: offline") })
                return try AppSession(
                    configuration: .init(
                        location: location, transport: offline, notifier: nil,
                        notificationCenter: NotificationCenter()))
            }
        }

        static func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("timed out waiting until \(what)")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        /// Launch to the first Home render's data: the session opens the registry and the active
        /// store and binds, then Home's first observation delivers every topic with its derived
        /// fields (entry counts, last capture, due).
        @Test func coldStartToHomesFirstTopics() async throws {
            let world = try await World()
            defer { world.directory.cleanup() }
            let clock = ContinuousClock()
            let start = clock.now
            let session = try world.session()
            await session.start()
            let bound = clock.now - start
            let home = HomeModel(session: session, debounce: .zero)
            let observing = Task { await home.observe() }
            try await Self.waitUntil("Home has its topics") { home.topics.count == 20 }
            let elapsed = clock.now - start
            observing.cancel()
            print("PERF cold start: bound in \(bound), Home's 20 topics in \(elapsed)")
            #expect(home.topics.contains { $0.topic.entryCount > 2_500 }, "derived counts are there")
            #expect(elapsed < .seconds(1), "cold start to Home's data took \(elapsed)")
            await session.shutdown()
        }

        /// The busiest topic's entries (about 2,800, plus the pinned unsynced ones).
        @Test func theBusiestTopicsEntryList() async throws {
            let world = try await World()
            defer { world.directory.cleanup() }
            let session = try world.session()
            await session.start()
            let busiest = PerfSeed.topic(0, spec: .standard)
            let clock = ContinuousClock()
            let start = clock.now
            let model = EntriesModel(session: session, topicRef: busiest.slug, now: PerfSeed.Spec.standard.now)
            model.filters.range = .all
            let observing = Task { await model.observe() }
            try await Self.waitUntil("the list has its rows") { model.loaded && !model.rows.isEmpty }
            let elapsed = clock.now - start
            observing.cancel()
            print("PERF entries list: \(model.rows.count) rows, \(model.pinned.count) pinned in \(elapsed)")
            #expect(model.rows.count > 2_500)
            #expect(elapsed < .seconds(1), "the busiest topic's list took \(elapsed)")
            await session.shutdown()
        }

        /// A topic's Overview: the stats and three 400-point series fetched and cached, then the
        /// same read back offline from the cache.
        @Test func statsFreshThenCached() async throws {
            let world = try await World()
            defer { world.directory.cleanup() }
            let partitions = try StorePartitions.open(at: world.location, notifier: nil)
            let store = try #require(try await partitions.openActiveStoreIfExists())
            let cases = try JSONDecoder().decode(
                StatsChartVectorTests.Input.self, from: Fixtures.data("stats-vectors.json")
            ).cases
            func body(_ name: String) throws -> Data {
                try JSONEncoder().encode(try #require(cases.first { $0.name == name }).response)
            }
            let transport = FakeTransport()
            let stats = try body("stats many all")
            let series = try ["n", "d", "c"].map { try body("series many \($0) day") }
            let headers: HTTPHeaders = [
                QuickrHeader.serverId: PerfSeed.Spec.standard.serverId,
                QuickrHeader.epoch: PerfSeed.Spec.standard.epoch,
            ]
            transport.stub(
                where: { _ in true },
                { request in
                    let path = request.url.path
                    let index = ["/n/", "/d/", "/c/"].firstIndex { path.contains($0) }
                    return HTTPResponse(status: 200, headers: headers, body: index.map { series[$0] } ?? stats)
                })
            let client = APIClient(
                baseURL: URL(string: "https://quickr.test")!, transport: transport, identity: StaticServerIdentity(nil))
            let loader = StatsLoader(store: store, client: client, requestSync: {})
            let topicId = PerfSeed.topicId(0)
            let query = StatsQuery(cacheKey: "range=all", filters: EntryFilters())
            let clock = ContinuousClock()
            let fresh = try await clock.measure {
                let model = OverviewModel(topicId: topicId, ref: "many", loader: { loader })
                await model.load(query: query, bucket: .day)
                guard case .loaded(_, .fresh) = model.stats else { throw CancellationError() }
            }
            transport.reset()
            transport.stub(where: { _ in true }, { _ in throw TransportError.unreachable("offline") })
            let cached = try await clock.measure {
                let model = OverviewModel(topicId: topicId, ref: "many", loader: { loader })
                await model.load(query: query, bucket: .day)
                guard case .loaded(_, .stale) = model.stats, model.series.count == 3 else { throw CancellationError() }
            }
            print("PERF stats: fresh (fetch, decode, cache) \(fresh), offline from the cache \(cached)")
            #expect(fresh < .seconds(1) && cached < .seconds(1), "fresh \(fresh), cached \(cached)")
        }

        /// The Notification Service Extension's work on a due reminder: open the registry and the
        /// active store read-only, reconcile and register the category, check for an unsynced
        /// entry and count the due topics for the badge. The NSE has about 30 s and 24 MB.
        @Test func theNotificationServicePath() async throws {
            let world = try await World()
            defer { world.directory.cleanup() }
            let location = world.location
            let topic = PerfSeed.topic(0, spec: .standard)
            let center = FakeNotificationCenter()
            let now = PerfSeed.Spec.standard.now
            let preparation = NotificationPreparation(
                center: center, registry: { try Registry.open(at: location, notifier: nil) },
                activeStore: { try ReadOnlyStores(location: location).activeStore() }, now: { now })
            let reminder = QuickrNotificationInfo(
                v: 1, kind: "due", origin: .remote, serverId: PerfSeed.Spec.standard.serverId,
                topicId: topic.id.wireString,
                topicSlug: topic.slug, version: topic.currentVersion,
                dueSince: ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)),
                url: "/t/\(topic.slug)/record",
                quickLog: .choice(
                    .init(
                        key: "severity", label: "Severity",
                        options: [
                            .init(value: "none", label: "None"), .init(value: "mild", label: "Mild"),
                            .init(value: "severe", label: "Severe"),
                        ],
                        totalOptions: 3)))
            let clock = ContinuousClock()
            var prepared: NotificationPreparation.Prepared?
            let elapsed = await clock.measure {
                prepared = await preparation.prepare(
                    .init(id: "perf", body: "Time for Headache 1", categoryIdentifier: "", quickr: reminder))
            }
            print("PERF NSE: prepared in \(elapsed), badge \(String(describing: prepared?.badge))")
            #expect(prepared?.badge != nil, "the active store was read")
            #expect(elapsed < .seconds(2), "the NSE path took \(elapsed)")
        }
    }
}
