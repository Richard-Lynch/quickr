import Foundation
import QuickrTestSupport
import Testing

@testable import QuickrData

#if canImport(UserNotifications)
import UserNotifications
#endif

/// timers2.md §9.1: `LocalNotificationRequest` gains `interruptionLevel` and `fireAt`, backward
/// compatible; the fake records both; the system adapter maps them (R23's host half).
@Suite(.timeLimit(.minutes(1))) struct NotificationCenterProtocolTests {
    @Test("a request built as before keeps its v1 shape: no fireAt, the active level")
    func backwardCompatible() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let request = LocalNotificationRequest(
            id: "due-t-2026", title: "Mood", body: "How are you?", categoryIdentifier: "quickr.t.x", fireDate: due,
            sound: true)
        #expect(request.fireAt == nil)
        #expect(request.interruptionLevel == .active)
        #expect(request.fireDate == due)
        let snapshot = NotificationSnapshot(id: "a")
        #expect(snapshot.title == "" && snapshot.body == "" && !snapshot.sound)
        #expect(snapshot.interruptionLevel == .active)
    }

    @Test("the fake records fireAt, fireDate and the level, and lists the pending request at fireAt")
    func fakeRecordsBoth() async throws {
        let center = FakeNotificationCenter()
        let fireAt = Date(timeIntervalSince1970: 1_800_000_030)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        try await center.add(
            LocalNotificationRequest(
                id: "quickr.alert.r.1.half", title: "Intervals", body: "Half way · Rest 1", threadIdentifier: "topic-t",
                sound: true, fireAt: fireAt, interruptionLevel: .timeSensitive))
        try await center.add(LocalNotificationRequest(id: "due-t", title: "Mood", body: "", fireDate: due))
        let added = center.withState { $0.added }
        #expect(added.map(\.fireAt) == [fireAt, nil])
        #expect(added.map(\.fireDate) == [nil, due])
        #expect(added.map(\.interruptionLevel) == [.timeSensitive, .active])
        let pending = await center.pendingNotificationRequests()
        #expect(pending.map(\.date) == [fireAt, due])
        #expect(pending[0].title == "Intervals" && pending[0].body == "Half way · Rest 1" && pending[0].sound)
        #expect(pending[0].threadIdentifier == "topic-t")
        #expect(pending.map(\.interruptionLevel) == [.timeSensitive, .active])
        center.removePendingNotificationRequests(withIdentifiers: ["due-t"])
        #expect(center.withState { $0.removedPending } == ["due-t"])
    }

    @Test("quickr info: an alert's run_id, alert_label and fire_at_ms round-trip; v1 payloads omit them")
    func alertInfoKeys() throws {
        let info = QuickrNotificationInfo(
            kind: "alert", origin: .local, serverId: "s", topicId: "t", runId: "r", alertLabel: "Go",
            fireAtMs: 1_800_000_030_000)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
        #expect(json?["run_id"] as? String == "r")
        #expect(json?["alert_label"] as? String == "Go")
        #expect(json?["fire_at_ms"] as? Int == 1_800_000_030_000)
        #expect(json?["origin"] as? String == "local")
        #expect(try JSONDecoder().decode(QuickrNotificationInfo.self, from: JSONEncoder().encode(info)) == info)

        let reminder = QuickrNotificationInfo(kind: "due", serverId: "s")
        let keys = try (JSONSerialization.jsonObject(with: JSONEncoder().encode(reminder)) as? [String: Any])?.keys
        #expect(Set(keys ?? [:].keys).isDisjoint(with: ["run_id", "alert_label", "fire_at_ms"]))
        let decoded = try JSONDecoder().decode(
            QuickrNotificationInfo.self, from: Data(#"{"v": 1, "kind": "due", "server_id": "s"}"#.utf8))
        #expect(decoded.runId == nil && decoded.alertLabel == nil && decoded.fireAtMs == nil)
    }

    #if canImport(UserNotifications)
    @Test("the system adapter: fireAt → an interval trigger of at least 1 s; fireDate keeps the calendar trigger")
    func systemTriggers() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alert = LocalNotificationRequest(
            id: "a", title: "", body: "", fireAt: now.addingTimeInterval(30), interruptionLevel: .timeSensitive)
        let interval = try #require(
            SystemNotificationCenter.trigger(alert, now: now) as? UNTimeIntervalNotificationTrigger)
        #expect(interval.timeInterval == 30)
        #expect(!interval.repeats)

        var late = alert
        late.fireAt = now.addingTimeInterval(-5)
        let minimum = try #require(
            SystemNotificationCenter.trigger(late, now: now) as? UNTimeIntervalNotificationTrigger)
        #expect(minimum.timeInterval == 1)

        var both = alert
        both.fireDate = now.addingTimeInterval(3_600)
        #expect(SystemNotificationCenter.trigger(both, now: now) is UNTimeIntervalNotificationTrigger, "fireAt wins")

        let reminder = LocalNotificationRequest(id: "d", title: "", body: "", fireDate: now.addingTimeInterval(60))
        let calendar = try #require(
            SystemNotificationCenter.trigger(reminder, now: now) as? UNCalendarNotificationTrigger)
        #expect(Calendar.current.date(from: calendar.dateComponents) == now.addingTimeInterval(60))
        #expect(
            SystemNotificationCenter.trigger(LocalNotificationRequest(id: "n", title: "", body: ""), now: now) == nil)
    }

    @Test("the system adapter maps every interruption level both ways")
    func systemLevels() {
        for level in NotificationInterruptionLevel.allCases {
            #expect(SystemNotificationCenter.level(SystemNotificationCenter.level(level)) == level)
        }
        #expect(SystemNotificationCenter.level(RunAlerts.interruptionLevel) == .timeSensitive)
    }
    #endif
}
