import Foundation
import QuickrCore
import QuickrData
import Synchronization

/// A stateful fake quickR server behind `Transport`, so outbox tests run through the real
/// `APIClient` and `APIClassifier`. It implements what the outbox relies on: F9 headers on every
/// response, the F10 preconditions, reserved ids (`entry_deleted`), revisions and
/// `stale_revision`, idempotent POST replay, 404s, archive/unarchive, and the online-only topic
/// writes (create, PATCH, DELETE of an archived topic). Faults script the
/// network: answer instead, lose the answer, garble it, or delay the request (a `Gate`).
final class FakeServer: Transport {
    static let base = URL(string: "https://q.example")!
    static let at = Date(timeIntervalSince1970: 1_772_625_600)

    struct State {
        var serverId = "server-1"
        var epoch = "E1"
        var entries: [String: Entry] = [:]
        /// `deleted_ids`.
        var deleted: Set<String> = []
        var topics: [String: Topic] = [:]
        /// Strip both identity headers from every response (a misbehaving proxy).
        var omitHeaders = false
    }

    enum Action: Sendable {
        /// Don't execute; answer this instead.
        case respond(HTTPResponse)
        /// Execute, then lose the answer.
        case lose(TransportError)
        /// Execute, then answer with this status and body (and the real headers).
        case garble(status: Int, body: Data)
        /// Hold the request in the network until the gate opens, then execute it (or answer
        /// `override`). The client's cancellation abandons the wait, not the request.
        case delay(Gate, override: HTTPResponse? = nil)
        /// Hold the request until the client cancels it; it then executes (or answers `override`)
        /// and the answer reaches the client just after the cancellation: a response that lands
        /// while the client shuts down. It arrives `after` the cancel (20 ms: after any timer the
        /// cancellation woke), so a client that stops listening at cancellation loses it.
        case answerOnCancel(Gate, override: HTTPResponse? = nil, after: Duration = .milliseconds(20))
        /// A transport that ignores cancellation: the request waits for the gate whatever the
        /// client does, then executes and answers.
        case hang(Gate)
        /// Commit at once, but deliver the answer only after `delay`, whatever the client does.
        case commitThenDeliver(after: Duration)
        /// Mutate the server first (another device acts just before), then execute.
        case before(@Sendable (inout State) -> Void)
    }

    private struct Fault {
        var matches: @Sendable (HTTPRequest) -> Bool
        var action: Action
        var once: Bool
    }

    private let state = Mutex(State())
    private let faults = Mutex<[Fault]>([])
    private let log = Mutex<[HTTPRequest]>([])
    private let executed = Mutex<[String]>([])

    /// `"METHOD /path → status"` of every request the server executed, in order (a delayed one
    /// when its gate opens).
    var handled: [String] { executed.withLock { $0 } }

    func with<T>(_ body: (inout State) -> T) -> T { state.withLock { body(&$0) } }

    /// Every request that reached the transport, in order.
    var requests: [HTTPRequest] { log.withLock { $0 } }

    /// `"METHOD /path"` of every request, in order.
    var calls: [String] { requests.map { "\($0.method.rawValue) \($0.url.path)" } }

    func count(_ method: HTTPMethod) -> Int { requests.filter { $0.method == method }.count }

    func inject(_ method: HTTPMethod? = nil, once: Bool = true, _ action: Action) {
        inject(where: { method == nil || $0.method == method }, once: once, action)
    }

    func inject(where matches: @escaping @Sendable (HTTPRequest) -> Bool, once: Bool = true, _ action: Action) {
        faults.withLock { $0.append(Fault(matches: matches, action: action, once: once)) }
    }

    // MARK: Server-side changes by "another device"

    func put(_ topic: Topic) { with { $0.topics[topic.id.wireString] = topic } }

    func put(_ entry: Entry) { with { $0.entries[entry.id.wireString] = entry } }

    /// Edits an entry as the web would: the revision goes up.
    func edit(_ id: UUID, notes: String = "edited elsewhere") {
        with { state in
            guard var entry = state.entries[id.wireString] else { return }
            entry.notes = notes
            entry.revision += 1
            state.entries[id.wireString] = entry
        }
    }

    func deleteEntry(_ id: UUID) {
        with {
            $0.entries[id.wireString] = nil
            $0.deleted.insert(id.wireString)
        }
    }

    func setArchived(_ topicId: UUID, _ archived: Bool) {
        with { state in
            guard var topic = state.topics[topicId.wireString] else { return }
            topic.status = archived ? .archived : .active
            topic.archivedAt = archived ? Self.at : nil
            topic.revision += 1
            state.topics[topicId.wireString] = topic
        }
    }

    func deleteTopic(_ topicId: UUID) {
        with { state in
            state.topics[topicId.wireString] = nil
            for (id, entry) in state.entries where entry.topicId == topicId {
                state.entries[id] = nil
                state.deleted.insert(id)
            }
        }
    }

    func entry(_ id: UUID) -> Entry? { with { $0.entries[id.wireString] } }

    // MARK: Transport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        let action: Action? = faults.withLock { faults in
            guard let index = faults.firstIndex(where: { $0.matches(request) }) else { return nil }
            let fault = faults[index]
            if fault.once { faults.remove(at: index) }
            return fault.action
        }
        switch action {
        case nil:
            return handle(request)
        case .respond(let response):
            return response
        case .lose(let error):
            _ = handle(request)
            throw error
        case .garble(let status, let body):
            var response = handle(request)
            response.status = status
            response.body = body
            return response
        case .before(let mutate):
            with { mutate(&$0) }
            return handle(request)
        case .delay(let gate, let override):
            let delivery = Task { [self] in
                await gate.arrive()
                return override ?? handle(request)
            }
            let answer = Answer()
            Task { answer.resume(.success(await delivery.value)) }
            return try await withTaskCancellationHandler {
                try await answer.value()
            } onCancel: {
                gate.abandon()
                answer.resume(.failure(TransportError.cancelled(requestStarted: true)))
            }
        case .hang(let gate):
            await gate.arrive()
            return handle(request)
        case .commitThenDeliver(let delay):
            let response = handle(request)
            await Task { try? await Task.sleep(for: delay) }.value  // not cancellable from here
            return response
        case .answerOnCancel(let gate, let override, let delay):
            let answer = Answer()
            Task { [self] in
                await gate.arrive()  // opened by a test that doesn't cancel, or to clean up
                guard !answer.cancelled else { return }
                answer.resume(.success(override ?? handle(request)))
            }
            return try await withTaskCancellationHandler {
                try await answer.value()
            } onCancel: { [self] in
                answer.cancelled = true
                let response = override ?? handle(request)
                Task {
                    try? await Task.sleep(for: delay)
                    answer.resume(.success(response))
                }
            }
        }
    }

    /// The client's view of a request that is replayed later by the network (a delayed POST).
    func replay(_ request: HTTPRequest) -> HTTPResponse { handle(request) }

    // MARK: Handling

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        let response = state.withLock { state in
            var response = Self.route(request, &state)
            if !state.omitHeaders {
                response.headers[QuickrHeader.serverId] = state.serverId
                response.headers[QuickrHeader.epoch] = state.epoch
            }
            return response
        }
        executed.withLock { $0.append("\(request.method.rawValue) \(request.url.path) → \(response.status)") }
        return response
    }

    private static func route(_ request: HTTPRequest, _ state: inout State) -> HTTPResponse {
        let parts = request.url.path.split(separator: "/").map(String.init)  // api, v1, …
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return problem(404, "not_found") }
        if request.method != .get {
            if request.headers[QuickrHeader.expectServerId] != state.serverId {
                return problem(409, "server_mismatch", "server mismatch")
            }
            if request.headers[QuickrHeader.expectEpoch] != state.epoch {
                return problem(409, "epoch_mismatch", "epoch mismatch")
            }
        }
        if parts.count == 3 {
            guard request.method == .post, parts[2] == "topics" else { return problem(404, "not_found") }
            return createTopic(request, &state)
        }
        let id = parts[3]
        let expected = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expected_revision" }?.value.flatMap(Int.init)
        switch (request.method, parts[2], parts.count > 4 ? parts[4] : nil) {
        case (.post, "topics", "entries"): return createEntry(topicId: id, request, &state)
        case (.get, "entries", nil):
            guard let entry = state.entries[id] else { return problem(404, "not_found") }
            return ok(200, entry)
        case (.patch, "entries", nil): return updateEntry(id, request, &state)
        case (.delete, "entries", nil):
            state.entries[id] = nil
            state.deleted.insert(id)
            return HTTPResponse(status: 204)
        case (.get, "topics", nil):
            guard let topic = state.topics[id] else { return problem(404, "not_found") }
            return ok(200, topic)
        case (.patch, "topics", nil): return updateTopic(id, request, &state)
        case (.delete, "topics", nil):
            guard let topic = state.topics[id] else { return problem(404, "not_found") }
            guard topic.status == .archived else {
                return problem(409, "conflict", "archive the topic before deleting it")
            }
            state.topics[id] = nil
            state.deleted.insert(id)
            for (entryId, entry) in state.entries where entry.topicId == topic.id {
                state.entries[entryId] = nil
                state.deleted.insert(entryId)
            }
            return HTTPResponse(status: 204)
        case (.post, "topics", let action?) where action == "archive" || action == "unarchive":
            guard var topic = state.topics[id] else { return problem(404, "not_found") }
            if let expected, expected != topic.revision { return problem(409, "stale_revision", "stale revision") }
            topic.status = action == "archive" ? .archived : .active
            topic.archivedAt = action == "archive" ? at : nil
            topic.revision += 1
            state.topics[id] = topic
            return ok(200, topic)
        default:
            return problem(404, "not_found")
        }
    }

    private static func createTopic(_ request: HTTPRequest, _ state: inout State) -> HTTPResponse {
        guard let body = request.body, let dto = try? WireCoding.decoder().decode(TopicCreateDTO.self, from: body)
        else { return problem(422, "invalid_request") }
        var schedule: Schedule?
        if let input = dto.schedule {
            guard let parsed = try? input.toDomain() else { return problem(422, "invalid_request") }
            schedule = parsed
        }
        let slug = dto.slug ?? dto.name.lowercased().replacingOccurrences(of: " ", with: "-")
        if state.topics.values.contains(where: { $0.slug == slug }) {
            return problem(409, "conflict", "slug '\(slug)' is already taken")
        }
        let topic = Topic(
            id: UUID(), slug: slug, name: dto.name, description: dto.description ?? "", currentVersion: 1,
            revision: 1, questionCount: dto.questions.count, createdAt: at, updatedAt: at, schedule: schedule,
            scheduleUpdatedAt: schedule == nil ? nil : at, questions: dto.questions.map { $0.toDomain() })
        state.topics[topic.id.wireString] = topic
        return ok(201, topic)
    }

    private static func updateTopic(_ id: String, _ request: HTTPRequest, _ state: inout State) -> HTTPResponse {
        guard var topic = state.topics[id] else { return problem(404, "not_found") }
        guard let body = request.body, let dto = try? WireCoding.decoder().decode(TopicUpdateDTO.self, from: body)
        else { return problem(422, "invalid_request") }
        if let expected = dto.expectedRevision, expected != topic.revision {
            return problem(409, "stale_revision", "stale revision")
        }
        if let slug = dto.slug, slug != topic.slug, state.topics.values.contains(where: { $0.slug == slug }) {
            return problem(409, "conflict", "slug '\(slug)' is already taken")
        }
        topic.name = dto.name ?? topic.name
        topic.slug = dto.slug ?? topic.slug
        topic.description = dto.description ?? topic.description
        switch dto.schedule {
        case .absent: break
        case .null:
            topic.schedule = nil
            topic.scheduleUpdatedAt = at
        case .value(let input):
            guard let schedule = try? input.toDomain() else { return problem(422, "invalid_request") }
            topic.schedule = schedule
            topic.scheduleUpdatedAt = at
        }
        topic.revision += 1
        state.topics[id] = topic
        return ok(200, topic)
    }

    private static func createEntry(topicId: String, _ request: HTTPRequest, _ state: inout State) -> HTTPResponse {
        guard let topic = state.topics[topicId] else { return problem(404, "not_found", "topic not found") }
        guard let data = request.body, let body = try? WireCoding.decoder().decode(EntryCreateDTO.self, from: data),
            let id = body.id
        else { return problem(422, "invalid_request", "bad body") }
        if state.deleted.contains(id) { return problem(409, "entry_deleted", "entry was deleted") }
        if let existing = state.entries[id] { return ok(201, existing) }
        if topic.status == .archived { return problem(409, "topic_archived", "topic is archived") }
        let entry = Entry(
            id: UUID(uuidString: id)!, topicId: topic.id, version: body.version ?? 1, revision: 1,
            source: body.source ?? "api", channel: .ios, capturedAt: body.capturedAt ?? at, createdAt: at,
            updatedAt: at, notes: body.notes ?? "", meta: body.meta ?? [:],
            answers: body.answers.compactMapValues { $0?.value })
        state.entries[id] = entry
        return ok(201, entry)
    }

    private static func updateEntry(_ id: String, _ request: HTTPRequest, _ state: inout State) -> HTTPResponse {
        guard var entry = state.entries[id] else { return problem(404, "not_found", "entry not found") }
        guard let data = request.body, let patch = try? WireCoding.decoder().decode(EntryUpdateDTO.self, from: data)
        else { return problem(422, "invalid_request", "bad body") }
        if let expected = patch.expectedRevision, expected != entry.revision {
            return problem(409, "stale_revision", "stale revision")
        }
        for (key, value) in patch.answers ?? [:] { entry.answers[key] = value?.value }
        if let notes = patch.notes { entry.notes = notes }
        if let capturedAt = patch.capturedAt { entry.capturedAt = capturedAt }
        if let source = patch.source { entry.source = source }
        if let meta = patch.meta { entry.meta = meta }
        entry.revision += 1
        state.entries[id] = entry
        return ok(200, entry)
    }

    // MARK: Bodies

    static func problem(_ status: Int, _ code: String, _ detail: String = "nope") -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: ["code": code, "detail": detail, "errors": []])
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    static func ok(_ status: Int, _ entry: Entry) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: entryJSON(entry))
    }

    static func ok(_ status: Int, _ topic: Topic) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: topicJSON(topic))
    }

    static func entryJSON(_ entry: Entry) -> Data {
        try! WireCoding.encoder().encode(WireEntry(entry))
    }

    static func topicJSON(_ topic: Topic) -> Data {
        try! WireCoding.encoder().encode(WireTopic(topic))
    }
}

/// `EntryOut` as the server writes it.
private struct WireEntry: Encodable {
    var entry: Entry

    init(_ entry: Entry) { self.entry = entry }

    enum Keys: String, CodingKey {
        case id, version, revision, source, channel, notes, meta, answers
        case topicId = "topic_id"
        case capturedAt = "captured_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(entry.id.wireString, forKey: .id)
        try c.encode(entry.topicId.wireString, forKey: .topicId)
        try c.encode(entry.version, forKey: .version)
        try c.encode(entry.revision, forKey: .revision)
        try c.encode(entry.source, forKey: .source)
        try c.encode(entry.channel, forKey: .channel)
        try c.encode(entry.capturedAt, forKey: .capturedAt)
        try c.encode(entry.createdAt, forKey: .createdAt)
        try c.encode(entry.updatedAt, forKey: .updatedAt)
        try c.encode(entry.notes, forKey: .notes)
        try c.encode(entry.meta, forKey: .meta)
        let answers = entry.answers.sorted { $0.key < $1.key }.map { key, value in
            AnswerDTO(key: key, type: Self.type(value), value: value)
        }
        try c.encode(answers, forKey: .answers)
    }

    static func type(_ value: AnswerValue) -> String {
        switch value {
        case .int: "int"
        case .double: "double"
        case .string: "str"
        case .strings: "enum_list"
        }
    }
}

/// `TopicDetail` as the server writes it.
private struct WireTopic: Encodable {
    var topic: Topic

    init(_ topic: Topic) { self.topic = topic }

    enum Keys: String, CodingKey {
        case id, slug, name, description, status, revision, schedule, due, questions
        case currentVersion = "current_version"
        case questionCount = "question_count"
        case entryCount = "entry_count"
        case lastCapturedAt = "last_captured_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case scheduleUpdatedAt = "schedule_updated_at"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(topic.id.wireString, forKey: .id)
        try c.encode(topic.slug, forKey: .slug)
        try c.encode(topic.name, forKey: .name)
        try c.encode(topic.description, forKey: .description)
        try c.encode(topic.status, forKey: .status)
        try c.encode(topic.currentVersion, forKey: .currentVersion)
        try c.encode(topic.revision, forKey: .revision)
        try c.encode(topic.questionCount, forKey: .questionCount)
        try c.encode(topic.entryCount, forKey: .entryCount)
        try c.encode(topic.lastCapturedAt, forKey: .lastCapturedAt)
        try c.encode(topic.createdAt, forKey: .createdAt)
        try c.encode(topic.updatedAt, forKey: .updatedAt)
        try c.encode(topic.archivedAt, forKey: .archivedAt)
        try c.encode(topic.schedule.map(ScheduleDTO.init), forKey: .schedule)
        try c.encode(topic.scheduleUpdatedAt, forKey: .scheduleUpdatedAt)
        try c.encodeNil(forKey: .due)
        try c.encode(topic.questions.map(QuestionDTO.init), forKey: .questions)
    }
}

/// A request held "in the network". The request reaches the server when the gate opens; the
/// client gets the answer then, unless it gave up first.
final class Gate: Sendable {
    private struct State {
        var open = false
        var arrived = false
        var abandoned = false
        var openWaiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Whether the client gave up waiting (its task was cancelled).
    var abandoned: Bool { state.withLock { $0.abandoned } }

    /// Called by the server: records the arrival, then waits until the gate opens.
    func arrive() async {
        let arrivals = state.withLock { state in
            state.arrived = true
            defer { state.arrivalWaiters = [] }
            return state.arrivalWaiters
        }
        for waiter in arrivals { waiter.resume() }
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.open { return true }
                state.openWaiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    /// Waits until a request is held here.
    func arrival() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.arrived { return true }
                state.arrivalWaiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.openWaiters = [] }
            return state.openWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func abandon() { state.withLock { $0.abandoned = true } }

    /// Teardown: opens the gate and also releases anyone still waiting for an arrival that will
    /// never come, so no waiter outlives the test.
    func releaseAll() {
        let waiters = state.withLock { state in
            state.open = true
            defer {
                state.openWaiters = []
                state.arrivalWaiters = []
            }
            return state.openWaiters + state.arrivalWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// The first of a delivery and a cancellation, handed to one waiting client.
private final class Answer: Sendable {
    private let state = Mutex<
        (
            result: Result<HTTPResponse, TransportError>?, waiter: CheckedContinuation<HTTPResponse, any Error>?
        )
    >((nil, nil))

    private let cancelFlag = Mutex(false)

    /// Set when the client cancelled (`answerOnCancel` then answers from the handler).
    var cancelled: Bool {
        get { cancelFlag.withLock { $0 } }
        set { cancelFlag.withLock { $0 = newValue } }
    }

    func value() async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<HTTPResponse, TransportError>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready.mapError { $0 as any Error }) }
        }
    }

    func resume(_ result: Result<HTTPResponse, TransportError>) {
        let waiter = state.withLock { state -> CheckedContinuation<HTTPResponse, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result.mapError { $0 as any Error })
    }
}
