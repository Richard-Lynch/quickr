import Foundation

/// Errors from the store layer.
public enum StoreError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The file has migrations this build doesn't know (it was written by a newer build).
    case schemaTooNew([String])
    case coordinationFailed(String)
    /// The store file has been retired by a reset (sync-protocol.md §12). Reopen through the
    /// registry and retry there.
    case retired
    /// No `server` row for this id in the registry.
    case unknownServer(String)
    /// The store has no `sync_state` row yet.
    case notBootstrapped
    /// A lease was requested out of the global order (§5.2): `flush` is held and `sync` was asked.
    case lockOrderViolation(acquiring: LeaseName, holding: LeaseName)
    /// A stored row didn't decode.
    case corruptRow(String)
    /// The registry row changed under a conditional step (another process advanced or started a
    /// reset). Re-read the registry and retry.
    case registryChanged(String)

    public var description: String {
        switch self {
        case .schemaTooNew(let ids): "store schema is newer than this build: \(ids.sorted())"
        case .coordinationFailed(let path): "file coordination failed for \(path)"
        case .retired: "store file is retired"
        case .unknownServer(let id): "no registered server \(id)"
        case .notBootstrapped: "store has no sync_state"
        case .lockOrderViolation(let acquiring, let holding):
            "lock order: can't acquire \(acquiring.rawValue) while holding \(holding.rawValue)"
        case .corruptRow(let message): "corrupt row: \(message)"
        case .registryChanged(let id): "registry changed for server \(id)"
        }
    }
}
