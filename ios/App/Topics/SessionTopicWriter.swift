import Foundation
import QuickrCore
import QuickrData
import QuickrUI

/// The topic screens' `TopicWriter`, the question editor's `VersionWriter` and Edit times'
/// `EntryTimingWriting`, over the app's
/// session, bound to the store the screen was opened from (`binding`). Online-only writes go
/// through `TopicWrites` (fail closed, Expect headers, fenced apply, then a pull); archive and
/// unarchive go through the outbox. Once the active store isn't `binding` any more (a server
/// switch, a reset), every write is refused instead of reaching the other store.
@MainActor
final class SessionTopicWriter: TopicWriter, VersionWriter, EntryTimingWriting {
    let session: AppSession
    let binding: AppSession.Binding

    init(session: AppSession, binding: AppSession.Binding) {
        self.session = session
        self.binding = binding
    }

    func create(_ creation: TopicDraft.Creation, schedule: Schedule?) async -> TopicWriteOutcome<Topic> {
        await perform { await $0.create(TopicRequests.create(creation, schedule: schedule)) }
    }

    func saveDetails(_ change: TopicDetailsChange, topicId: UUID) async -> TopicWriteOutcome<Topic> {
        await perform { await $0.update(topicId: topicId, TopicRequests.details(change)) }
    }

    func saveSchedule(_ schedule: Schedule?, topicId: UUID) async -> TopicWriteOutcome<Topic> {
        await perform { await $0.update(topicId: topicId, TopicRequests.schedule(schedule)) }
    }

    /// Deletes an archived topic; an archive still queued is sent first (`TopicWrites.delete`).
    func delete(topicId: UUID) async -> TopicWriteOutcome<Void> {
        await perform { await $0.delete(topicId: topicId) }
    }

    func checkVersion(_ version: TopicDraft.Version, baseVersion: Int, topicId: UUID) async
        -> TopicWriteOutcome<CompatibilityReport>
    {
        await perform {
            await $0.checkVersion(topicId: topicId, TopicRequests.versionCheck(version, baseVersion: baseVersion))
        }
    }

    func publishVersion(_ version: TopicDraft.Version, baseVersion: Int, changeNote: String, topicId: UUID) async
        -> TopicWriteOutcome<Topic>
    {
        await perform {
            await $0.publishVersion(topicId: topicId, version, baseVersion: baseVersion, changeNote: changeNote)
        }
    }

    func latestTopic(topicId: UUID) async -> TopicWriteOutcome<Topic> {
        await perform { await $0.latest(topicId: topicId) }
    }

    /// Edit times: online only (timers.md §3.8), see `TopicWrites.updateEntryTiming`.
    func saveTiming(_ edit: TimingDraft.Edit, entryId: UUID, expectedRevision: Int) async -> TopicWriteOutcome<Entry> {
        await perform { await $0.updateEntryTiming(entryId: entryId, edit, expectedRevision: expectedRevision) }
    }

    func latestEntry(entryId: UUID) async -> TopicWriteOutcome<Entry> {
        await perform { await $0.latestEntry(entryId: entryId) }
    }

    func unsyncedChanges(topicId: UUID) async -> Int {
        guard session.binding == binding, let store = session.store else { return 0 }
        return (try? await TopicWrites.unsyncedChanges(topicId: topicId, in: store)) ?? 0
    }

    func setArchived(_ archived: Bool, topicId: UUID, baseRevision: Int) async throws {
        guard session.binding == binding else { throw TopicWriteError.switched }
        if archived {
            try await session.archiveTopic(id: topicId, baseRevision: baseRevision)
        } else {
            try await session.unarchiveTopic(id: topicId, baseRevision: baseRevision)
        }
    }

    /// Runs `body` with writes scoped to `binding`'s store, or says why there are none.
    private func perform<Value: Sendable>(_ body: (TopicWrites) async -> TopicWrites.Outcome<Value>) async
        -> TopicWriteOutcome<Value>
    {
        guard session.binding == binding, let store = session.store else { return .switched }
        guard let scope = await TopicWrites.scope(binding: binding, store: store) else {
            return session.binding == binding ? .notReady : .switched
        }
        let coordinator = session.coordinator
        let writes = TopicWrites(
            scope: scope, store: store, transport: session.configuration.transport,
            credentials: session.configuration.credentials,
            // The screen doesn't wait for the pull: it runs on its own.
            requestSync: { reason in Task { _ = await coordinator.sync(reason: reason) } })
        return Self.outcome(await body(writes))
    }

    static func outcome<Value: Sendable>(_ outcome: TopicWrites.Outcome<Value>) -> TopicWriteOutcome<Value> {
        switch outcome {
        case .done(let value): .done(value)
        case .offline: .offline
        case .notReady: .notReady
        case .resyncing: .resyncing
        case .rejected(_, let problem): .rejected(problem)
        case .staleRevision: .staleRevision
        case .notFound: .notFound
        case .busy: .busy
        case .unconfirmed(let message): .unconfirmed(message)
        case .failed(let message): .failed(message)
        }
    }
}
