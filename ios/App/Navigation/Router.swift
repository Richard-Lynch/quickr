import Foundation
import Observation
import QuickrCore

/// Owns the root `NavigationStack`'s path of `Route`s (QuickrCore; one per PWA page) and opens
/// links: `quickr://` URLs, notifications' `/t/{slug}/record` paths and links to the server's PWA.
@MainActor @Observable
final class Router {
    var path: [Route] = [] {
        didSet { dropCarriedIfGone() }
    }
    /// The last link quickR couldn't open, until the root has said so.
    var unopenedLink: URL?

    /// Shows the screen `url` names, above the topic list (back returns to it). Returns false, and
    /// leaves the screen as it is, for a link quickR doesn't have.
    @discardableResult
    func handle(url: URL, serverURL: URL?) -> Bool {
        guard let routes = DeepLink.routes(for: url, serverURL: serverURL) else {
            unopenedLink = url
            return false
        }
        path = routes
        return true
    }

    /// A PWA path, as a notification carries it (`quickr.url`).
    @discardableResult
    func handle(path: String) -> Bool {
        guard let routes = DeepLink.routes(forPath: path) else { return false }
        self.path = routes
        return true
    }

    func open(_ route: Route) {
        path.append(route)
    }

    /// Swaps the top screen for `route` (a topic's tabs), so back still goes where it did.
    func replaceTop(with route: Route) {
        if path.isEmpty { path = [route] } else { path[path.count - 1] = route }
    }

    /// Swaps the top screen for `route` and hands `value` (a screen's model) to the screen at that
    /// path entry, if SwiftUI builds a new one for it (topic settings after a slug save).
    func replaceTop(with route: Route, carrying value: AnyObject) {
        replaceTop(with: route)
        carried = Carried(depth: path.count - 1, route: route, value: value)
    }

    /// What `replaceTop(with:carrying:)` handed to the screen at `route`; only while that entry is
    /// still on top of the path, and only once.
    func takeCarried(for route: Route) -> AnyObject? {
        guard let carried, carried.depth == path.count - 1, path.last == route, carried.route == route else {
            return nil
        }
        self.carried = nil
        return carried.value
    }

    private struct Carried {
        let depth: Int
        let route: Route
        let value: AnyObject
    }

    @ObservationIgnored private var carried: Carried?

    /// The entry left the path (back, a link): nothing is handed to a later screen.
    private func dropCarriedIfGone() {
        guard let carried else { return }
        if !path.indices.contains(carried.depth) || path[carried.depth] != carried.route { self.carried = nil }
    }
}
