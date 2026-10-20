#if DEBUG
import Foundation
import GRDB
import QuickrCore
import QuickrData

/// `-QuickrDemoStore`: a throwaway store, active on a server nobody answers (127.0.0.1:9, so every
/// write queues "offline"), seeded with topics that cover the tile kinds: chips (due), a number
/// with a last value, a multi-question topic that logs through the record screen, an
/// unscheduled chip topic and an archived one. For screenshots and the tile UI tests.
enum DemoStore {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-QuickrDemoStore") }

    /// One per launch, so every UI test starts from the same seed.
    static let location = StoreLocation(
        root: URL.temporaryDirectory.appending(path: "quickr-demo-\(ProcessInfo.processInfo.processIdentifier)"))

    static let serverId = "demo-server"

    static func seed(_ partitions: StorePartitions) async {
        do {
            guard try await partitions.registry.repository.activeServerId() == nil else { return }
            let store = try await partitions.createStore(serverId: serverId, baseURL: "http://127.0.0.1:9")
            try await partitions.registry.setActive(serverId)
            let now = Date()
            let (topics, entries) = demo(now: now)
            try await store.writer.write { db in
                // As after a bootstrap: with an epoch the outbox attempts its sends (and fails
                // them fast against the closed port), so a log reports "queued" at once.
                try db.execute(sql: "UPDATE sync_state SET epoch = 'demo-epoch' WHERE id = 1")
                for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
                for entry in entries { _ = try ServerLayer.upsert(db, entry: entry) }
            }
        } catch {
            assertionFailure("demo store: \(error)")
        }
    }

    static func demo(now: Date) -> ([Topic], [Entry]) {
        let severity = ["None", "Mild", "Moderate", "Severe"].map { EnumOption(value: $0.lowercased(), label: $0) }
        let moods = ["Low", "OK", "Good"].map { EnumOption(value: $0.lowercased(), label: $0) }
        let headache = topic(
            "headache", "Headache", now: now, created: now - 86_400,
            schedule: .interval(.init(everyMinutes: 180, timezone: "UTC")), scheduleSet: now - 5 * 3600,
            questions: [
                Question(key: "severity", label: "Severity", required: true, kind: .choice(.init(options: severity))),
                Question(key: "notes", label: "Where", required: false, kind: .string(.init())),
            ])
        let water = topic(
            "water", "Water", now: now, created: now - 86_400,
            schedule: .interval(.init(everyMinutes: 120, timezone: "UTC")), scheduleSet: now - 86_400,
            questions: [
                Question(
                    key: "glasses", label: "Glasses", required: true,
                    kind: .int(.init(min: 0, max: 20, unit: "glasses")))
            ])
        let mood = topic(
            "mood", "Mood", now: now, created: now - 86_400, schedule: nil, scheduleSet: nil,
            questions: [
                Question(
                    key: "mood", label: "Mood", required: true,
                    kind: .choice(.init(options: moods)))
            ])
        let workout = topic(
            "workout", "Workout", now: now, created: now - 86_400, schedule: nil, scheduleSet: nil,
            questions: [
                Question(key: "type", label: "Type", required: true, kind: .choice(.init(options: severity))),
                Question(key: "minutes", label: "Minutes", required: true, kind: .int(.init(min: 0, unit: "min"))),
            ])
        var old = topic(
            "old-habit", "Old habit", now: now, created: now - 30 * 86_400, schedule: nil, scheduleSet: nil,
            questions: [
                Question(key: "done", label: "Done", required: true, kind: .choice(.init(options: severity)))
            ])
        old.status = .archived
        old.archivedAt = now - 86_400
        let entries = [
            entry(water, ["glasses": .int(3)], at: now - 4 * 3600),
            entry(headache, ["severity": .string("mild")], at: now - 6 * 3600),
        ]
        return ([headache, water, mood, workout, old], entries)
    }

    private static func topic(
        _ slug: String, _ name: String, now: Date, created: Date, schedule: Schedule?, scheduleSet: Date?,
        questions: [Question]
    ) -> Topic {
        Topic(
            id: UUID(), slug: slug, name: name, currentVersion: 1, revision: 1, questionCount: questions.count,
            createdAt: created, updatedAt: created, schedule: schedule, scheduleUpdatedAt: scheduleSet,
            questions: questions)
    }

    private static func entry(_ topic: Topic, _ answers: [String: AnswerValue], at date: Date) -> Entry {
        Entry(
            id: UUID(), topicId: topic.id, version: 1, revision: 1, source: "demo", channel: .ios, capturedAt: date,
            createdAt: date, updatedAt: date, answers: answers)
    }
}
#endif
