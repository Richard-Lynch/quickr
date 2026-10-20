import Foundation
import Observation
import QuickrCore

/// Owns the root `NavigationStack`'s path of `Route`s (QuickrCore; one per PWA page) and opens
/// links: `quickr://` URLs, notifications' `/t/{slug}/record` paths and links to the server's PWA.
@MainActor @Observable
final class Router {
    var path: [Route] = []
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
}
