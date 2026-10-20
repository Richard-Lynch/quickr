#if DEBUG
import Foundation
import QuickrCore
import QuickrData

/// `-QuickrDemoStore`: launches over a fresh store seeded with demo topics (due, overdue, soon,
/// later, unscheduled, archived; chip, number and no quick-log), offline, for the HOME and TILES UI
/// tests and screenshots. Debug builds only.
enum DemoStore {
    static let argument = "-QuickrDemoStore"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

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
                // The store derives entry counts and the last entry from its entries.
                guard let last = topic.lastCapturedAt else { continue }
                for n in 0..<topic.entryCount {
                    let at = last.addingTimeInterval(-Double(n) * 86_400)
                    let entry = Entry(
                        id: UUID(), topicId: topic.id, version: 1, revision: 1, source: "demo", channel: .ios,
                        capturedAt: at, createdAt: at, updatedAt: at, answers: answers[topic.slug] ?? [:])
                    _ = try ServerLayer.upsert(db, entry: entry)
                }
            }
            // A known epoch, as after a bootstrap: without one the outbox makes no claims, so a
            // quick-log's `sendNow` would wait out its whole window before reporting "queued".
            try db.execute(sql: "UPDATE sync_state SET epoch = 'demo-epoch'")
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

/// Every request fails as if offline.
private struct OfflineTransport: Transport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
#endif
