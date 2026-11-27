import Foundation
import Observation
import QuickrCore

/// Each topic's latest entry, for the idle tile's summary line (content-display.md §5), app-wide
/// like ``QuickLogModels`` and for the same reason: a tile the lazy list rebuilds shows its line
/// at once, at its final height. The tiles' store observations fill it.
///
/// One store's: when the writer's `EntryScope` changes (a server switch or a reset) every entry
/// goes, and late updates from the old store's observations are ignored.
@MainActor @Observable
public final class LatestEntries {
    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var scope: EntryScope?
    @ObservationIgnored private let writer: any EntryWriter

    public init(writer: any EntryWriter) {
        self.writer = writer
    }

    /// The topic's latest entry, as last read from the active store; nil before the first read and
    /// for a topic with none.
    public subscript(topicId: UUID) -> Entry? {
        followScope()
        return entries[topicId]
    }

    /// Records `entry` (nil: the topic has none) read from `scope`; ignored unless that is still the
    /// active store. Unchanged values aren't written (each write redraws).
    public func update(_ topicId: UUID, entry: Entry?, from scope: EntryScope?) {
        followScope()
        guard scope == self.scope, entries[topicId] != entry else { return }
        entries[topicId] = entry
    }

    /// Drops the entries of topics no longer in the store (`ids`: every topic it holds).
    public func retain(_ ids: Set<UUID>) {
        followScope()
        let kept = entries.filter { ids.contains($0.key) }
        if kept.count != entries.count { entries = kept }
    }

    private func followScope() {
        let current = writer.scope
        guard current != scope else { return }
        if !entries.isEmpty { entries.removeAll() }
        scope = current
    }
}
