import Foundation
import QuickrCore
import Testing

private let water = TopicLinkRef("water")!
private let topicId = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
private let entryId = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

/// Every PWA route (`frontend/src/router.tsx`) with its canonical path.
private let pwaPaths: [(String, [Route])] = [
    ("/", []),
    ("/settings", [.settings]),
    ("/new", [.newTopic]),
    ("/t/water", [.topic(water, .overview)]),
    ("/t/water/entries", [.topic(water, .entries)]),
    ("/t/water/versions", [.topic(water, .versions)]),
    ("/t/water/record", [.record(water)]),
    (
        "/t/water/record?fix=7c9e6679-7425-40de-944b-e07fc1f90ae7",
        [.record(water, fix: "7c9e6679-7425-40de-944b-e07fc1f90ae7")]
    ),
    ("/t/water/entries/6ba7b810-9dad-11d1-80b4-00c04fd430c8", [.entry(water, entryId: entryId)]),
    ("/t/water/edit", [.editQuestions(water)]),
    ("/t/water/settings", [.topicSettings(water)]),
    ("/t/3f2504e0-4f89-11d3-9a0c-0305e82c3301/record", [.record(TopicLinkRef(id: topicId))]),
]

@Suite struct DeepLinkTests {
    @Test(arguments: pwaPaths.map(\.0))
    func everyPWAPathParsesAndRoundTrips(_ path: String) throws {
        let expected = try #require(pwaPaths.first { $0.0 == path }?.1)
        #expect(DeepLink.routes(forPath: path) == expected)
        guard let route = expected.first else { return }
        // Path → route → path, and route → quickr:// URL → route.
        #expect(DeepLink.path(for: route) == path)
        let url = DeepLink.url(for: route)
        #expect(url.absoluteString == "quickr:/" + path)
        #expect(DeepLink.routes(for: url) == expected)
    }

    @Test func everyRouteRoundTripsThroughItsURL() {
        let routes: [Route] =
            [
                .settings, .newTopic, .record(water), .record(water, fix: "a_b-9"), .entry(water, entryId: entryId),
                .editQuestions(water), .topicSettings(water),
            ] + TopicTab.allCases.map { .topic(water, $0) }
        for route in routes {
            #expect(DeepLink.routes(for: DeepLink.url(for: route)) == [route], "\(route)")
            #expect(DeepLink.routes(forPath: DeepLink.path(for: route)) == [route], "\(route)")
        }
        #expect(DeepLink.url(for: nil).absoluteString == "quickr://")
        #expect(DeepLink.routes(for: DeepLink.url(for: nil)) == [])
    }

    @Test func quickrURLForms() {
        let record: [Route] = [.record(water)]
        #expect(DeepLink.routes(for: URL(string: "quickr://t/water/record")!) == record)
        #expect(DeepLink.routes(for: URL(string: "quickr:///t/water/record")!) == record)
        #expect(DeepLink.routes(for: URL(string: "QUICKR://t/water/record/")!) == record)
        #expect(DeepLink.routes(for: URL(string: "quickr://settings")!) == [.settings])
        #expect(DeepLink.routes(for: URL(string: "quickr:///")!) == [])
        // Filters the PWA keeps in the query are ignored.
        #expect(DeepLink.routes(for: URL(string: "quickr://t/water?range=7d")!) == [.topic(water, .overview)])
        #expect(DeepLink.routes(for: URL(string: "quickr://?status=archived")!) == [])
        // An encoded slug decodes; an uppercase id is the same topic.
        #expect(DeepLink.routes(forPath: "/t/wat%65r") == [.topic(water, .overview)])
        #expect(
            DeepLink.routes(forPath: "/t/3F2504E0-4F89-11D3-9A0C-0305E82C3301") == [
                .topic(TopicLinkRef(id: topicId), .overview)
            ])
    }

    @Test func preV2SessionsURLsOpenTheEntries() {
        #expect(DeepLink.routes(forPath: "/t/water/sessions") == [.topic(water, .entries)])
        #expect(
            DeepLink.routes(forPath: "/t/water/sessions/6ba7b810-9dad-11d1-80b4-00c04fd430c8") == [
                .entry(water, entryId: entryId)
            ])
    }

    @Test func linksToTheConfiguredServerOpenTheSameScreen() {
        let server = URL(string: "https://quickr.example.com")!
        #expect(
            DeepLink.routes(for: URL(string: "https://quickr.example.com/t/water/record")!, serverURL: server) == [
                .record(water)
            ])
        #expect(
            DeepLink.routes(for: URL(string: "https://QUICKR.example.com:443/settings")!, serverURL: server) == [
                .settings
            ])
        #expect(DeepLink.routes(for: URL(string: "https://quickr.example.com")!, serverURL: server) == [])
        // Under a path prefix (a reverse proxy), only paths below it.
        let prefixed = URL(string: "http://nas.local:8100/quickr/")!
        #expect(
            DeepLink.routes(for: URL(string: "http://nas.local:8100/quickr/t/water")!, serverURL: prefixed) == [
                .topic(water, .overview)
            ])
        #expect(DeepLink.routes(for: URL(string: "http://nas.local:8100/quickr")!, serverURL: prefixed) == [])
        #expect(DeepLink.routes(for: URL(string: "http://nas.local:8100/quickrx/t/water")!, serverURL: prefixed) == nil)
        #expect(DeepLink.routes(for: URL(string: "http://nas.local:8100/t/water")!, serverURL: prefixed) == nil)
        // Another host, port or scheme, or no server configured: not ours.
        #expect(DeepLink.routes(for: URL(string: "https://evil.example.com/t/water")!, serverURL: server) == nil)
        #expect(DeepLink.routes(for: URL(string: "https://quickr.example.com:8443/t/water")!, serverURL: server) == nil)
        #expect(DeepLink.routes(for: URL(string: "http://quickr.example.com/t/water")!, serverURL: server) == nil)
        #expect(DeepLink.routes(for: URL(string: "https://quickr.example.com/t/water")!) == nil)
    }

    @Test(arguments: [
        "t/water",  // not absolute
        "/t", "/t/", "/t//record", "/t/water//record",
        "/t/Water", "/t/-water", "/t/water_1", "/t/\(String(repeating: "a", count: 65))", "/t/wa%2Fter",
        "/t/water/record/extra", "/t/water/entries/not-a-uuid", "/t/water/entries/123", "/t/water/overview",
        "/t/water/unknown", "/settings/x", "/new/x", "/topics/water", "/api/v1/topics", "/T/water",
        "/t/water/record?fix=", "/t/water/record?fix=a%20b", "/t/water/record?fix=\(String(repeating: "f", count: 65))",
        "/t/%E0%A4%A", "/%", "//settings", "/t/water/entries//", "/settings//",
    ])
    func junkIsRejected(_ path: String) {
        #expect(DeepLink.routes(forPath: path) == nil)
    }

    @Test func junkURLsAreRejected() {
        for raw in [
            "https://quickr.example.com/t/water", "mailto:someone@example.com", "quickr://user@t/water",
            "quickr://t:80/water", "quickr://t/water/nope", "file:///t/water", "quickrx://t/water",
        ] {
            #expect(DeepLink.routes(for: URL(string: raw)!) == nil, "\(raw)")
        }
    }

    @Test func topicLinkRefs() {
        #expect(TopicLinkRef("a")?.rawValue == "a")
        #expect(TopicLinkRef("0-run")?.rawValue == "0-run")
        #expect(TopicLinkRef(String(repeating: "a", count: 64)) != nil)
        #expect(TopicLinkRef("3F2504E0-4F89-11D3-9A0C-0305E82C3301")?.id == topicId)
        #expect(
            TopicLinkRef("3F2504E0-4F89-11D3-9A0C-0305E82C3301")?.rawValue == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        for bad in ["", "-a", "A", "a b", "a_b", "é", String(repeating: "a", count: 65)] {
            #expect(TopicLinkRef(bad) == nil, "\(bad)")
        }
        #expect(Route.record(water).topic == water)
        #expect(Route.settings.topic == nil)
    }

    // MARK: - Provenance (notifications.md §7.5)

    @Test func aLinkCanNameItsStore() throws {
        let scope = EntryScope(serverId: "0b9e0000-0000-4000-8000-0000000000aa", storeGen: 3)
        let url = DeepLink.url(for: .record(TopicLinkRef(id: topicId)), scope: scope)
        #expect(url.absoluteString == "quickr://t/\(topicId.uuidString.lowercased())/record?scope=\(scope.id)")
        let link = try #require(DeepLink.link(for: url))
        #expect(link.routes == [.record(TopicLinkRef(id: topicId))])
        #expect(link.scope == scope && link.scope?.serverId == scope.serverId && link.scope?.storeGen == 3)
        // routes(for:) still reads it, without the scope; a fix keeps its query.
        #expect(DeepLink.routes(for: url) == [.record(TopicLinkRef(id: topicId))])
        let fix = DeepLink.url(for: .record(water, fix: "abc"), scope: scope)
        #expect(DeepLink.link(for: fix) == DeepLink.Link(routes: [.record(water, fix: "abc")], scope: scope))
    }

    @Test func aLinkWithoutAScopeIsTheActiveServers() throws {
        #expect(DeepLink.link(for: URL(string: "quickr://t/water/record")!)?.scope == nil)
        // A server's PWA link is that server's by its address; a scope on it isn't read.
        let server = URL(string: "https://quickr.example")!
        let pwa = try #require(
            DeepLink.link(for: URL(string: "https://quickr.example/t/water/record?scope=x/1")!, serverURL: server))
        #expect(pwa.scope == nil && pwa.routes == [.record(water)])
    }

    @Test func aMalformedScopeOpensNothing() {
        for bad in ["", "server", "server/", "/1", "server/x", "ser ver/1", "a/b/c"] {
            var components = URLComponents(string: "quickr://t/water/record")!
            components.queryItems = [URLQueryItem(name: "scope", value: bad)]
            #expect(DeepLink.link(for: components.url!) == nil, "\(bad)")
        }
    }

    @Test func aRouteCanNameItsTopicById() {
        let id = TopicLinkRef(id: topicId)
        #expect(Route.record(water, fix: "f").with(topic: id) == .record(id, fix: "f"))
        #expect(Route.topic(water, .entries).with(topic: id) == .topic(id, .entries))
        #expect(Route.settings.with(topic: id) == .settings)
    }
}
