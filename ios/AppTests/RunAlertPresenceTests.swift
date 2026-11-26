import Foundation
import QuickrData
import Testing
import UserNotifications

@testable import QuickR

/// T2-M1 (timers2.md §9.1): a foreground run alert's haptic trigger and its 10 s inline label.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RunAlertPresenceTests {
    static func info(run: String = "0A00-RUN", label: String = "Half way") -> QuickrNotificationInfo {
        QuickrNotificationInfo(
            kind: RunAlerts.kind, origin: .local, serverId: "s", topicId: "t", runId: run, alertLabel: label,
            fireAtMs: 1)
    }

    @Test func anAlertBumpsTheHapticAndShowsItsLabelOnItsRunFor10Seconds() async throws {
        let gate = SleepGate()
        let presence = RunAlertPresence(sleep: { duration in try await gate.wait(duration) })
        presence.present(Self.info())
        #expect(presence.presented == 1)
        #expect(presence.label(runId: "0a00-run") == "Half way")
        #expect(presence.label(runId: "other") == nil)
        let slept = await gate.next()
        #expect(slept == RunAlertPresence.inlineDuration)
        await gate.release()
        for _ in 0..<100 where presence.shown != nil { await Task.yield() }
        #expect(presence.label(runId: "0a00-run") == nil)
        #expect(presence.presented == 1)
    }

    @Test func aSecondAlertRestartsTheTenSecondsAndAReminderChangesNothing() async throws {
        let gate = SleepGate()
        let presence = RunAlertPresence(sleep: { duration in try await gate.wait(duration) })
        presence.present(Self.info(label: "Half way"))
        _ = await gate.next()
        presence.present(Self.info(label: "Go"))
        _ = await gate.next()
        #expect(presence.presented == 2)
        // The first sleep was cancelled; the second's end clears.
        await gate.release()
        for _ in 0..<100 where presence.shown != nil { await Task.yield() }
        #expect(presence.shown == nil)

        presence.present(QuickrNotificationInfo(kind: "due", serverId: "s"))
        #expect(presence.presented == 2 && presence.shown == nil)
    }

    @Test func runAlertsAreBannersWithSound() {
        #expect(NotificationResponder.alertPresentation == [.banner, .sound])
    }
}

/// Holds each `sleep` until released; records the durations asked for.
private actor SleepGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var asked: [Duration] = []
    private var watchers: [CheckedContinuation<Duration, Never>] = []

    func wait(_ duration: Duration) async throws {
        if watchers.isEmpty { asked.append(duration) } else { watchers.removeFirst().resume(returning: duration) }
        await withCheckedContinuation { waiting.append($0) }
        try Task.checkCancellation()
    }

    /// The next sleep's duration, once one is asked for.
    func next() async -> Duration {
        if !asked.isEmpty { return asked.removeFirst() }
        return await withCheckedContinuation { watchers.append($0) }
    }

    func release() {
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}
