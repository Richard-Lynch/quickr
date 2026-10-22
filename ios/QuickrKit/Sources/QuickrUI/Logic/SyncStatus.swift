/// What the header sync pill says, from the outbox counts. Mirrors the PWA's `SyncIndicator`
/// (`frontend/src/components/pwa/Sync.tsx`).
public struct SyncStatus: Hashable, Sendable {
    /// Picks the colour and icon: failures win, then offline, then waiting (online, syncing).
    public enum Kind: Sendable {
        case failed
        case offline
        case waiting
        /// Something the user should look at that isn't an item: a different server, repeated
        /// sync errors (iOS only).
        case attention
        /// The first pull of a store ("Loading history", iOS only).
        case loading
    }

    public let kind: Kind
    /// The pill's text on a phone: "2 failed", "3", "Offline".
    public let short: String
    /// The full sentence: "2 failed to sync", "3 waiting to sync", "Offline".
    public let label: String
    /// What VoiceOver reads; offline is always mentioned.
    public let accessibilityLabel: String

    /// Any pill, with its texts (SYNC-UX builds these from `SyncPillState`).
    public init(kind: Kind, short: String, label: String, accessibilityLabel: String) {
        self.kind = kind
        self.short = short
        self.label = label
        self.accessibilityLabel = accessibilityLabel
    }

    /// nil when online and the outbox is empty: the pill hides.
    public init?(online: Bool, pending: Int, failed: Int) {
        if online && pending == 0 && failed == 0 { return nil }
        if failed > 0 {
            kind = .failed
        } else {
            kind = online ? .waiting : .offline
        }
        if failed > 0 {
            short = "\(failed) failed"
            label = "\(failed) failed to sync"
        } else if pending > 0 {
            short = "\(pending)"
            label = "\(pending) waiting to sync"
        } else {
            short = "Offline"
            label = "Offline"
        }
        accessibilityLabel = online || label == "Offline" ? label : "Offline · \(label)"
    }

    /// The sync icon turns while there is something to send and a connection to send it on.
    public var isSyncing: Bool { kind == .waiting || kind == .loading }
}
