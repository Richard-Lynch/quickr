import Foundation
import QuickrCore

/// Whether a link that names its server opens (notifications.md §7.5): a reminder's body or
/// "More…" (its server), a widget's tap (its server and store generation). Only the active
/// server's links open; quickR never switches servers for a link.
public enum LinkScope {
    public enum Check: Sendable, Hashable {
        /// The active server's (and store's): open it, by topic id.
        case open
        /// Another registered server's: not opened. `name` says which, for the message.
        case otherServer(name: String)
        /// A server quickR doesn't have any more, or a store since reset: not opened; widgets are
        /// asked to refresh.
        case stale
    }

    /// The check for a link from `serverId` (and `storeGen`, when the link names one) while
    /// `active` is bound. The registry names another server.
    public static func check(
        serverId: String, storeGen: Int?, active: EntryScope?, registry: Registry
    ) async -> Check {
        if let active, active.serverId == serverId {
            guard let storeGen, storeGen != active.storeGen else { return .open }
            return .stale
        }
        guard let server = try? await registry.repository.server(id: serverId) else { return .stale }
        return .otherServer(name: name(of: server))
    }

    /// What the user calls a server: its name, else its address's host.
    static func name(of server: RegisteredServer) -> String {
        if let name = server.displayName, !name.isEmpty { return name }
        return URL(string: server.baseURL)?.host() ?? server.baseURL
    }

    /// What the app says when it doesn't open a link.
    public static func message(_ check: Check) -> String? {
        switch check {
        case .open: nil
        case .otherServer(let name):
            "This is from \(name), not the server quickR is using now. Switch to \(name) in Settings to open it."
        case .stale:
            "This is from a server or data quickR doesn't have any more. Your widgets will update."
        }
    }
}
