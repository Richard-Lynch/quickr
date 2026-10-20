import Foundation
import QuickrData
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(2))) struct FakesTests {
    @Test func transportPrefersStubsThenQueueAndRecords() async throws {
        let transport = FakeTransport()
        let fixture = try Fixtures.api("health")
        transport.stub(.get, "/api/v1/health", fixture.response())
        transport.enqueue(.failure(.timedOut(requestStarted: true)))
        let base = try #require(URL(string: "http://localhost:8000"))
        let health = try await transport.send(
            HTTPRequest(method: .get, url: base.appendingPathComponent("api/v1/health"), timeout: .seconds(30)))
        #expect(health.status == 200 && health.headers["x-quickr-epoch"] != nil)
        await #expect(throws: TransportError.timedOut(requestStarted: true)) {
            try await transport.send(HTTPRequest(method: .get, url: base, timeout: .seconds(1)))
        }
        await #expect(throws: TransportError.self) {
            try await transport.send(HTTPRequest(method: .get, url: base, timeout: .seconds(1)))
        }
        #expect(transport.requests.count == 3)
    }

    @Test func leaseDeadlinesUseBootAndContinuousTime() {
        let clock = FakeLeaseClock()
        let deadline = clock.now().adding(.seconds(30))
        #expect(!clock.now().hasPassed(deadline: deadline))
        clock.advance(by: .seconds(29))
        #expect(!clock.now().hasPassed(deadline: deadline))
        clock.advance(by: .seconds(1))
        #expect(clock.now().hasPassed(deadline: deadline))
        clock.reboot(ct: 0)
        #expect(clock.now().hasPassed(deadline: clock.now().adding(.seconds(1))) == false)
        #expect(clock.now().hasPassed(deadline: deadline), "a deadline from another boot has passed")
    }

    @Test func notificationCenterRecordsRegistrations() async throws {
        let center = FakeNotificationCenter()
        let category = NotificationCategorySpec(
            id: "quickr.t.x.0123456789abcdef",
            actions: [NotificationActionSpec(id: "q1|s|t|1|k|o|v", title: "Good", kind: .log)])
        center.setNotificationCategories([category])
        #expect(await center.notificationCategories() == [category])
        try await center.add(LocalNotificationRequest(id: "due-t-2026-03-04T08:00:00Z", title: "T", body: "B"))
        #expect(await center.pendingNotificationRequests().map(\.id) == ["due-t-2026-03-04T08:00:00Z"])
        center.removePendingNotificationRequests(withIdentifiers: ["due-t-2026-03-04T08:00:00Z"])
        #expect(await center.pendingNotificationRequests().isEmpty)
        try await center.setBadgeCount(2)
        #expect(center.withState { $0.badge } == 2)
    }
}
