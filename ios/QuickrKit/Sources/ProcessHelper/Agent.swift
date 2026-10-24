import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport

/// `ProcessHelper agent`: one app or extension process of a multi-process test
/// (sync-protocol.md §13 G5, outbox.md §13). It opens the shared registry and store files under
/// `--root` with the test's shared clocks (`FileLeaseClock`, `FileWallClock`), reaches the test's
/// fake server over loopback HTTP with the production `URLSessionTransport`, and runs the real
/// `Outbox`, `SyncCoordinator` and store primitives on command (`HelperCommand` lines on stdin,
/// one `HelperReply` line each on stdout). It exits at stdin EOF.
actor Agent {
    let partitions: StorePartitions
    let owner: String
    let notifier: ScopedDarwinNotifier
    let leaseClock: any LeaseClock
    let wallClock: FileWallClock
    let pageLimit: Int
    private var role: StorePartitions.Role = .app
    private var store: LocalStore?
    private var baseURL: URL?
    private var claims: [String: LeaseClaim] = [:]
    private var intent: RegisteredServer?
    private var coordinator: SyncCoordinator?
    private var listener: Task<Void, Never>?
    private var warning: SyncCoordinator.ResetWarning?

    init(arguments: [String: String]) throws {
        guard let root = arguments["root"], let owner = arguments["owner"], let leasePath = arguments["lease-clock"],
            let wallPath = arguments["wall-clock"], let scope = arguments["scope"]
        else { throw HelperError(description: "agent needs --root --owner --lease-clock --wall-clock --scope") }
        // `system` is production lease time (mach_continuous_time + the boot session id).
        leaseClock = leasePath == "system" ? SystemLeaseClock() : FileLeaseClock(url: URL(fileURLWithPath: leasePath))
        pageLimit = Int(arguments["page-limit"] ?? "") ?? APIClient.feedPageLimit
        wallClock = FileWallClock(url: URL(fileURLWithPath: wallPath))
        notifier = ScopedDarwinNotifier(scope: scope)
        self.owner = owner
        partitions = try StorePartitions.open(
            at: StoreLocation(root: URL(fileURLWithPath: root)), leaseClock: leaseClock, wallClock: wallClock,
            notifier: notifier)
    }

    func handle(_ command: HelperCommand) async throws -> [String: String] {
        let args = command.args
        switch command.name {
        case "ping":
            return ["pid": String(getpid())]

        // MARK: Store

        case "open":
            // open {role: app|extension}: the active store, through the §12.2 recovery.
            role = args["role"] == "extension" ? .extension : .app
            return ["storeGen": String(try await reopen().storeGen)]
        case "isRetired":
            return ["retired": String(try await requireStore().isRetired())]

        // MARK: Outbox

        case "log":
            let topic = TopicRef(
                id: try uuid(args["topicId"]), slug: args["slug"] ?? "mood", name: args["name"] ?? "Mood")
            let body = EntryCreateDTO(
                id: nil, answers: [args["key"] ?? "mood": .int(Int(args["value"] ?? "4") ?? 4)], source: "ios",
                capturedAt: wallClock.now(), version: 1)
            let id = try uuid(args["id"])
            return try await enqueue { outbox in
                try await outbox.createEntry(id: id, topic: topic, body: body, origin: self.origin())
            }
        case "update":
            let patch =
                args["mood"].flatMap(Int.init).map { EntryUpdateDTO(answers: ["mood": .int($0)]) }
                ?? EntryUpdateDTO(notes: args["notes"] ?? "edited")
            let (id, topicId) = (try uuid(args["id"]), try uuid(args["topicId"]))
            return try await enqueue { outbox in
                try await outbox.updateEntry(id: id, topicId: topicId, patch: patch, origin: self.origin())
            }
        case "delete":
            let (id, topicId, undoable) = (try uuid(args["id"]), try uuid(args["topicId"]), args["undoable"] == "true")
            return try await enqueue { outbox in
                try await outbox.deleteEntry(id: id, topicId: topicId, undoable: undoable, origin: self.origin())
            }
        case "undoLog":
            return ["result": "\(try await outbox().undoLog(entryId: try uuid(args["id"]), origin: origin()))"]
        case "archive":
            return try describe(await outbox().archiveTopic(id: try uuid(args["topicId"]), origin: origin()))
        case "unarchive":
            return try describe(await outbox().unarchiveTopic(id: try uuid(args["topicId"]), origin: origin()))
        case "runStart":
            // runStart {topicId, slug, name, version}: `RunWrites.start` (timers.md §8.1).
            let topic = TopicRef(
                id: try uuid(args["topicId"]), slug: args["slug"] ?? "mood", name: args["name"] ?? "Mood")
            let result = try await runWrites().start(topic: topic, version: Int(args["version"] ?? "1") ?? 1)
            return ["runId": result.runId, "started": String(result.started)]
        case "runTap":
            // runTap {type, runId, seg?}: one tap through `RunWrites`; `seg` is the segment the
            // surface showed (a widget's or Live Activity's content state).
            guard let type = RunTapType(rawValue: try required(args["type"])) else {
                throw HelperError(description: "unknown tap \(args["type"] ?? "")")
            }
            let target: RunTapTarget =
                args["seg"].flatMap(Int.init).map { .shown(seg: $0, step: nil, pauseId: nil) } ?? .current
            let result = try await runWrites().tap(type, runId: try required(args["runId"]), target: target)
            return result.map(describe) ?? ["result": "none"]
        case "releaseHolds":
            return ["released": String(try await outbox().releaseHolds(all: args["all"] == "true"))]
        case "flush":
            let report = try await outbox().flush(
                force: args["force"] != "false", budget: .milliseconds(Int(args["budgetMs"] ?? "30000") ?? 30_000),
                leaseWait: .milliseconds(Int(args["leaseWaitMs"] ?? "0") ?? 0))
            return [
                "ending": "\(report.ending)", "requests": String(report.requests), "acked": String(report.acked),
                "failed": String(report.failed), "retried": String(report.retried), "settled": String(report.settled),
                "elapsedMs": report.elapsed.map { String(Int(($0 / .milliseconds(1)).rounded(.up))) } ?? "",
            ]

        // MARK: Leases

        case "leaseAcquire":
            let name = try leaseName(args["name"])
            let store = try requireStore()
            let claim = try await store.leases.acquire(
                name, owner: owner, holding: Array(claims.values),
                waitingUpTo: .milliseconds(Int(args["waitMs"] ?? "0") ?? 0), pollInterval: .milliseconds(20))
            if let claim { claims[name.rawValue] = claim }
            return ["acquired": String(claim != nil)]
        case "leaseRenew":
            guard let claim = claims[try leaseName(args["name"]).rawValue] else { return ["renewed": "false"] }
            return ["renewed": String(try await requireStore().leases.renew(claim))]
        case "leaseRelease":
            guard let claim = claims.removeValue(forKey: try leaseName(args["name"]).rawValue) else {
                return ["released": "false"]
            }
            return ["released": String(try await requireStore().leases.release(claim))]

        // MARK: Reset primitives (§12.1)

        case "persistIntent":
            let store = try requireStore()
            let (count, maxSeq) = try await store.outbox.summary()
            let intent = try await partitions.persistResetIntent(
                store: store, confirmedCount: count, confirmedMaxSeq: maxSeq)
            self.intent = intent
            return ["pendingGen": String(intent.pendingGen ?? 0), "count": String(count)]
        case "retire":
            guard let intent, let sync = claims["sync"], let flush = claims["flush"] else {
                throw HelperError(description: "retire needs an intent and both leases")
            }
            let outcome = try await requireStore().retire(
                confirmedCount: intent.pendingConfirmedCount ?? 0, confirmedMaxSeq: intent.pendingConfirmedMaxSeq ?? 0,
                intentToken: intent.pendingToken, sync: sync, flush: flush)
            return ["outcome": "\(outcome)"]

        // MARK: Coordinator (app only)

        case "sync":
            return ["result": "\(await coordinatorInstance().sync(reason: .requested))"]
        case "bootstrap":
            let coordinator = coordinatorInstance()
            let result = await coordinator.bootstrapIfNeeded()
            let resumed = await coordinator.resumedReset
            return ["result": "\(result)", "resumedReset": resumed.map { "\($0)" } ?? "none"]
        case "waitIdle":
            // Waits, without starting a run, until the coordinator has no run in progress (for
            // a run started by `listen`). Call it once the run's effect is visible.
            let coordinator = coordinatorInstance()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while coordinator.status.activity != .idle {
                guard ContinuousClock.now < deadline else { throw HelperError(description: "coordinator still busy") }
                try await Task.sleep(for: .milliseconds(2))
            }
            return [:]
        case "listen":
            listener?.cancel()
            listener = coordinatorInstance().listen(to: notifier)
            return [:]
        case "resetWarning":
            guard let warning = try await coordinatorInstance().resetWarning() else {
                throw HelperError(description: "no active store")
            }
            self.warning = warning
            return [
                "serverId": warning.serverId, "storeGen": String(warning.storeGen), "count": String(warning.count),
                "failed": String(warning.failedCount), "maxSeq": String(warning.maxSeq),
            ]
        case "performReset":
            // The warning the last `resetWarning` showed is what the user confirmed (§12.1 step 1).
            guard let warning else { throw HelperError(description: "send resetWarning first") }
            return ["outcome": "\(try await coordinatorInstance().performReset(confirmed: warning))"]

        // MARK: Signals

        case "post":
            notifier.post(ChangeSignalName(rawValue: try required(args["signal"])))
            return [:]

        // MARK: Notification categories (notifications.md §5.2, N4)

        case "registerCategories":
            return try await registerCategories(
                prefix: try required(args["prefix"]), count: Int(args["count"] ?? "1") ?? 1,
                log: URL(fileURLWithPath: try required(args["log"])),
                participants: Int(args["participants"] ?? "1") ?? 1, cap: args["cap"].flatMap { Int($0) })

        // MARK: Test of the harness

        case "hang":
            // Never replies (until the process dies): a child that is stuck.
            try await Task.sleep(for: .seconds(86_400))
            return [:]

        default:
            throw HelperError(description: "unknown command \(command.name)")
        }
    }

    // MARK: - Pieces

    /// Opens the active store at its current generation, through the §12.2 recovery (as every
    /// process does at start, on `registry-changed`, and when a transaction fails `retired`).
    @discardableResult
    private func reopen() async throws -> LocalStore {
        guard let opened = try await partitions.openActiveStore(role: role) else {
            throw HelperError(description: "no active store")
        }
        let store = opened.store
        self.store = store
        baseURL = try await store.syncState.syncState().flatMap { URL(string: $0.baseURL) }
        if case .resetPending(_, let intent) = opened { self.intent = intent }
        return store
    }

    /// An enqueue; a store retired by a reset reopens through the registry and the enqueue is
    /// retried on the new file (sync-protocol.md §12.1 step 4). `reopened` says whether it was.
    private func enqueue(_ body: (Outbox) async throws -> OutboxEnqueueResult) async throws -> [String: String] {
        do {
            return describe(try await body(try outbox()))
        } catch StoreError.retired {
            try await reopen()
            var result = describe(try await body(try outbox()))
            result["reopened"] = "true"
            result["storeGen"] = String(try requireStore().storeGen)
            return result
        }
    }

    private func requireStore() throws -> LocalStore {
        guard let store else { throw HelperError(description: "no store open (send open first)") }
        return store
    }

    private func outbox() throws -> Outbox {
        guard let baseURL else { throw HelperError(description: "no store open (send open first)") }
        let notifier = notifier
        let client = APIClient(baseURL: baseURL, transport: URLSessionTransport(), identity: StaticServerIdentity(nil))
        return Outbox(
            store: try requireStore(), sender: client, owner: owner,
            // As an extension would (§5.6 step 3): the app's coordinator listens.
            onSignal: { _ in notifier.post(.syncRequested) }, random: { 0.5 }, shutdownGrace: .milliseconds(500))
    }

    private func runWrites() throws -> RunWrites { RunWrites(store: try requireStore(), origin: origin()) }

    private func coordinatorInstance() -> SyncCoordinator {
        if let coordinator { return coordinator }
        var configuration = SyncCoordinator.Configuration()
        configuration.autoRetry = false
        configuration.pageLimit = pageLimit
        let coordinator = SyncCoordinator(
            partitions: partitions,
            feed: { url in
                APIClient(baseURL: url, transport: URLSessionTransport(), identity: StaticServerIdentity(nil))
            },
            flush: NoSyncSideEffects(), owner: owner, configuration: configuration)
        self.coordinator = coordinator
        return coordinator
    }

    private func origin() -> OutboxOrigin { owner.hasPrefix("widget") ? .widget : .app }

    private func describe(_ result: OutboxEnqueueResult) -> [String: String] {
        switch result {
        case .appended(let item): ["result": "appended", "itemId": item.id]
        case .merged(let item): ["result": "merged", "itemId": item.id]
        case .cancelled: ["result": "cancelled"]
        }
    }

    /// §5.2 through the real `NotificationCategories.register`: one registry `IMMEDIATE`
    /// transaction per call inserts the new row, reads the whole table and hands it to the center.
    /// The center here is `RegistrationLog`: each `setNotificationCategories` is an `O_APPEND`
    /// line in `log`, written inside the transaction, so the log's line order is the transactions'
    /// commit order and each line is exactly what that call registered.
    ///
    /// `participants` processes run in lockstep: registration `k` starts only once the log holds
    /// `participants × k` lines (every process finished round `k − 1`), so the processes overlap
    /// in every round. After its `count` rows, each process registers once more without inserting
    /// (when every process is done): its final registration must carry the whole table.
    /// `cap` caps each registration (§5.2); without it every row is registered.
    private func registerCategories(prefix: String, count: Int, log: URL, participants: Int, cap: Int?) async throws
        -> [String: String]
    {
        for index in 0..<count {
            try await waitForLines(participants * index, in: log)
            try await register(row: Self.categoryRow(prefix: prefix, index: index), log: log, cap: cap)
        }
        try await waitForLines(participants * count, in: log)
        try await register(row: nil, log: log, cap: cap)
        return ["registered": String(count + 1)]
    }

    private func register(row: NotificationCategories.Row?, log: URL, cap: Int?) async throws {
        let center = RegistrationLog(owner: owner, label: row?.category.id ?? "final", log: log)
        try await NotificationCategories(registry: partitions.registry, center: center, cap: cap)
            .register(row.map { [$0] } ?? [])
    }

    /// A real category (a two-option enum) for topic `prefix`-`index`: distinct topics, distinct ids.
    private static func categoryRow(prefix: String, index: Int) -> NotificationCategories.Row {
        let topicId = UUID(
            uuidString: String(format: "00000000-0000-4000-8%03d-%012d", Int(prefix.unicodeScalars.first!.value), index)
        )!
        .wireString
        let question = Question(
            key: "mood", label: "Mood",
            kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "bad", label: "Bad")])))
        let category = NotificationCategory(
            serverId: "server-1", topicId: topicId, version: 1, questions: [question])!
        return .init(serverId: "server-1", topicId: topicId, category: category)
    }

    /// Polls the log until it has `count` lines (a cross-process barrier on durable state).
    private func waitForLines(_ count: Int, in log: URL) async throws {
        guard count > 0 else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ((try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").count ?? 0) < count {
            guard ContinuousClock.now < deadline else { throw HelperError(description: "lockstep: no \(count) lines") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func uuid(_ value: String?) throws -> UUID {
        guard let value, let uuid = UUID(uuidString: value) else {
            throw HelperError(description: "bad uuid \(value ?? "nil")")
        }
        return uuid
    }

    private func leaseName(_ value: String?) throws -> LeaseName {
        guard let value, let name = LeaseName(rawValue: value) else { throw HelperError(description: "bad lease name") }
        return name
    }

    private func required(_ value: String?) throws -> String {
        guard let value else { throw HelperError(description: "missing argument") }
        return value
    }
}

/// Reads commands until stdin closes, running each concurrently, and writes each reply as one
/// line as soon as it is ready.
func runAgent(_ rawArguments: [String]) async -> Never {
    var arguments: [String: String] = [:]
    var iterator = rawArguments.makeIterator()
    while let key = iterator.next() {
        guard key.hasPrefix("--"), let value = iterator.next() else { fail("agent: bad argument \(key)") }
        arguments[String(key.dropFirst(2))] = value
    }
    let agent: Agent
    do {
        agent = try Agent(arguments: arguments)
    } catch {
        fail("agent: \(error)")
    }
    let output = ReplyWriter()
    await withTaskGroup(of: Void.self) { group in
        for await line in standardInputLines() {
            guard let command = try? JSONDecoder().decode(HelperCommand.self, from: Data(line.utf8)) else {
                continue
            }
            group.addTask {
                let reply: HelperReply
                do {
                    reply = HelperReply(id: command.id, ok: true, result: try await agent.handle(command))
                } catch {
                    reply = HelperReply(id: command.id, ok: false, error: describe(error))
                }
                output.write(reply)
            }
        }
    }
    exit(0)
}

/// stdin's lines, read by a blocking `readLine` on a thread of their own, so the wait for the
/// next command never holds a cooperative-pool thread, whatever the pool's width.
func standardInputLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread {
            while let line = readLine() { continuation.yield(line) }
            continuation.finish()
        }.start()
    }
}

/// The error a reply carries: its type, a stable code for the errors tests match, and its text.
func describe(_ error: any Error) -> String {
    if let error = error as? OutboxError, error == .entryDeleted { return "OutboxError.entryDeleted: \(error)" }
    if let error = error as? StoreError, error == .retired { return "StoreError.retired: \(error)" }
    return "\(type(of: error)): \(error)"
}

/// Writes reply lines to stdout, unbuffered, one at a time.
final class ReplyWriter: Sendable {
    private let lock = NSLock()

    func write(_ reply: HelperReply) {
        guard var line = try? JSONEncoder().encode(reply) else { return }
        line.append(UInt8(ascii: "\n"))
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(line)
    }
}

/// N4's notification center: records each `setNotificationCategories` as one line,
/// `{owner}|{inserted category id, or "final"}|{registered ids, comma-separated}`.
private struct RegistrationLog: NotificationCenterProtocol {
    let owner: String
    let label: String
    let log: URL

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        let line = "\(owner)|\(label)|\(categories.map(\.id).sorted().joined(separator: ","))\n"
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { fatalError("can't open \(log.path)") }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        precondition(write(descriptor, bytes, bytes.count) == bytes.count, "short write to \(log.path)")
    }

    func notificationCategories() async -> [NotificationCategorySpec] { [] }
    func deliveredNotifications() async -> [NotificationSnapshot] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func pendingNotificationRequests() async -> [NotificationSnapshot] { [] }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func add(_ request: LocalNotificationRequest) async throws {}
    func setBadgeCount(_ count: Int) async throws {}
    func authorizationStatus() async -> NotificationAuthorization { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
}
