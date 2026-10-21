import Foundation
import QuickrCore
import QuickrData
import WidgetKit

extension AppEnvironment {
    /// A `quickr://` link or one to the server's PWA (`onOpenURL`, a UI test's launch link). A link
    /// that names its store (a widget's, notifications.md §7.5) opens only while that store is
    /// active; one without (the PWA's, a typed one) opens against the active server.
    func open(url: URL) {
        guard let link = DeepLink.link(for: url, serverURL: settings.serverURL) else {
            router.unopenedLink = url
            return
        }
        guard let scope = link.scope else {
            router.path = link.routes
            return
        }
        Task { await openScoped(link.routes, serverId: scope.serverId, storeGen: scope.storeGen) }
    }

    /// Shows `routes` when `serverId` (and `storeGen`, when the link names one) is the active
    /// store's; otherwise says why not, and has the widgets refresh when the link's store is gone.
    /// Returns whether it opened.
    @discardableResult
    func openScoped(_ routes: [Route], serverId: String, storeGen: Int?) async -> Bool {
        guard let session else { return false }
        let check = await LinkScope.check(
            serverId: serverId, storeGen: storeGen, active: session.binding?.scope,
            registry: session.partitions.registry)
        guard check == .open else {
            router.refusedLink = LinkScope.message(check)
            if check == .stale { WidgetCenter.shared.reloadAllTimelines() }
            return false
        }
        router.path = routes
        return true
    }
}
