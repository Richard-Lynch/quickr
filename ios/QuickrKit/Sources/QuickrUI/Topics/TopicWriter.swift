import Foundation
import QuickrCore

/// What became of an online-only topic write (sync-protocol.md §11), as the screens show it.
public enum TopicWriteOutcome<Value: Sendable>: Sendable {
    /// The server executed it.
    case done(Value)
    /// No connection: nothing was sent.
    case offline
    /// The server hasn't finished its first sync on this iPhone: nothing was sent.
    case notReady
    /// quickR moved to another server (or reset) since the screen opened: nothing was sent.
    case switched
    /// Another server or epoch answered: quickR is resyncing.
    case resyncing
    /// The server refused it, with its Problem when it sent one.
    case rejected(Problem?)
    /// The topic changed elsewhere since it was read.
    case staleRevision
    /// The topic isn't on the server any more.
    case notFound
    /// The outbox was busy sending and the write didn't start: try again.
    case busy
    /// It may or may not have happened; a sync will show which.
    case unconfirmed(String)
    case failed(String)

    /// The message for every outcome but `done` and `rejected` (whose Problem the form maps).
    public var message: String? {
        switch self {
        case .done, .rejected: nil
        case .offline: TopicWriteMessage.offline
        case .notReady: TopicWriteMessage.notReady
        case .switched: TopicWriteMessage.switched
        case .resyncing: TopicWriteMessage.resyncing
        case .staleRevision: TopicWriteMessage.staleRevision
        case .notFound: TopicWriteMessage.notFound
        case .busy: TopicWriteMessage.busy
        case .unconfirmed(let message), .failed(let message): message
        }
    }
}

public enum TopicWriteMessage {
    /// sync-protocol.md §11: "Needs a connection" when used offline.
    public static let offline = "Needs a connection. Connect to the internet, then try again."
    public static let notReady = "This server hasn’t finished syncing yet. Try again in a moment."
    public static let switched = "quickR switched to another server. Open this topic again."
    public static let resyncing = "quickR is resyncing, try again in a moment."
    public static let staleRevision = "This topic was changed elsewhere. It shows the latest now; try again."
    public static let notFound = "This topic isn’t on the server any more."
    public static let busy = "Sync is busy, try again in a moment."
}

/// Why a queued topic change (archive, unarchive) was refused; its description is the message.
public enum TopicWriteError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The screen's store isn't the active one any more (a server switch or a reset).
    case switched

    public var description: String {
        switch self {
        case .switched: TopicWriteMessage.switched
        }
    }
}

/// The topic screens' writes, bound to the store the screen was opened from (the app's
/// `SessionTopicWriter` over `TopicWrites` and the session). Online-only writes return an
/// outcome; archive and unarchive are queued, so they work offline.
@MainActor
public protocol TopicWriter: AnyObject {
    func create(_ creation: TopicDraft.Creation, schedule: Schedule?) async -> TopicWriteOutcome<Topic>
    func saveDetails(_ change: TopicDetailsChange, topicId: UUID) async -> TopicWriteOutcome<Topic>
    /// Sets the schedule, or removes it (nil).
    func saveSchedule(_ schedule: Schedule?, topicId: UUID) async -> TopicWriteOutcome<Topic>
    /// Deletes an archived topic.
    func delete(topicId: UUID) async -> TopicWriteOutcome<Void>
    /// The topic's queued and failed changes: lost if it is deleted.
    func unsyncedChanges(topicId: UUID) async -> Int
    /// Queues an archive or an unarchive (`baseRevision`: the revision on screen). Throws when the
    /// screen's store isn't the active one any more, or the queue refuses it.
    func setArchived(_ archived: Bool, topicId: UUID, baseRevision: Int) async throws
}
