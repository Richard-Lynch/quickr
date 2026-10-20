import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// The NSE flow (notifications.md §6, §8, §11.2 L1/L6; N9) with a fake center, a registry and the
/// active store.
@MainActor @Suite(.timeLimit(.minutes(2))) struct NotificationPreparationTests {
    static let now = HomeModelTests.now
    static let active = "server-1"
    static let inactive = "server-2"

    static let water = HomeModelTests.topic(
        2, "Water", everyMinutes: 120, lastMinutesAgo: 130, questions: [NotificationCategoriesTests.severity(2)])
    static let meds = HomeModelTests.topic(1, "Meds", everyMinutes: 240, lastMinutesAgo: 300)
    static let stretch = HomeModelTests.topic(3, "Stretch", everyMinutes: 180, lastMinutesAgo: 150)
    /// Water's slot: due 10 minutes ago.
    static let waterSlot = canonical(now.addingTimeInterval(-10 * 60))

    static func canonical(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    static let descriptor = QuickLogDescriptor.choice(
        .init(
            key: "severity", label: "Severity",
            options: [.init(value: "s0", label: "S0"), .init(value: "s1", label: "S1")], totalOptions: 2))

    static func reminder(
        server: String = active, topic: Topic = water, dueSince: String = waterSlot, kind: String = "due", v: Int = 1,
        origin: QuickrNotificationInfo.Origin = .remote
    ) -> QuickrNotificationInfo {
        QuickrNotificationInfo(
            v: v, kind: kind, origin: origin, serverId: server, topicId: topic.id.wireString, topicSlug: topic.slug,
            version: 1, dueSince: dueSince, url: "/t/\(topic.slug)/record", quickLog: descriptor)
    }

    @MainActor struct World {
        let registry = Registry(writer: try! TestDatabase.registry())
        let center = FakeNotificationCenter()
        let store: TestStore
        var registryOpens = true
        var storeOpens = true

        init() async throws {
            store = try TestStore()
            for server in [active, inactive] {
                _ = try await registry.register(serverId: server, baseURL: "https://\(server).example", now: now)
            }
            try await registry.setActive(active)
            try await HomeModelTests.seed(store.store, [water, meds, stretch])
        }

        var preparation: NotificationPreparation {
            let (registry, store, registryOpens, storeOpens) = (registry, store.store, registryOpens, storeOpens)
            let now = NotificationPreparationTests.now
            return NotificationPreparation(
                center: center,
                registry: {
                    struct BeforeFirstUnlock: Error {}
                    guard registryOpens else { throw BeforeFirstUnlock() }
                    return registry
                },
                activeStore: { storeOpens ? store : nil }, now: { now })
        }

        func prepare(_ quickr: QuickrNotificationInfo?, id: String = "push-1", category: String = "quickr.t.x.server")
            async -> NotificationPreparation.Prepared
        {
            await preparation.prepare(.init(id: id, body: "Time to log", categoryIdentifier: category, quickr: quickr))
        }

        var table: [String] {
            get throws {
                try registry.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM notification_category") }
            }
        }
    }

    static var waterCategory: NotificationCategory {
        NotificationCategory(serverId: active, topicId: water.id.wireString, version: 1, descriptor: descriptor)
    }

    // MARK: - The active server

    /// From the active server: its category (registered first), and the badge is the active
    /// store's due count: Water and Meds, not Stretch.
    @Test func aReminderFromTheActiveServerGetsItsCategoryAndTheDueCount() async throws {
        let w = try await World()
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.categoryIdentifier == Self.waterCategory.id)
        #expect(prepared.badge == 2 && prepared.body == "Time to log")
        #expect(try w.table == [Self.waterCategory.id])
        #expect(w.center.withState { $0.categories.map(\.id) } == [Self.waterCategory.id])
    }

    /// The due count is at `now + skew`: Stretch falls due 30 minutes from now on this clock, but
    /// the server's is 31 minutes ahead.
    @Test func theDueCountUsesTheServersClock() async throws {
        let w = try await World()
        try w.store.write { db in try db.execute(sql: "UPDATE sync_state SET skew_ms = ?", arguments: [31 * 60_000]) }
        #expect(await w.prepare(Self.reminder()).badge == 3)
    }

    /// N9: Water logged on this device and not synced yet: the reminder says so, has no actions,
    /// and Water isn't counted.
    @Test func aSlotLoggedOnThisDeviceSaysSoAndIsNotCounted() async throws {
        let w = try await World()
        try w.store.write { db in
            try OutboxStorage.append(
                db,
                NewOutboxItem(
                    id: UUID(),
                    payload: .entryCreate(
                        topic: TopicRef(id: Self.water.id, slug: Self.water.slug, name: Self.water.name),
                        body: EntryCreateDTO(
                            id: nil, answers: ["severity": .string("s1")], source: "ios", capturedAt: Self.now,
                            version: 1)),
                    baseRevision: nil, origin: .app, hold: nil),
                now: Self.now)
        }
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.body == NotificationPreparation.alreadyLoggedBody)
        #expect(prepared.categoryIdentifier == "")
        #expect(prepared.badge == 1, "Meds only")
    }

    /// An entry the server already has doesn't trigger the "already logged" body: only a local one.
    @Test func aSyncedEntryIsNotALocalLog() async throws {
        let w = try await World()
        try w.store.write { db in
            _ = try ServerLayer.upsert(
                db,
                entry: Entry(
                    id: UUID(), topicId: Self.water.id, version: 1, revision: 1, source: "web", channel: .ui,
                    capturedAt: Self.now, createdAt: Self.now, updatedAt: Self.now, answers: [:]))
        }
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.body == "Time to log" && prepared.categoryIdentifier == Self.waterCategory.id)
        #expect(prepared.badge == 1)
    }

    /// The active store can't be opened (a reset, file protection): the badge is left alone.
    @Test func noActiveStoreLeavesTheBadge() async throws {
        var w = try await World()
        w.storeOpens = false
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.badge == nil && prepared.categoryIdentifier == Self.waterCategory.id)
    }

    // MARK: - Other servers (N9)

    /// N9: a reminder from a server the user has but isn't on: its category, and the badge untouched.
    @Test func aReminderFromAnInactiveServerLeavesTheBadgeUnset() async throws {
        let w = try await World()
        let prepared = await w.prepare(Self.reminder(server: Self.inactive))
        #expect(prepared.badge == nil)
        let category = NotificationCategory(
            serverId: Self.inactive, topicId: Self.water.id.wireString, version: 1, descriptor: Self.descriptor)
        #expect(prepared.categoryIdentifier == category.id)
    }

    /// A server the registry doesn't know: no category (its actions could only be dropped), no
    /// badge, nothing registered.
    @Test func aReminderFromAnUnknownServerLosesItsCategory() async throws {
        let w = try await World()
        let prepared = await w.prepare(Self.reminder(server: "server-9"))
        #expect(prepared.categoryIdentifier == "" && prepared.badge == nil)
        #expect(try w.table.isEmpty)
    }

    // MARK: - Untouched

    /// Before first unlock the registry can't be opened: untouched, but L1 still cancels our
    /// pending local reminder for the slot.
    @Test func beforeFirstUnlockOnlyTheLocalFallbackIsCancelled() async throws {
        var w = try await World()
        w.registryOpens = false
        let slot = try #require(Self.reminder().slot)
        w.center.withState {
            $0.pending = [NotificationSnapshot(id: slot.localRequestIdentifier), NotificationSnapshot(id: "other")]
        }
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared == .init(body: "Time to log", categoryIdentifier: "quickr.t.x.server", badge: nil))
        #expect(w.center.withState { $0.pending.map(\.id) } == ["other"])
    }

    /// A test push, a newer payload version, a sync push or a notification that isn't quickR's.
    @Test func anythingButAV1ReminderIsUntouched() async throws {
        let w = try await World()
        for quickr in [Self.reminder(kind: "test"), Self.reminder(v: 2), Self.reminder(kind: "sync"), nil] {
            let prepared = await w.prepare(quickr)
            #expect(prepared == .init(body: "Time to log", categoryIdentifier: "quickr.t.x.server", badge: nil))
        }
        #expect(try w.table.isEmpty)
        #expect(w.center.withState { $0.categoryRegistrations.isEmpty })
    }

    // MARK: - Delivered reminders

    /// L1 removes a delivered local reminder for the slot; older remote ones for the topic go
    /// too. A newer slot, another topic and another server stay.
    @Test func olderAndLocalDuplicatesAreRemoved() async throws {
        let w = try await World()
        let earlier = Self.canonical(Self.now.addingTimeInterval(-130 * 60))
        let later = Self.canonical(Self.now.addingTimeInterval(60 * 60))
        w.center.withState {
            $0.delivered = [
                NotificationSnapshot(id: "local-same", quickr: Self.reminder(origin: .local)),
                NotificationSnapshot(id: "remote-older", quickr: Self.reminder(dueSince: earlier)),
                NotificationSnapshot(id: "remote-later", quickr: Self.reminder(dueSince: later)),
                NotificationSnapshot(id: "meds-older", quickr: Self.reminder(topic: Self.meds, dueSince: earlier)),
                NotificationSnapshot(
                    id: "other-server", quickr: Self.reminder(server: Self.inactive, dueSince: earlier)),
                NotificationSnapshot(id: "push-1", quickr: Self.reminder()),
            ]
        }
        _ = await w.prepare(Self.reminder())
        #expect(
            w.center.withState { $0.delivered.map(\.id) } == ["remote-later", "meds-older", "other-server", "push-1"])
    }

    @Test func userInfoIsReadFromTheQuickrKey() throws {
        let info = Self.reminder()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
        #expect(QuickrNotificationInfo(userInfo: ["quickr": object, "aps": ["alert": "x"]]) == info)
        #expect(QuickrNotificationInfo(userInfo: ["aps": ["alert": "x"]]) == nil)
        #expect(QuickrNotificationInfo(userInfo: ["quickr": ["v": 1]]) == nil)
    }
}
