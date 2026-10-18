import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization

/// Builders and fixtures for the store tests.
enum Make {
    static let t0 = Date(timeIntervalSince1970: 1_772_625_600)  // 2026-03-04T12:00:00Z

    static let questions = [
        Question(key: "mood", label: "Mood", kind: .int(.init(min: 1, max: 5))),
        Question(
            key: "where", label: "Where", required: false,
            kind: .choice(.init(options: [.init(value: "home", label: "Home"), .init(value: "work", label: "Work")]))),
        Question(key: "weight", label: "Weight", required: false, kind: .double(.init(decimals: 1))),
    ]

    static func topic(
        id: UUID = UUID(), name: String = "Mood", slug: String? = nil, revision: Int = 1,
        status: TopicStatus = .active, schedule: Schedule? = nil
    ) -> Topic {
        Topic(
            id: id, slug: slug ?? name.lowercased(), name: name, description: "How do you feel", status: status,
            currentVersion: 1, revision: revision, questionCount: questions.count, entryCount: 99,
            lastCapturedAt: t0, createdAt: t0, updatedAt: t0, archivedAt: status == .archived ? t0 : nil,
            schedule: schedule, scheduleUpdatedAt: schedule == nil ? nil : t0, questions: questions)
    }

    static func entry(
        id: UUID = UUID(), topicId: UUID, revision: Int = 1, version: Int = 1, minutes: Double = 0,
        answers: [String: AnswerValue] = ["mood": .int(3)], notes: String = ""
    ) -> Entry {
        let at = t0.addingTimeInterval(minutes * 60)
        return Entry(
            id: id, topicId: topicId, version: version, revision: revision, source: "ios", channel: .ios,
            capturedAt: at, createdAt: at, updatedAt: at, notes: notes, meta: ["k": "v"], answers: answers)
    }

    static func version(_ number: Int = 1) -> TopicVersion {
        TopicVersion(version: number, questions: questions, changeNote: "v\(number)", createdAt: t0)
    }

    static func createPayload(topic: Topic, minutes: Double = 0, answers: [String: AnswerValue] = ["mood": .int(4)])
        -> OutboxPayload
    {
        .entryCreate(
            topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name),
            body: EntryCreateDTO(
                id: nil, answers: answers, source: "ios", capturedAt: t0.addingTimeInterval(minutes * 60), version: 1))
    }
}

/// A store over an in-memory database (or a file at `path`) with a bootstrapped `sync_state` and
/// fake clocks.
struct TestStore {
    let store: LocalStore
    let clock: FakeLeaseClock
    let wall: FakeClock
    let path: String?

    init(epoch: String? = "E1", path: String? = nil) throws {
        self.path = path
        let queue = try TestDatabase.store(path: path)
        try queue.write { db in
            try LocalStore.createSyncState(db, serverId: "server-1", baseURL: "https://q.example")
            try db.execute(sql: "UPDATE sync_state SET epoch = ?", arguments: [epoch])
        }
        clock = FakeLeaseClock()
        wall = FakeClock(Make.t0)
        store = LocalStore(
            serverId: "server-1", storeGen: 1, url: nil, writer: queue, leaseClock: clock, wallClock: wall)
    }

    var writer: any DatabaseWriter { store.writer }

    func write<T>(_ body: (Database) throws -> T) throws -> T { try store.writer.write(body) }

    func read<T>(_ body: (Database) throws -> T) throws -> T { try store.writer.read(body) }

    @discardableResult
    func enqueue(_ payload: OutboxPayload, id: UUID = UUID(), hold: LeaseInstant? = nil, baseRevision: Int? = nil)
        throws -> OutboxItem
    {
        try write { db in
            try OutboxStorage.append(
                db, NewOutboxItem(id: id, payload: payload, baseRevision: baseRevision, origin: .app, hold: hold),
                now: wall.now())
        }
    }

    /// Sets an item's state (and reason) directly, as the outbox state machine would.
    func setState(_ item: OutboxItem, _ state: OutboxState, reason: OutboxFailureReason? = nil) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE outbox_item SET state = ?, failure_reason = ? WHERE id = ?",
                arguments: [state.rawValue, reason?.rawValue, item.id])
        }
    }
}

/// A fresh temporary directory, removed by `cleanup()`.
struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "quickr-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Records posts and delivers them to `signals` subscribers in this process.
final class RecordingNotifier: ChangeNotifier {
    private let state = Mutex<(posts: [ChangeSignalName], subscribers: [AsyncStream<Void>.Continuation])>(([], []))

    var posts: [ChangeSignalName] { state.withLock { $0.posts } }

    func post(_ name: ChangeSignalName) {
        let subscribers = state.withLock { state in
            state.posts.append(name)
            return state.subscribers
        }
        for subscriber in subscribers { subscriber.yield() }
    }

    func signals(_ name: ChangeSignalName) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.subscribers.append(continuation) }
        return stream
    }
}

extension LeaseClaim {
    static func fake(_ name: LeaseName) -> LeaseClaim { LeaseClaim(name: name, owner: "nobody", token: "none") }
}
