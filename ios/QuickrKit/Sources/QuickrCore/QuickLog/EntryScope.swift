import Foundation

/// Which store a write or an outbox item belongs to: the server and its store generation
/// ("{server_id}/{store_gen}"). A toast's Undo, a `sendNow` and the sync sheet's actions act
/// only while it is still the active one, so a server switch or a reset in between never sends
/// them to another store. Not the base URL: a new address for the same server keeps the store.
public struct EntryScope: Sendable, Hashable {
    public var id: String

    public init(_ id: String) {
        self.id = id
    }

    public init(serverId: String, storeGen: Int) {
        self.init("\(serverId)/\(storeGen)")
    }
}
