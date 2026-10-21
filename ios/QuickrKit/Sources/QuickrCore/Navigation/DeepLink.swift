import Foundation

/// PWA paths and `quickr://` URLs ↔ `Route`s. A path is the PWA's own (`/t/water/record`); the
/// app's URL for it is `quickr://t/water/record` (`quickr:///t/water/record` works too). A link
/// to the configured server's PWA (`https://quickr.example.com/t/water`) opens the same screen.
///
/// A parse gives the navigation stack to show above the topic list: `[]` is the list itself,
/// one route otherwise (back returns to the list, like the PWA's back button with no history).
/// Anything the PWA wouldn't route, or with a malformed slug or id, is nil. Query parameters
/// other than the record screen's `fix` and the app's `scope` are ignored (the PWA's list and
/// chart filters).
///
/// **Provenance** (notifications.md §7.5): a link quickR makes for a widget names the store it
/// was read from, `scope={server_id}/{store_gen}`, and its topic by id
/// (`quickr://t/{topic_id}/record?scope=…`), so the app can refuse it once another server or
/// store is active instead of opening that one's same-slug topic. A link without a scope (the
/// PWA's, a typed one) opens against the active server, as before.
public enum DeepLink {
    public static let scheme = "quickr"

    /// The longest outbox item id `fix=` accepts.
    static let maxFixLength = 64
    /// What `fix=` writes unescaped: the characters an outbox item id has.
    private static let fixAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// The stack a PWA path opens, or nil. `path` may carry a query: `/t/water/record?fix=…`.
    public static func routes(forPath path: String) -> [Route]? {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = parts.count == 2 ? URLComponents(string: "?" + parts[1])?.queryItems ?? [] : []
        return routes(path: String(parts[0]), query: query)
    }

    /// The stack a `quickr://` URL opens, or an http(s) URL under `serverURL` (its path prefix
    /// respected). Nil for other URLs and for paths quickR doesn't have.
    public static func routes(for url: URL, serverURL: URL? = nil) -> [Route]? {
        link(for: url, serverURL: serverURL)?.routes
    }

    /// A parsed link: its stack, and the store it names (`scope=`), if any.
    public struct Link: Sendable, Hashable {
        public var routes: [Route]
        public var scope: EntryScope?

        public init(routes: [Route], scope: EntryScope?) {
            self.routes = routes
            self.scope = scope
        }
    }

    /// `routes(for:serverURL:)` with the link's `scope` (a `quickr://` link's only: a server's
    /// PWA link is that server's by its address). A malformed scope makes the link nil.
    public static func link(for url: URL, serverURL: URL? = nil) -> Link? {
        guard let routes = parse(url, serverURL: serverURL) else { return nil }
        guard url.scheme?.lowercased() == scheme,
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "scope" })?.value
        else { return Link(routes: routes, scope: nil) }
        let scope = EntryScope(raw)
        guard !scope.serverId.isEmpty, scope.storeGen != nil, isScopeServer(scope.serverId) else { return nil }
        return Link(routes: routes, scope: scope)
    }

    /// The app's URL for a route, naming the store it belongs to:
    /// `quickr://t/{topic_id}/record?scope={server_id}/{store_gen}`.
    public static func url(for route: Route, scope: EntryScope) -> URL {
        var components = URLComponents(url: url(for: route), resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "scope", value: scope.id)]
        return components.url ?? url(for: route)
    }

    private static func parse(_ url: URL, serverURL: URL?) -> [Route]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), components.user == nil, components.password == nil
        else { return nil }
        let query = components.queryItems ?? []
        switch scheme {
        case Self.scheme:
            guard components.port == nil else { return nil }
            let host = components.host ?? ""
            let path = host.isEmpty ? components.percentEncodedPath : "/" + host + components.percentEncodedPath
            return routes(path: path, query: query)
        case "http", "https":
            guard let serverURL, let base = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
                base.scheme?.lowercased() == scheme, base.host?.lowercased() == components.host?.lowercased(),
                effectivePort(base) == effectivePort(components)
            else { return nil }
            let prefix =
                base.percentEncodedPath.hasSuffix("/")
                ? String(base.percentEncodedPath.dropLast()) : base.percentEncodedPath
            let path = components.percentEncodedPath
            guard path == prefix || path.hasPrefix(prefix + "/") || (prefix.isEmpty && path.isEmpty) else {
                return nil
            }
            return routes(path: String(path.dropFirst(prefix.count)), query: query)
        default:
            return nil
        }
    }

    /// The PWA path for a route: `/t/water/record`, `/t/water/record?fix=abc`.
    public static func path(for route: Route) -> String {
        switch route {
        case .settings: return "/settings"
        case .newTopic: return "/new"
        case .topic(let ref, .overview): return "/t/\(ref)"
        case .topic(let ref, let tab): return "/t/\(ref)/\(tab.rawValue)"
        case .record(let ref, let fix):
            let fixQuery = fix.map { "?fix=\($0.addingPercentEncoding(withAllowedCharacters: fixAllowed) ?? $0)" }
            return "/t/\(ref)/record" + (fixQuery ?? "")
        case .entry(let ref, let entryId): return "/t/\(ref)/entries/\(entryId.uuidString.lowercased())"
        case .editQuestions(let ref): return "/t/\(ref)/edit"
        case .topicSettings(let ref): return "/t/\(ref)/settings"
        }
    }

    /// The app's URL for a route (`quickr://t/water/record`), or for the topic list (`quickr://`).
    public static func url(for route: Route?) -> URL {
        let path = route.map(path(for:)) ?? "/"
        // Never fails: every path above is ASCII and already percent-encoded.
        return URL(string: "\(scheme):/" + path) ?? URL(string: "\(scheme)://")!
    }

    // MARK: - Parsing

    private static func routes(path rawPath: String, query: [URLQueryItem]) -> [Route]? {
        var path = rawPath
        if path.isEmpty || path == "/" { return [] }
        guard path.hasPrefix("/") else { return nil }
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // An empty segment ("//") never matches: not a slug, an id or a page name.
        let raw = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        var segments: [String] = []
        for segment in raw {
            guard let decoded = segment.removingPercentEncoding else { return nil }
            segments.append(decoded)
        }
        guard let route = route(segments, query: query) else { return nil }
        return [route]
    }

    private static func route(_ segments: [String], query: [URLQueryItem]) -> Route? {
        switch segments.first {
        case "settings" where segments.count == 1: return .settings
        case "new" where segments.count == 1: return .newTopic
        case "t":
            guard segments.count >= 2, let ref = TopicLinkRef(segments[1]) else { return nil }
            return topicRoute(ref, Array(segments.dropFirst(2)), query: query)
        default: return nil
        }
    }

    private static func topicRoute(_ ref: TopicLinkRef, _ rest: [String], query: [URLQueryItem]) -> Route? {
        switch rest.count {
        case 0: return .topic(ref, .overview)
        case 1:
            switch rest[0] {
            case "entries", "sessions": return .topic(ref, .entries)  // `sessions`: pre-v2 URLs
            case "versions": return .topic(ref, .versions)
            case "record":
                guard let fix = query.first(where: { $0.name == "fix" })?.value else { return .record(ref) }
                return isFixId(fix) ? .record(ref, fix: fix) : nil
            case "edit": return .editQuestions(ref)
            case "settings": return .topicSettings(ref)
            default: return nil
            }
        case 2:
            guard rest[0] == "entries" || rest[0] == "sessions", let id = UUID(uuidString: rest[1]) else { return nil }
            return .entry(ref, entryId: id)
        default: return nil
        }
    }

    /// An outbox item id: 1–64 of `[A-Za-z0-9_-]`.
    private static func isFixId(_ s: String) -> Bool {
        (1...maxFixLength).contains(s.utf8.count)
            && s.utf8.allSatisfy { b in
                (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x2D
                    || b == 0x5F
            }
    }

    /// A server id as the registry has it: 1–64 of `[A-Za-z0-9_-]`.
    private static func isScopeServer(_ s: String) -> Bool { isFixId(s) }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
