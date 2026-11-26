import Foundation
import GRDB
import QuickrCore
import QuickrData
import Synchronization
import Testing

@testable import QuickR

/// M1-REVIEW P1-2 (timers2.md §9.1, "this device's taps"): a Live Activity button or a run intent
/// runs in the app's process with no `RootView` (iOS launches it in the background, or wakes it
/// suspended), so nothing observes the store for alerts. Each handler reschedules the run alerts
/// itself, after its write and while it holds the store, as it reconciles the Live Activity.
@MainActor @Suite(.serialized) struct RunAlertTapTests {
    /// Run, then Rest (60 s: "Half way" at 30 s, "Go" at 60 s). A lap from Run 1 opens Rest 1.
    static let timer = TopicTimer(
        steps: [],
        laps: [
            TopicTimer.LapType(key: "run", label: "Run"),
            TopicTimer.LapType(
                key: "rest", label: "Rest",
                alerts: [
                    TopicTimer.Alert(key: "half", label: "Half way", at: "t/2", atMs: 30_000),
                    TopicTimer.Alert(key: "go", label: "Go", at: "t", atMs: 60_000),
                ]),
        ],
        variables: [TopicTimer.Variable(name: "t", ms: 60_000)])

    /// The seeded store with Coffee timed by `timer`, and (when `open`) a run of it started 10 s
    /// ago, in Run 1.
    static func seeded(open: Bool) async throws -> (StoreLocation, Topic, String?) {
        let location = try await TestStores.seededLocation()
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        let topic = try #require(try await PlaceholderTopicRepository().topics().map(\.topic).first)
        let version = TopicVersion(version: topic.currentVersion, questions: [], timer: timer, createdAt: Date())
        var runId: String?
        var run: Run?
        if open {
            let id = UUID()
            let start = RunEvent(id: id.wireString, type: .start, at: RunInstant.milliseconds(Date()) - 10_000)
            let state = try RunFold.fold(runId: id.wireString, timer: timer, events: [start])
            run = Run(
                id: id, topicId: topic.id, version: topic.currentVersion, status: .running, revision: 1,
                startedAt: start.at, endedAt: nil, edited: false,
                events: [Run.StoredEvent(event: start, arrival: 1, effect: .applied, source: "web")], state: state,
                aliases: [])
            runId = id.wireString
        }
        try await store.writer.write { [run] db in
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topic.id)
            if let run { _ = try ServerLayer.upsert(db, run: run) }
        }
        return (location, topic, runId)
    }

    /// A live environment whose notification centre is `center`, its cooldown on `clock`.
    static func environment(
        _ location: StoreLocation, center: RecordingAlertCenter, clock: ManualRunClock
    ) -> AppEnvironment {
        let environment = AppEnvironment.live(
            location: location, defaults: UserDefaults(suiteName: "alert-tap-tests-\(UUID().uuidString)")!,
            keychain: InMemoryKeychain(), transport: RecordingTransport(), categoryCenter: center,
            runClock: { clock.now })
        environment.activityTapFlushBudget = .seconds(60)
        return environment
    }

    @Test("a Live Activity's Lap schedules the new lap's alerts, and its Pause cancels them, with no RootView")
    func activityTapsReschedule() async throws {
        let (location, topic, seededRun) = try await Self.seeded(open: true)
        defer { TestStores.remove(location) }
        let runId = try #require(seededRun)
        let center = RecordingAlertCenter()
        let clock = ManualRunClock()
        let environment = Self.environment(location, center: center, clock: clock)
        defer { Task { await environment.session?.shutdown() } }
        #expect(environment.session?.store == nil, "launched for the tap: nothing bound, no RootView")
        #expect(center.alertIds.isEmpty)

        try await environment.handleActivityTap(
            RunActivityTap(button: .lap, serverId: "test-server", topicId: topic.id, runId: runId, seg: 0))
        let prefix = "quickr.alert.\(runId.lowercased()).1."
        #expect(center.alertIds == [prefix + "go", prefix + "half"], "Rest 1's alerts, scheduled by the tap")

        clock.advance(by: .milliseconds(500))
        try await environment.handleActivityTap(
            RunActivityTap(button: .pause, serverId: "test-server", topicId: topic.id, runId: runId, seg: 1))
        #expect(center.alertIds.isEmpty, "paused: the pending alerts are cancelled")
    }

    @Test("a run intent's start then lap schedules the lap's alerts, with no RootView")
    func intentTapsReschedule() async throws {
        let (location, topic, _) = try await Self.seeded(open: false)
        defer { TestStores.remove(location) }
        let center = RecordingAlertCenter()
        let clock = ManualRunClock()
        let environment = Self.environment(location, center: center, clock: clock)
        defer { Task { await environment.session?.shutdown() } }

        let auto = RunIntentRequest(action: .auto, topicId: topic.id, origin: .widget)
        let started = try await environment.handleRunIntent(auto)
        #expect(started.started)
        #expect(center.alertIds.isEmpty, "Run 1 has no alerts")
        clock.advance(by: .milliseconds(500))
        _ = try await environment.handleRunIntent(auto)
        let events = try await LiveActivityTapTests.runEvents(location)
        #expect(events == ["start", "lap"])
        #expect(center.alertIds.count == 2, "Rest 1's alerts, scheduled by the intent: \(center.alertIds)")
        #expect(center.alertIds.allSatisfy { $0.hasPrefix(RunAlerts.identifierPrefix) })
    }
}

/// A notification centre in memory that keeps the pending requests: what the scheduler reads
/// and writes.
final class RecordingAlertCenter: NotificationCenterProtocol {
    private let pending = Mutex<[String: LocalNotificationRequest]>([:])

    /// The pending run alerts' identifiers, sorted.
    var alertIds: [String] {
        pending.withLock { $0.keys.filter { $0.hasPrefix(RunAlerts.identifierPrefix) }.sorted() }
    }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {}
    func notificationCategories() async -> [NotificationCategorySpec] { [] }
    func deliveredNotifications() async -> [NotificationSnapshot] { [] }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

    func pendingNotificationRequests() async -> [NotificationSnapshot] {
        pending.withLock { requests in
            requests.values.map { request in
                NotificationSnapshot(
                    id: request.id, categoryIdentifier: request.categoryIdentifier ?? "",
                    threadIdentifier: request.threadIdentifier ?? "", date: request.fireAt ?? request.fireDate,
                    quickr: request.quickr, title: request.title, body: request.body, sound: request.sound,
                    interruptionLevel: request.interruptionLevel)
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pending.withLock { requests in for id in identifiers { requests[id] = nil } }
    }

    func add(_ request: LocalNotificationRequest) async throws {
        pending.withLock { $0[request.id] = request }
    }

    func setBadgeCount(_ count: Int) async throws {}
    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> Bool { true }
}
