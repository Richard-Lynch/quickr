#if DEBUG || QUICKR_PERF
import Foundation
import GRDB
import QuickrCore

/// A store the size of a heavy user's, for performance tests and the perf launch (PERF): 20 topics
/// of the shapes people use (a chip, a number, a mixed four-question form, a multi-select, notes),
/// up to three versions each, 10,000 entries skewed towards a few busy topics over the past year,
/// schedules on some, two archived, and an outbox with items in every state. Deterministic: the
/// same spec gives the same rows, so timings compare across runs.
///
/// Debug builds (and `QUICKR_PERF` release builds): the app's `-QuickrPerfStore` launch and the
/// host tests use it.
public enum PerfSeed {
    public struct Spec: Sendable, Hashable {
        public var topics: Int
        public var entries: Int
        public var serverId: String
        public var epoch: String
        public var baseURL: String
        /// The newest entry is a little before this; the oldest about a year before.
        public var now: Date

        public init(
            topics: Int = 20, entries: Int = 10_000, serverId: String = "5eed0000-0000-4000-8000-00000000e9c4",
            epoch: String = "00000000-0000-4000-8000-00000000e9c4", baseURL: String = "https://quickr.test",
            now: Date = Date(timeIntervalSince1970: 1_790_000_000)
        ) {
            self.topics = topics
            self.entries = entries
            self.serverId = serverId
            self.epoch = epoch
            self.baseURL = baseURL
            self.now = now
        }

        public static let standard = Spec()
    }

    public struct Summary: Sendable, Hashable {
        public var topics: Int
        public var versions: Int
        public var entries: Int
        /// Outbox items by state.
        public var outbox: [OutboxState: Int]
    }

    /// Registers the server, makes it active, creates its store (bootstrapped, at `spec.epoch`)
    /// and fills it.
    public static func seed(at location: StoreLocation, spec: Spec = .standard, notifier: (any ChangeNotifier)? = nil)
        async throws -> Summary
    {
        let partitions = try StorePartitions.open(at: location, notifier: notifier)
        let store = try await partitions.createStore(serverId: spec.serverId, baseURL: spec.baseURL)
        try await partitions.registry.setActive(spec.serverId)
        return try await store.writer.write { db in try fill(db, spec: spec) }
    }

    /// Fills a store whose `sync_state` exists: the server layer, a bootstrapped sync state at
    /// `spec.epoch`, and the outbox.
    public static func fill(_ db: Database, spec: Spec = .standard) throws -> Summary {
        var random = SplitMix(seed: 0x9E37_79B9_7F4A_7C15)
        let topics = (0..<spec.topics).map { topic($0, spec: spec) }
        var versions = 0
        for topic in topics {
            _ = try ServerLayer.upsert(db, topic: topic)
            for number in 1...topic.currentVersion {
                _ = try ServerLayer.insert(
                    db,
                    version: TopicVersion(
                        version: number, questions: questions(kind: kindOf(topic), version: number),
                        changeNote: "v\(number)",
                        createdAt: spec.now.addingTimeInterval(-Double(400 - number * 30) * 86_400)),
                    id: uuid(Ids.version + Int(topicIndex(topic)) * 16 + number), topicId: topic.id)
                versions += 1
            }
        }
        // Skewed: topic i weighs 1 / (i + 1), so the first few hold most entries.
        let weights = topics.indices.map { 1.0 / Double($0 + 1) }
        let total = weights.reduce(0, +)
        var counts = weights.map { Int(Double(spec.entries) * $0 / total) }
        counts[0] += spec.entries - counts.reduce(0, +)
        var entryNumber = 0
        for (index, topic) in topics.enumerated() {
            for _ in 0..<counts[index] {
                entryNumber += 1
                let ago = Double(random.next(below: 365 * 24 * 60)) * 60 + 600
                let at = spec.now.addingTimeInterval(-ago)
                let version = 1 + random.next(below: topic.currentVersion)
                let entry = Entry(
                    id: entryId(entryNumber), topicId: topic.id, version: version, revision: 1 + random.next(below: 2),
                    source: ["ios", "web", "mcp"][random.next(below: 3)], channel: .ios, capturedAt: at, createdAt: at,
                    updatedAt: at, notes: random.next(below: 10) == 0 ? "note \(entryNumber)" : "", meta: [:],
                    answers: answers(kind: kindOf(topic), version: version, random: &random))
                _ = try ServerLayer.upsert(db, entry: entry)
            }
        }
        try db.execute(
            sql: """
                UPDATE sync_state SET epoch = ?, bootstrap_complete = 1, cursor = ?, head_seen = ? WHERE id = 1
                """,
            arguments: [spec.epoch, entryNumber + 100, entryNumber + 100])
        let outbox = try fillOutbox(db, topics: topics, spec: spec, random: &random)
        return Summary(topics: topics.count, versions: versions, entries: entryNumber, outbox: outbox)
    }

    // MARK: - Topics

    enum Kind: Int, CaseIterable {
        case chip, number, mixed, multi, notes
    }

    static func kindOf(_ topic: Topic) -> Kind { Kind(rawValue: Int(topicIndex(topic)) % Kind.allCases.count)! }

    static func topicIndex(_ topic: Topic) -> UInt64 {
        UInt64(topic.id.uuidString.suffix(12), radix: 16)! - UInt64(Ids.topic)
    }

    static func topic(_ index: Int, spec: Spec) -> Topic {
        let kind = Kind(rawValue: index % Kind.allCases.count)!
        let names = ["Headache", "Water", "Workout", "Symptoms", "Journal"]
        let name = "\(names[kind.rawValue]) \(index / Kind.allCases.count + 1)"
        let current = 1 + index % 3
        let archived = index >= spec.topics - 2
        let created = spec.now.addingTimeInterval(-400 * 86_400)
        let schedule: Schedule? =
            index % 4 == 0
            ? .daily(.init(times: [TimeOfDay("09:00")!, TimeOfDay("21:00")!], timezone: "Europe/London")) : nil
        let questions = questions(kind: kind, version: current)
        return Topic(
            id: uuid(Ids.topic + index), slug: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name,
            description: "", status: archived ? .archived : .active, currentVersion: current, revision: 1 + current,
            questionCount: questions.count, entryCount: 0, lastCapturedAt: nil, createdAt: created,
            updatedAt: created, archivedAt: archived ? spec.now.addingTimeInterval(-86_400) : nil, schedule: schedule,
            scheduleUpdatedAt: schedule == nil ? nil : created, questions: questions)
    }

    static func options(_ values: [String]) -> Question.ChoiceRules {
        .init(options: values.map { EnumOption(value: $0, label: $0.capitalized) })
    }

    /// Later versions add a question, as a topic grows.
    static func questions(kind: Kind, version: Int) -> [Question] {
        var questions: [Question]
        switch kind {
        case .chip:
            questions = [
                Question(key: "severity", label: "Severity", kind: .choice(options(["none", "mild", "severe"])))
            ]
        case .number:
            questions = [
                Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20, unit: "glasses")))
            ]
        case .mixed:
            questions = [
                Question(key: "type", label: "Type", kind: .choice(options(["run", "yoga", "swim", "bike"]))),
                Question(key: "duration", label: "Duration", kind: .int(.init(min: 1, max: 600, unit: "min"))),
                Question(
                    key: "distance", label: "Distance", required: false, kind: .double(.init(decimals: 2, unit: "km"))),
                Question(key: "rpe", label: "RPE", kind: .int(.init(min: 1, max: 10))),
            ]
        case .multi:
            questions = [
                Question(
                    key: "symptoms", label: "Symptoms",
                    kind: .choice(
                        .init(
                            options: ["cough", "fever", "tired", "sore"].map {
                                EnumOption(value: $0, label: $0.capitalized)
                            }, multiple: true)))
            ]
        case .notes:
            questions = [Question(key: "text", label: "Text", kind: .string(.init()))]
        }
        if version >= 2 {
            questions.append(Question(key: "mood", label: "Mood", required: false, kind: .int(.init(min: 1, max: 5))))
        }
        if version >= 3 {
            questions.append(
                Question(
                    key: "where", label: "Where", required: false, kind: .choice(options(["home", "work", "out"]))))
        }
        return questions
    }

    static func answers(kind: Kind, version: Int, random: inout SplitMix) -> [String: AnswerValue] {
        var answers: [String: AnswerValue]
        switch kind {
        case .chip: answers = ["severity": .string(["none", "mild", "severe"][random.next(below: 3)])]
        case .number: answers = ["glasses": .int(random.next(below: 12))]
        case .mixed:
            answers = [
                "type": .string(["run", "yoga", "swim", "bike"][random.next(below: 4)]),
                "duration": .int(10 + random.next(below: 80)), "rpe": .int(1 + random.next(below: 10)),
            ]
            if random.next(below: 2) == 0 { answers["distance"] = .double(Double(random.next(below: 2000)) / 100) }
        case .multi:
            let all = ["cough", "fever", "tired", "sore"]
            answers = ["symptoms": .strings(all.filter { _ in random.next(below: 2) == 0 })]
        case .notes: answers = ["text": .string("Day \(random.next(below: 1000)): fine.")]
        }
        if version >= 2, random.next(below: 2) == 0 { answers["mood"] = .int(1 + random.next(below: 5)) }
        if version >= 3, random.next(below: 3) == 0 { answers["where"] = .string("home") }
        return answers
    }

    // MARK: - Outbox

    /// Creates waiting to send, a few sending or unconfirmed, deletes in their undo window, refused
    /// items of each kind, and changes queued behind a refused one.
    static func fillOutbox(_ db: Database, topics: [Topic], spec: Spec, random: inout SplitMix) throws
        -> [OutboxState: Int]
    {
        var states: [OutboxState: Int] = [:]
        let active = topics.filter { $0.status == .active }
        var items = 0
        func append(_ payload: OutboxPayload, base: Int? = nil) throws -> OutboxItem {
            items += 1
            return try OutboxStorage.append(
                db, NewOutboxItem(id: uuid(Ids.outbox + items), payload: payload, baseRevision: base, origin: .app),
                now: spec.now)
        }
        func set(_ item: OutboxItem, _ state: OutboxState, reason: OutboxFailureReason? = nil, maybe: Bool = false)
            throws
        {
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = ?, failure_reason = ?, maybe_delivered = ?,
                      attempts = CASE WHEN ? IN ('in_flight', 'uncertain', 'failed') THEN 1 ELSE 0 END,
                      claim_token = CASE WHEN ? = 'in_flight' THEN 'perf-claim' END,
                      claim_owner = CASE WHEN ? = 'in_flight' THEN 'app:perf' END,
                      claim_layer_gen = CASE WHEN ? = 'in_flight' THEN 1 END,
                      claim_epoch = CASE WHEN ? = 'in_flight' THEN ? END,
                      last_error_json = CASE WHEN ? = 'failed' THEN '{"message":"Refused by the server"}' END
                    WHERE id = ?
                    """,
                arguments: [
                    state.rawValue, reason?.rawValue, maybe, state.rawValue, state.rawValue, state.rawValue,
                    state.rawValue, state.rawValue, spec.epoch, state.rawValue, item.id,
                ])
            states[state, default: 0] += 1
        }
        func create(_ topic: Topic, minutes: Int) -> OutboxPayload {
            .entryCreate(
                topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name),
                body: EntryCreateDTO(
                    id: nil, answers: answers(kind: kindOf(topic), version: topic.currentVersion, random: &random),
                    source: "ios", capturedAt: spec.now.addingTimeInterval(-Double(minutes) * 60),
                    version: topic.currentVersion))
        }
        for n in 0..<40 {
            let item = try append(create(active[n % active.count], minutes: n * 7))
            switch n {
            case 0..<2: try set(item, .inFlight)
            case 2..<5: try set(item, .uncertain, maybe: true)
            case 5..<8: try set(item, .failed, reason: [.rejected, .topicArchived, .futureTime][n - 5])
            default: states[.pending, default: 0] += 1
            }
        }
        // Edits of synced entries, one refused (conflict) with an edit queued behind it.
        for n in 0..<6 {
            let entry = entryId(1 + n * max(1, spec.entries / 7))
            let topic = try String.fetchOne(
                db, sql: "SELECT topic_id FROM entry WHERE id = ?", arguments: [entry.wireString])!
            let item = try append(
                .entryUpdate(entryId: entry.wireString, topicId: topic, patch: EntryUpdateDTO(notes: "edited \(n)")),
                base: 1)
            if n == 0 { try set(item, .failed, reason: .conflict) } else { states[.pending, default: 0] += 1 }
        }
        _ = try append(
            .entryUpdate(
                entryId: entryId(1).wireString,
                topicId: try String.fetchOne(
                    db, sql: "SELECT topic_id FROM entry WHERE id = ?", arguments: [entryId(1).wireString])!,
                patch: EntryUpdateDTO(notes: "behind the conflict")), base: 1)
        states[.pending, default: 0] += 1
        // Deletes: three in their undo window, two waiting, one whose entry went elsewhere.
        for n in 0..<6 {
            let entry = entryId(spec.entries / 2 + n)
            let topic = try String.fetchOne(
                db, sql: "SELECT topic_id FROM entry WHERE id = ?", arguments: [entry.wireString])!
            let item = try append(.entryDelete(entryId: entry.wireString, topicId: topic), base: 1)
            switch n {
            case 0..<3:
                try db.execute(
                    sql: "UPDATE outbox_item SET state = 'held', hold_boot_id = 'perf-boot', hold_ct = 1 WHERE id = ?",
                    arguments: [item.id])
                states[.held, default: 0] += 1
            case 5: try set(item, .failed, reason: .deletedElsewhere)
            default: states[.pending, default: 0] += 1
            }
        }
        // An archive waiting to send.
        _ = try append(.topicArchive(topicId: active.last!.id.wireString), base: active.last!.revision)
        states[.pending, default: 0] += 1
        return states
    }

    // MARK: - Ids and randomness

    /// Each kind of row numbers its ids from its own base, so ids never repeat across kinds.
    enum Ids {
        static let topic = 0x10_0000_0000
        static let version = 0x20_0000_0000
        static let entry = 0x30_0000_0000
        static let outbox = 0x40_0000_0000
    }

    /// The seed's n-th entry (from 1).
    public static func entryId(_ n: Int) -> UUID { uuid(Ids.entry + n) }

    /// The seed's n-th topic (from 0).
    public static func topicId(_ n: Int) -> UUID { uuid(Ids.topic + n) }

    /// A fixed id from a number: `00000000-0000-4000-8000-<n>`.
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(n)))!
    }

    /// SplitMix64: small, fast, and the same sequence everywhere.
    struct SplitMix {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }
}
#endif
