import Foundation
import QuickrCore

/// A topic's Versions tab (the PWA's `VersionsPage`), from the store: newest first, the current
/// one marked and open. Versions are immutable and come only from the server (sync-protocol.md
/// §3.2), so the tab works offline; each one's entry count is the store's (§3.3).
public struct VersionsList: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var version: Int
        public var isCurrent: Bool
        public var createdAt: Date
        /// The change note, or nil: show ``placeholder`` instead.
        public var note: String?
        /// "Initial version" for v1, "No change note" otherwise.
        public var placeholder: String
        public var entryCount: Int
        public var questions: [Question]

        public var id: Int { version }

        /// "12 entries".
        public func entries(locale: Locale = .autoupdatingCurrent) -> String {
            ChartFormat.plural(entryCount, "entry", "entries", locale: locale)
        }
    }

    public var rows: [Row]
    /// The topic's current version when the store doesn't have its row yet (just published here;
    /// the pull is bringing it).
    public var pending: Int?

    public init(versions: [TopicVersion], currentVersion: Int) {
        rows = versions.sorted { $0.version > $1.version }.map { v in
            Row(
                version: v.version, isCurrent: v.version == currentVersion, createdAt: v.createdAt,
                note: v.changeNote.isEmpty ? nil : v.changeNote,
                placeholder: v.version == 1 ? "Initial version" : "No change note", entryCount: v.entryCount,
                questions: v.questions)
        }
        pending = versions.contains { $0.version == currentVersion } ? nil : currentVersion
    }

    public static let intro =
        "Versions are immutable snapshots. Every entry stays pinned to the version it was recorded with."
}
