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

    /// Shows `routes` (and hands `prefill` to their record screen) when `serverId` (and
    /// `storeGen`, when the link names one) is the active store's; otherwise says why not, and has
    /// the widgets refresh when the link's store is gone. Returns whether it opened.
    @discardableResult
    func openScoped(
        _ routes: [Route], serverId: String, storeGen: Int?, prefill: NotificationPrefill? = nil
    ) async -> Bool {
        // Checked against the bound store, not one a starting session hasn't bound yet (a cold
        // launch from a widget or a notification).
        await startSettled()
        guard let session else { return false }
        // A switch or a reset during the check is checked again; the route is set with no
        // suspension after the binding was last confirmed.
        let bound: @MainActor () -> EntryScope? = { [weak self] in
            self?.session === session ? session.binding?.scope : nil
        }
        let check = await LinkScope.open(
            serverId: serverId, storeGen: storeGen, binding: bound, registry: session.partitions.registry
        ) {
            recordPrefill = prefill
            router.path = routes
        }
        guard check != .open else { return true }
        router.refusedLink = LinkScope.message(check)
        if check == .stale { WidgetCenter.shared.reloadAllTimelines() }
        return false
    }
}
