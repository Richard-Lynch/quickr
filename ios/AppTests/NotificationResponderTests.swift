import Foundation
import QuickrCore
import QuickrData
import Testing
import UIKit
import UserNotifications

@testable import QuickR

/// The notification delegate's side of the handler (notifications.md §7): a response's parts
/// become the handler's input, and a body tap opens its record screen with any tap-to-fix text.
/// QuickrData's `NotificationActionHandlerTests` cover the actions themselves.
@MainActor
struct NotificationResponderTests {
    static let topicId = "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c01"  // PlaceholderTopicRepository.coffee

    static func content(_ quickr: [String: Any]?) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Coffee"
        if let quickr { content.userInfo = ["quickr": quickr] }
        return content
    }

    static let reminder: [String: Any] = [
        "v": 1, "kind": "due", "server_id": "test-server", "topic_id": topicId, "topic_slug": "coffee",
        "version": 1, "due_since": "2026-10-17T08:00:00Z", "url": "/t/coffee/record",
        "quick_log": [
            "type": "enum", "key": "cups", "label": "Cups", "total_options": 1,
            "options": [["value": "one", "label": "One"]],
        ],
    ]

    @Test func aResponseBecomesTheHandlersInput() throws {
        let body = NotificationResponder.input(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil, content: Self.content(Self.reminder)
        )
        #expect(body.action == .open && body.title == "Coffee")
        let quickr = try #require(body.quickr)
        #expect(quickr.topicId == Self.topicId && quickr.dueSince == "2026-10-17T08:00:00Z" && quickr.version == 1)
        guard case .choice(let choice) = quickr.quickLog else {
            Issue.record("the descriptor decodes")
            return
        }
        #expect(choice.options.map(\.value) == ["one"])

        let dismiss = NotificationResponder.input(
            actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil, content: Self.content(Self.reminder)
        )
        #expect(dismiss.action == .dismiss)
        let typed = NotificationResponder.input(
            actionIdentifier: "q1|a|b|1|cups|i|", userText: "7,5", content: Self.content(Self.reminder))
        #expect(typed.action == .custom("q1|a|b|1|cups|i|") && typed.userText == "7,5")
        let foreign = NotificationResponder.input(actionIdentifier: "x", userText: nil, content: Self.content(nil))
        #expect(foreign.quickr == nil, "not quickR's")
    }

    @Test func aTapToFixOpensTheRecordScreenWithItsTextOnce() async throws {
        let seeded = try await TestStores.seededLocation()
        defer { TestStores.remove(seeded) }
        let environment = AppEnvironment.live(location: seeded, categoryCenter: nil)
        let fix: [String: Any] = [
            "v": 1, "kind": "fix", "server_id": "test-server", "topic_id": Self.topicId, "url": "/t/coffee/record",
            "prefill": ["cups": "abc"],
        ]
        let input = NotificationResponder.input(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil, content: Self.content(fix))
        await environment.handleNotificationResponse(input)
        #expect(environment.router.path.last == .record(TopicLinkRef("coffee")!))
        let topic = try #require(UUID(uuidString: Self.topicId))
        #expect(environment.takeRecordPrefill(topicId: UUID()) == nil, "another topic's screen doesn't take it")
        #expect(environment.takeRecordPrefill(topicId: topic) == ["cups": "abc"])
        #expect(environment.takeRecordPrefill(topicId: topic) == nil, "once")

        // A reminder's body opens its record screen with nothing to prefill.
        environment.router.path = []
        await environment.handleNotificationResponse(
            NotificationResponder.input(
                actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil,
                content: Self.content(Self.reminder)))
        #expect(environment.router.path.last == .record(TopicLinkRef("coffee")!))
        #expect(environment.recordPrefill == nil)
        await environment.session?.shutdown()
    }

    // MARK: - Exactly one completion, whenever the background task expires (Codex r1)

    @Test func expiryBeforeTheWorkFinishesAtOnceAndOnlyOnce() async {
        let tasks = FakeBackgroundTasks(expireOnBegin: true)
        var completions = 0
        await NotificationResponder.run(tasks: tasks, completion: { completions += 1 }, work: {})
        #expect(completions == 1)
        #expect(tasks.ended == [tasks.issued], "the task is ended, even though it expired inside begin")
    }

    @Test func expiryDuringTheWorkFinishesAtOnceAndCancelsIt() async {
        let tasks = FakeBackgroundTasks()
        let gate = Gate()
        var completions = 0
        let cancelled = Flag()
        let run = Task {
            await NotificationResponder.run(
                tasks: tasks, completion: { completions += 1 },
                work: {
                    await gate.wait()
                    cancelled.value = Task.isCancelled
                })
        }
        while !gate.isWaiting { await Task.yield() }
        tasks.expire()
        #expect(completions == 1, "completed at expiry, not when the work ends")
        #expect(tasks.ended == [tasks.issued])
        gate.open()
        await run.value
        #expect(cancelled.value)
        #expect(completions == 1 && tasks.ended.count == 1)
    }

    @Test func expiryAfterTheWorkChangesNothing() async {
        let tasks = FakeBackgroundTasks()
        var completions = 0
        await NotificationResponder.run(tasks: tasks, completion: { completions += 1 }, work: {})
        #expect(completions == 1 && tasks.ended == [tasks.issued])
        tasks.expire()
        #expect(completions == 1 && tasks.ended.count == 1)
    }
}

@MainActor
private final class FakeBackgroundTasks: BackgroundTasking {
    let issued = UIBackgroundTaskIdentifier(rawValue: 42)
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expiration: (@MainActor () -> Void)?
    private let expireOnBegin: Bool

    init(expireOnBegin: Bool = false) { self.expireOnBegin = expireOnBegin }

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        self.expiration = expiration
        if expireOnBegin { expiration() }
        return issued
    }

    func end(_ task: UIBackgroundTaskIdentifier) { ended.append(task) }

    func expire() { expiration?() }
}

@MainActor
private final class Flag {
    var value = false
}

@MainActor
private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var isWaiting: Bool { waiter != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
