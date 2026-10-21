import Foundation
import QuickrData
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(5))) struct NotificationContractTests {
    /// The `quickr` object of notifications.md §2.1, with an enum descriptor.
    private static let remoteJSON = """
        {"v": 1, "kind": "due", "server_id": "0b9e0000-0000-4000-8000-000000000001",
         "topic_id": "6f1c0000-0000-4000-8000-000000000002", "topic_slug": "mood", "version": 3,
         "due_since": "2026-10-17T08:00:00Z", "url": "/t/mood/record", "future_key": true,
         "quick_log": {"type": "enum", "key": "mood", "label": "Mood",
                       "options": [{"value": "good", "label": "Good"}, {"value": "ok", "label": "OK"}],
                       "total_options": 5}}
        """

    private func info(_ json: String) throws -> QuickrNotificationInfo {
        try JSONDecoder().decode(QuickrNotificationInfo.self, from: Data(json.utf8))
    }

    @Test func descriptorAndOriginSurviveDecodeAndEncode() throws {
        let remote = try info(Self.remoteJSON)
        #expect(remote.origin == .remote)
        #expect(remote.url == "/t/mood/record")
        let expected = QuickLogDescriptor.choice(
            .init(
                key: "mood", label: "Mood",
                options: [.init(value: "good", label: "Good"), .init(value: "ok", label: "OK")],
                totalOptions: 5))
        #expect(remote.quickLog == expected)
        #expect(try info(String(decoding: JSONEncoder().encode(remote), as: UTF8.self)) == remote)

        let number = try info(
            """
            {"v": 1, "kind": "due", "origin": "local", "server_id": "s", "topic_id": "t", "version": 2,
             "due_since": "2026-10-17T08:00:00Z",
             "quick_log": {"type": "double", "key": "hours", "label": "Sleep", "unit": "h", "min": 0, "max": 24,
                           "decimals": 1, "last_value": 7.5}}
            """)
        #expect(number.origin == .local)
        #expect(
            number.quickLog
                == .number(
                    .init(
                        type: "double", key: "hours", label: "Sleep", unit: "h", min: .double(0), max: .double(24),
                        decimals: 1,
                        lastValue: .double(7.5))))
        #expect(try info(String(decoding: JSONEncoder().encode(number), as: UTF8.self)) == number)
    }

    @Test func fakeCenterKeepsTheDescriptor() async throws {
        let center = FakeNotificationCenter()
        let remote = try info(Self.remoteJSON)
        let slot = try #require(remote.slot)
        try await center.add(
            LocalNotificationRequest(
                id: slot.localRequestIdentifier, title: "Mood", body: "Time to log", quickr: remote))
        let pending = await center.pendingNotificationRequests()
        #expect(pending.first?.quickr?.quickLog == remote.quickLog)
        #expect(slot.localRequestIdentifier == "due-6f1c0000-0000-4000-8000-000000000002-2026-10-17T08:00:00Z")
    }

    private func snapshot(
        _ id: String, _ origin: QuickrNotificationInfo.Origin, slot: String = "2026-10-17T08:00:00Z",
        server: String = "s"
    )
        -> NotificationSnapshot
    {
        NotificationSnapshot(
            id: id,
            quickr: QuickrNotificationInfo(kind: "due", origin: origin, serverId: server, topicId: "t", dueSince: slot))
    }

    /// L3 (and L1): the local reminder fired first; the push for the same slot removes it.
    @Test func remoteAfterLocalRemovesTheLocal() {
        let local = snapshot("due-t-2026-10-17T08:00:00Z", .local)
        let remote = snapshot("apns-1", .remote)
        #expect(ReminderDedup.identifiersToRemove(arriving: remote, delivered: [local]) == [local.id])
    }

    /// L2: the push was delivered first; the local reminder for the same slot is the duplicate.
    @Test func localAfterRemoteSuppressesTheLocal() {
        let remote = snapshot("apns-1", .remote)
        let local = snapshot("due-t-2026-10-17T08:00:00Z", .local)
        #expect(ReminderDedup.identifiersToRemove(arriving: local, delivered: [remote]) == [local.id])
    }

    @Test func otherSlotsServersAndKindsAreKept() {
        let local = snapshot("due-t-2026-10-17T08:00:00Z", .local)
        #expect(
            ReminderDedup.identifiersToRemove(
                arriving: snapshot("a", .remote, slot: "2026-10-17T21:30:00Z"), delivered: [local]
            ).isEmpty)
        #expect(
            ReminderDedup.identifiersToRemove(arriving: snapshot("a", .remote, server: "other"), delivered: [local])
                .isEmpty)
        #expect(ReminderDedup.identifiersToRemove(arriving: snapshot("b", .local), delivered: [local]).isEmpty)
        let test = NotificationSnapshot(id: "t", quickr: QuickrNotificationInfo(kind: "test", serverId: "s"))
        #expect(ReminderDedup.identifiersToRemove(arriving: test, delivered: [local]).isEmpty)
    }
}
