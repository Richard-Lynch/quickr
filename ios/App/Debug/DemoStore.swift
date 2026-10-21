#if DEBUG
import Foundation
import QuickrCore
@_spi(Testing) import QuickrData

/// `-QuickrDemoStore`: launches over a fresh store seeded with demo topics (due, overdue, soon,
/// later, unscheduled, archived; chip, number and no quick-log), offline, for the HOME and TILES UI
/// tests and screenshots. Debug builds only.
enum DemoStore {
    static let argument = "-QuickrDemoStore"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-QuickrDemoOutbox` (with `-QuickrDemoStore`): Water also has a log waiting to sync and one
    /// the server refused, for the entries list's pinned rows.
    static var withOutbox: Bool { ProcessInfo.processInfo.arguments.contains("-QuickrDemoOutbox") }

    /// The demo environment: the store is seeded before the session opens.
    @MainActor static func environment() -> AppEnvironment {
        let location = StoreLocation(
            root: URL.temporaryDirectory.appending(path: "quickr-demo-\(UUID().uuidString)"))
        return AppEnvironment(
            settings: AppSettings(defaults: UserDefaults(suiteName: "quickr-demo-\(UUID().uuidString)")!),
            prepare: { try? await seed(location) },
            makeSession: { try AppSession(configuration: .init(location: location, transport: OfflineTransport())) })
    }

    static func seed(_ location: StoreLocation, now: Date = Date()) async throws {
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try await partitions.createStore(serverId: "demo-server", baseURL: "https://quickr.example")
        try await partitions.registry.setActive("demo-server")
        let topics = topics(now: now)
        try await store.writer.write { db in
            for topic in topics {
                _ = try ServerLayer.upsert(db, topic: topic)
                // Its one version, as a sync would bring it (the edit screen reads an entry's version).
                _ = try ServerLayer.insert(
                    db, version: TopicVersion(version: 1, questions: topic.questions, createdAt: topic.createdAt),
                    id: entryId(topic: topic.id, index: 9_999), topicId: topic.id)
                // The store derives entry counts and the last entry from its entries.
                guard let last = topic.lastCapturedAt else { continue }
                for n in 0..<topic.entryCount {
                    let at = last.addingTimeInterval(-Double(n) * 86_400)
                    let entry = Entry(
                        id: entryId(topic: topic.id, index: n), topicId: topic.id, version: 1, revision: 1,
                        // A second source, so the entries list offers a source filter.
                        source: n % 4 == 3 ? "shortcut" : "demo", channel: .ios,
                        capturedAt: at, createdAt: at, updatedAt: at, answers: answers[topic.slug] ?? [:])
                    _ = try ServerLayer.upsert(db, entry: entry)
                }
            }
            // A known epoch, as after a bootstrap: without one the outbox makes no claims, so a
            // quick-log's `sendNow` would wait out its whole window before reporting "queued".
            try db.execute(sql: "UPDATE sync_state SET epoch = 'demo-epoch'")
        }
        if withOutbox { try await seedOutbox(store, now: now) }
    }

    /// The refused edit's error: a 422 whose `Problem` puts the message on the glasses field.
    static let refusedEditError = #"""
        {"message": "Some answers need attention", "status": 422,
         "body": {"code": "invalid_answers", "detail": "Some answers need attention",
                  "errors": [{"loc": ["body", "answers", "glasses"], "message": "Must be at most 20"}]}}
        """#

    /// The refused and the waiting Water log's ids (links in UI tests).
    static let refusedEntry = UUID(uuidString: "00000000-0000-4000-a000-0000000000f1")!
    static let waitingEntry = UUID(uuidString: "00000000-0000-4000-a000-0000000000f2")!

    /// Demo entry ids: the topic's number and the entry's index (0 is the newest), so UI tests can
    /// link to one: `00000000-0000-4000-9002-000000000000` is Water's newest.
    static func entryId(topic: UUID, index: Int) -> UUID {
        let n = Int(topic.uuidString.suffix(12)) ?? 0
        return UUID(uuidString: String(format: "00000000-0000-4000-9%03d-%012d", n, index))!
    }

    /// A pending and a failed Water log (the failed one older, logged first).
    static func seedOutbox(_ store: LocalStore, now: Date) async throws {
        let water = TopicRef(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, slug: "water", name: "Water")
        func create(_ id: UUID, _ glasses: Int, minutesAgo: Double) -> NewOutboxItem {
            NewOutboxItem(
                id: id,
                payload: .entryCreate(
                    topic: water,
                    body: EntryCreateDTO(
                        id: nil, answers: ["glasses": .int(glasses)], source: "ios",
                        capturedAt: now.addingTimeInterval(-minutesAgo * 60), version: 1)),
                origin: .app)
        }
        let failed = try await store.outbox.appendRawForTesting(create(refusedEntry, 25, minutesAgo: 90))
        _ = try await store.outbox.appendRawForTesting(create(waitingEntry, 5, minutesAgo: 5))
        // An edit of Water's second-newest entry that the server refused (99 glasses: over the max).
        let water2 = entryId(topic: UUID(uuidString: water.id)!, index: 1)
        let refusedEdit = try await store.outbox.appendRawForTesting(
            NewOutboxItem(
                payload: .entryUpdate(
                    entryId: water2.wireString, topicId: water.id,
                    patch: EntryUpdateDTO(answers: ["glasses": .int(99)])),
                baseRevision: 1, origin: .app))
        // A later edit of the same entry, waiting behind the refused one (2 glasses, a note).
        _ = try await store.outbox.appendRawForTesting(
            NewOutboxItem(
                payload: .entryUpdate(
                    entryId: water2.wireString, topicId: water.id,
                    patch: EntryUpdateDTO(answers: ["glasses": .int(2)], notes: "later")),
                origin: .app))
        try await store.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected', last_error_json = ?
                    WHERE id = ?
                    """,
                arguments: [#"{"message":"glasses: must be at most 20","status":422}"#, failed.id])
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected', last_error_json = ?
                    WHERE id = ?
                    """,
                arguments: [Self.refusedEditError, refusedEdit.id])
        }
    }

    /// Every demo entry's answers, by topic slug: what the tiles show as "Last …" and prefill.
    static let answers: [String: [String: AnswerValue]] = [
        "water": ["glasses": .int(3)],
        "headache": ["severity": .string("mild")],
        "mood": ["mood": .string("good")],
    ]

    /// Interval schedules make the due states relative to `now`, so every launch looks the same.
    static func topics(now: Date) -> [Topic] {
        let zone = TimeZone.current.identifier
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func every(_ minutes: Int) -> Schedule { .interval(.init(everyMinutes: minutes, timezone: zone)) }
        func topic(
            _ n: Int, _ slug: String, _ name: String, description: String = "", status: TopicStatus = .active,
            entries: Int = 0, last: Date? = nil, schedule: Schedule? = nil, questions: [Question]
        ) -> Topic {
            Topic(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, slug: slug, name: name,
                description: description, status: status, currentVersion: 1, revision: 1,
                questionCount: questions.count, entryCount: entries, lastCapturedAt: last, createdAt: ago(60 * 24 * 30),
                updatedAt: ago(60 * 24 * Double(n)), archivedAt: status == .archived ? ago(60 * 24) : nil,
                schedule: schedule, scheduleUpdatedAt: schedule == nil ? nil : ago(60 * 24 * 30), questions: questions)
        }
        let glasses = Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20, unit: "glasses")))
        let severity = Question(
            key: "severity", label: "Severity",
            kind: .choice(
                .init(options: ["none", "mild", "moderate", "severe"].map { .init(value: $0, label: $0.capitalized) })))
        let minutes = Question(key: "minutes", label: "Minutes", kind: .int(.init(min: 1)))
        let kind = Question(
            key: "kind", label: "Kind",
            kind: .choice(.init(options: [.init(value: "run", label: "Run"), .init(value: "gym", label: "Gym")])))
        let mood = Question(
            key: "mood", label: "Mood",
            kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "meh", label: "Meh")])))
        let hours = Question(
            key: "hours", label: "Hours slept", helpText: "Including naps", kind: .double(.init(decimals: 1)))
        let note = Question(key: "note", label: "Note", required: false, kind: .string(.init()))
        return [
            topic(1, "meds", "Medication", entries: 42, last: ago(300), schedule: every(240), questions: [note]),
            topic(2, "water", "Water", entries: 120, last: ago(130), schedule: every(120), questions: [glasses]),
            topic(3, "stretch", "Stretch", entries: 9, last: ago(150), schedule: every(180), questions: [note]),
            topic(
                4, "plants", "Water the plants", entries: 6, last: ago(60 * 24), schedule: every(60 * 24 * 3),
                questions: [note]),
            topic(5, "mood", "Mood", description: "How the day felt", entries: 30, last: ago(45), questions: [mood]),
            topic(6, "sleep", "Sleep", questions: [hours]),
            // Quick-log chips, with a last answer.
            topic(8, "headache", "Headache", entries: 12, last: ago(20), questions: [severity]),
            // Two required questions: no quick-log.
            topic(9, "workout", "Workout", questions: [minutes, kind]),
            topic(
                7, "old-habit", "Old habit", status: .archived, entries: 3, last: ago(60 * 24 * 20), questions: [note]),
        ]
    }
}
#endif
