import Foundation
import QuickrCore
@_spi(Testing) import QuickrData
import Testing
import UserNotifications

@testable import QuickR

/// The minimal `UNUserNotificationCenter` adapter (notifications.md §5; spike F1): the live
/// environment's session registers the active store's reminder categories with the real center,
/// without asking for notification permission.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5))) struct SystemNotificationCenterTests {
    static let server = "test-server"

    /// A store whose active server has a quick-loggable chips topic and a number topic.
    static func seeded() async throws -> (StoreLocation, chips: UUID, number: UUID) {
        let location = TestStores.emptyLocation()
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try await partitions.createStore(serverId: server, baseURL: "https://quickr.example")
        try await partitions.registry.setActive(server)
        let (chips, number) = (UUID(), UUID())
        let t0 = Date(timeIntervalSince1970: 1_767_225_600)
        func topic(_ id: UUID, _ slug: String, _ question: Question) -> Topic {
            Topic(
                id: id, slug: slug, name: slug.capitalized, currentVersion: 1, revision: 1, questionCount: 1,
                createdAt: t0, updatedAt: t0, questions: [question])
        }
        let severity = Question(
            key: "severity", label: "Severity",
            kind: .choice(.init(options: ["none", "mild", "severe"].map { .init(value: $0, label: $0.capitalized) })))
        let glasses = Question(key: "glasses", label: "Glasses", kind: .int(.init(min: 0, max: 20, unit: "glasses")))
        let topics = [topic(chips, "headache", severity), topic(number, "water", glasses)]
        try await store.writer.write { db in
            for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
        }
        return (location, chips, number)
    }

    /// Holds `SystemCategoriesLock`: it sets and reads the process-wide category set.
    @Test func theLiveSessionRegistersTheStoresCategoriesWithTheSystem() async throws {
        try await SystemCategoriesLock.shared.withLock { try await registersTheStoresCategories() }
    }

    private func registersTheStoresCategories() async throws {
        let (location, chips, number) = try await Self.seeded()
        defer { TestStores.remove(location) }
        UNUserNotificationCenter.current().setNotificationCategories([])
        let environment = AppEnvironment.live(location: location)
        await environment.start()
        let session = try #require(environment.session)
        await session.categoryRefreshSettled()

        let expected = try await NotificationCategories.rows(in: try #require(session.store))
        #expect(Set(expected.map(\.topicId)) == [chips.wireString, number.wireString])
        // The system applies the set asynchronously: poll, bounded.
        var registered: Set<UNNotificationCategory> = []
        for _ in 0..<50 {
            registered = await UNUserNotificationCenter.current().notificationCategories()
            if Set(expected.map(\.category.id)).isSubset(of: Set(registered.map(\.identifier))) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        for row in expected {
            let category = try #require(registered.first { $0.identifier == row.category.id }, "\(row.category.id)")
            #expect(category.actions.map(\.identifier) == row.category.actions.map(\.identifier))
            #expect(category.actions.map(\.title) == row.category.actions.map(\.title))
        }
        // The number topic has no last value: just "Other value…", a text input that stays in the
        // background.
        let water = try #require(registered.first { $0.identifier.contains(number.wireString) })
        let input = try #require(water.actions.first as? UNTextInputNotificationAction)
        #expect(input.textInputButtonTitle == "Log" && input.textInputPlaceholder == "Value in glasses")
        #expect(!input.options.contains(.foreground))
        await session.shutdown()
    }

    /// Specs survive the trip through `UNNotificationCategory`, `open` (foreground) included.
    @Test func specsRoundTripThroughTheSystemCenter() async throws {
        try await SystemCategoriesLock.shared.withLock { try await specsRoundTrip() }
    }

    private func specsRoundTrip() async throws {
        let spec = NotificationCategorySpec(
            id: "quickr.t.test.0000000000000000",
            actions: [
                .init(id: "q1|a", title: "Mild", kind: .log),
                .init(id: "q1|b", title: "Other value…", kind: .input(buttonTitle: "Log", placeholder: "Value")),
                .init(id: "q1|c", title: "More…", kind: .open),
                .init(id: "q1|d", title: "Locked", kind: .log, requiresAuthentication: true),
            ])
        let center = SystemNotificationCenter()
        center.setNotificationCategories([spec])
        var back: [NotificationCategorySpec] = []
        for _ in 0..<50 {
            back = await center.notificationCategories()
            if back.contains(where: { $0.id == spec.id }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(back.first { $0.id == spec.id } == spec)
    }
}
