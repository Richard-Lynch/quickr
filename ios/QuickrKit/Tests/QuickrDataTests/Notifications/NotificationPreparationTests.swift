import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// The NSE flow (notifications.md §6, §8, §11.2 L1/L6; N9) with a fake center, a registry and the
/// active store.
@MainActor @Suite(.timeLimit(.minutes(2))) struct NotificationPreparationTests {
    static let now = HomeModelTests.now
    nonisolated static let active = "00000000-0000-4000-8000-0000000000a1"
    nonisolated static let inactive = "00000000-0000-4000-8000-0000000000a2"
    nonisolated static let unknown = "00000000-0000-4000-8000-0000000000a9"

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
        let center: any NotificationCenterProtocol
        /// What the center recorded.
        let fake: FakeNotificationCenter
        let store: LocalStore
        var registryOpens = true
        var storeOpens = true

        init(gated: GatedCenter? = nil) async throws {
            fake = gated?.inner ?? FakeNotificationCenter()
            center = gated ?? fake
            let queue = try TestDatabase.store()
            try await queue.write { db in
                try LocalStore.createSyncState(db, serverId: active, baseURL: "https://active.example")
                try db.execute(sql: "UPDATE sync_state SET epoch = 'E1'")
            }
            store = LocalStore(
                serverId: active, storeGen: 1, url: nil, writer: queue, leaseClock: FakeLeaseClock(),
                wallClock: FakeClock(now))
            for server in [active, inactive] {
                _ = try await registry.register(serverId: server, baseURL: "https://\(server).example", now: now)
            }
            try await registry.setActive(active)
            try await HomeModelTests.seed(store, [water, meds, stretch])
        }

        var preparation: NotificationPreparation {
            let (registry, store, registryOpens, storeOpens) = (registry, store, registryOpens, storeOpens)
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

    /// An entry only this device has: its create queued.
    static func queue(_ store: LocalStore, _ topic: Topic, at: Date) async throws {
        let ref = TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
        try await store.writer.write { db in
            try OutboxStorage.append(
                db,
                NewOutboxItem(
                    id: UUID(),
                    payload: .entryCreate(
                        topic: ref,
                        body: EntryCreateDTO(
                            id: nil, answers: ["severity": .string("s1")], source: "ios", capturedAt: at, version: 1)),
                    baseRevision: nil, origin: .app, hold: nil),
                now: at)
        }
    }

    /// An entry the server has.
    static func synced(_ store: LocalStore, _ topic: Topic, at: Date) async throws {
        let topicId = topic.id
        try await store.writer.write { db in
            _ = try ServerLayer.upsert(
                db,
                entry: Entry(
                    id: UUID(), topicId: topicId, version: 1, revision: 1, source: "web", channel: .ui,
                    capturedAt: at, createdAt: at, updatedAt: at, answers: [:]))
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
        #expect(w.fake.withState { $0.categories.map(\.id) } == [Self.waterCategory.id])
    }

    /// The due count is at `now + skew`: Stretch falls due 30 minutes from now on this clock, but
    /// the server's is 31 minutes ahead.
    @Test func theDueCountUsesTheServersClock() async throws {
        let w = try await World()
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET skew_ms = ?", arguments: [31 * 60_000])
        }
        #expect(await w.prepare(Self.reminder()).badge == 3)
    }

    /// N9: Water logged on this device and not synced yet: the reminder says so, has no actions,
    /// and Water isn't counted.
    @Test func aSlotLoggedOnThisDeviceSaysSoAndIsNotCounted() async throws {
        let w = try await World()
        try await Self.queue(w.store, Self.water, at: Self.now)
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.body == NotificationPreparation.alreadyLoggedBody)
        #expect(prepared.categoryIdentifier == "")
        #expect(prepared.badge == 1, "Meds only")
    }

    /// An entry the server already has doesn't trigger the "already logged" body: only a local one.
    @Test func aSyncedEntryIsNotALocalLog() async throws {
        let w = try await World()
        try await Self.synced(w.store, Self.water, at: Self.now)
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
    /// A push built by a server from before the number title became "Log 5 glasses" (a11y N1)
    /// names the old "✓ 5 glasses" category. The NSE doesn't trust it: it registers and uses the
    /// category it computes. The old category, registered before the change, stays registered
    /// (append-only, §5.2), so a reminder already delivered under it keeps its buttons.
    @Test func aPushWithThePreN1CategoryIdGetsTheCurrentCategory() async throws {
        let w = try await World()
        var info = Self.reminder()
        info.quickLog = NotificationCategory.descriptor(
            questions: [NotificationActionHandlerTests.glasses], counts: [:], last: .int(5))
        let descriptor = try #require(info.quickLog)
        let current = NotificationCategory(
            serverId: Self.active, topicId: Self.water.id.wireString, version: 1, descriptor: descriptor)
        #expect(current.actions.first?.title == "Log 5 glasses")
        var oldActions = current.actions
        oldActions[0].title = "✓ 5 glasses"
        var oldCategory = current
        oldCategory.actions = oldActions
        oldCategory.id = "quickr.t.\(Self.water.id.wireString).\(NotificationCategory.hash(oldActions))"
        let old = oldCategory.id
        #expect(old != current.id)
        _ = try await NotificationCategories(registry: w.registry, center: w.center).register(
            [.init(serverId: Self.active, topicId: Self.water.id.wireString, category: oldCategory)])

        let prepared = await w.prepare(info, category: old)
        #expect(prepared.categoryIdentifier == current.id)
        #expect(try Set(w.table) == [old, current.id])
        #expect(Set(w.fake.withState { $0.categories.map(\.id) }).isSuperset(of: [old, current.id]))
    }

    /// With the cap already full of other categories (§5.2), the reminder being shown still gets
    /// its category registered: due now, it ranks first and the least recently wanted makes room.
    @Test func aReminderGetsItsCategoryWithTheCapFull() async throws {
        let w = try await World()
        let others = (0..<NotificationCategories.registrationCap).map { _ in NotificationCategoriesTests.row() }
        // Wanted more recently than the push: only its due time can rank it above them.
        let later = FakeClock(Self.now.addingTimeInterval(60))
        try await NotificationCategories(registry: w.registry, center: w.center, wallClock: later).register(others)
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.categoryIdentifier == Self.waterCategory.id)
        let registered = w.fake.withState { $0.categories.map(\.id) }
        #expect(
            registered.count == NotificationCategories.registrationCap && registered.contains(Self.waterCategory.id))
    }

    @Test func aReminderFromAnUnknownServerLosesItsCategory() async throws {
        let w = try await World()
        let prepared = await w.prepare(Self.reminder(server: Self.unknown))
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
        w.fake.withState {
            $0.pending = [NotificationSnapshot(id: slot.localRequestIdentifier), NotificationSnapshot(id: "other")]
        }
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared == .init(body: "Time to log", categoryIdentifier: "quickr.t.x.server", badge: nil))
        #expect(w.fake.withState { $0.pending.map(\.id) } == ["other"])
    }

    /// A test push, a newer payload version, a sync push or a notification that isn't quickR's.
    @Test func anythingButAV1ReminderIsUntouched() async throws {
        let w = try await World()
        for quickr in [Self.reminder(kind: "test"), Self.reminder(v: 2), Self.reminder(kind: "sync"), nil] {
            let prepared = await w.prepare(quickr)
            #expect(prepared == .init(body: "Time to log", categoryIdentifier: "quickr.t.x.server", badge: nil))
        }
        #expect(try w.table.isEmpty)
        #expect(w.fake.withState { $0.categoryRegistrations.isEmpty })
    }

    // MARK: - Delivered reminders

    /// L1 removes a delivered local reminder for the slot; older remote ones for the topic go
    /// too. A newer slot, another topic and another server stay.
    @Test func olderAndLocalDuplicatesAreRemoved() async throws {
        let w = try await World()
        let earlier = Self.canonical(Self.now.addingTimeInterval(-130 * 60))
        let later = Self.canonical(Self.now.addingTimeInterval(60 * 60))
        w.fake.withState {
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
            w.fake.withState { $0.delivered.map(\.id) } == ["remote-later", "meds-older", "other-server", "push-1"])
    }

    // MARK: - Bounded reads (24 MB)

    /// 5,000 queued entries (10 of them edited too): the badge's `last_captured_at` and the slot
    /// check read them one entity at a time (never the whole queue), and agree with the full view.
    @Test func aLongQueueIsReadOneEntityAtATime() async throws {
        let w = try await World()
        let water = Self.water
        let base = Self.now.addingTimeInterval(-3 * 86_400)
        // The edits move 10 entries after Water's last synced one (130 minutes ago), still before
        // its slot: Water stays due (since 5 minutes ago), and nothing satisfies the slot.
        let edited = Self.now.addingTimeInterval(-125 * 60)
        try await w.store.writer.write { db in
            for i in 0..<5_000 {
                let id = UUID()
                try OutboxStorage.append(
                    db,
                    NewOutboxItem(
                        id: id,
                        payload: .entryCreate(
                            topic: TopicRef(id: water.id, slug: water.slug, name: water.name),
                            body: EntryCreateDTO(
                                id: nil, answers: ["severity": .string("s1")], source: "ios",
                                capturedAt: base.addingTimeInterval(Double(i)), version: 1)),
                        baseRevision: nil, origin: .app, hold: nil),
                    now: base)
                guard i < 10 else { continue }
                try OutboxStorage.append(
                    db,
                    NewOutboxItem(
                        id: UUID(),
                        payload: .entryUpdate(
                            entryId: id.wireString, topicId: water.id.wireString,
                            patch: EntryUpdateDTO(capturedAt: edited.addingTimeInterval(Double(i)))),
                        baseRevision: nil, origin: .app, hold: nil),
                    now: base)
            }
        }
        let (groups, bounded, full) = try await w.store.writer.read { db in
            var groups: [Int] = []
            try StoreView.streamOverlays(db, onEntity: { items, _ in groups.append(items) }) { _ in true }
            let full = try StoreView.derived(db).mapValues(\.lastCapturedAt)
            return (groups, try StoreView.lastCapturedAt(db), full)
        }
        #expect(groups.count == 5_000 && groups.filter { $0 == 2 }.count == 10, "one entity's items at a time")
        #expect(bounded == full.compactMapValues { $0 })
        #expect(bounded[water.id.wireString] == edited.addingTimeInterval(9), "the edits are applied")
        // The queue is older than Water's slot: no local log, Water still due. The preparation
        // reads the queue only through the cursor (by entity), never whole (by seq).
        let statements = Mutex<[String]>([])
        try await w.store.writer.write { db in db.trace { event in statements.withLock { $0.append("\(event)") } } }
        let prepared = await w.prepare(Self.reminder())
        try await w.store.writer.write { db in db.trace(options: [], nil) }
        #expect(prepared.body == "Time to log" && prepared.badge == 2)
        // Whole item rows (payloads) only through the cursor.
        let queueReads = statements.withLock { $0 }.filter { $0.contains("SELECT * FROM outbox_item") }
        #expect(!queueReads.isEmpty, "\(queueReads)")
        #expect(queueReads.allSatisfy { $0.contains("ORDER BY entity_id, seq") }, "\(queueReads)")
    }

    /// The slot check finds a queued entry however many newer entries the topic has.
    @Test func aQueuedEntryBehindFiftyNewerOnesStillCounts() async throws {
        let w = try await World()
        try await Self.queue(w.store, Self.water, at: Self.now.addingTimeInterval(-5 * 60))
        for i in 0..<50 { try await Self.synced(w.store, Self.water, at: Self.now.addingTimeInterval(Double(-i))) }
        let prepared = await w.prepare(Self.reminder())
        #expect(prepared.body == NotificationPreparation.alreadyLoggedBody && prepared.categoryIdentifier == "")
    }

    // MARK: - Expiry

    /// The time ran out while the preparation waited on the system: it is cancelled, and makes no
    /// change after that (no registration, no removals).
    @Test func anExpiredPreparationChangesNothingMore() async throws {
        let gated = GatedCenter()
        let w = try await World(gated: gated)
        let earlier = Self.canonical(Self.now.addingTimeInterval(-130 * 60))
        gated.withState {
            $0.delivered = [
                NotificationSnapshot(id: "local-same", quickr: Self.reminder(origin: .local)),
                NotificationSnapshot(id: "remote-older", quickr: Self.reminder(dueSince: earlier)),
            ]
        }
        let preparation = w.preparation
        let incoming = NotificationPreparation.Incoming(
            id: "push-1", body: "Time to log", categoryIdentifier: "c", quickr: Self.reminder())
        let preparing = Task { await preparation.prepare(incoming) }
        await gated.waitUntilHeld()
        preparing.cancel()  // serviceExtensionTimeWillExpire
        gated.release()
        _ = await preparing.value
        #expect(gated.withState { $0.delivered.map(\.id) } == ["local-same", "remote-older"])
        #expect(gated.withState { $0.categoryRegistrations.isEmpty })
        #expect(try w.table.isEmpty)
    }

    /// Cancelled while reconciliation waits on `notificationCategories()`, with a category the
    /// system lost: the union isn't registered again (nor anything else).
    @Test func anExpiredReconciliationRegistersNothing() async throws {
        let gated = GatedCenter(.categories)
        let w = try await World(gated: gated)
        let row = NotificationCategoriesTests.row()
        _ = try await NotificationCategories(registry: w.registry, center: w.fake).register([row])
        w.fake.withState {
            $0.categories = []
            $0.categoryRegistrations = []
        }
        let preparation = w.preparation
        let incoming = NotificationPreparation.Incoming(
            id: "push-1", body: "Time to log", categoryIdentifier: "c", quickr: Self.reminder())
        let preparing = Task { await preparation.prepare(incoming) }
        await gated.waitUntilHeld()
        preparing.cancel()
        gated.release()
        _ = await preparing.value
        #expect(w.fake.withState { $0.categoryRegistrations.isEmpty })
        #expect(try w.table == [row.category.id])
    }

    /// Archives and unarchives of Water and Meds alternating with entries, 300 rounds (900 items;
    /// appending them is the slow part), then Meds archived and a
    /// failed unarchive: the
    /// badge's topics hold one state row per topic and agree with the full view (status,
    /// archived_at, last_captured_at).
    @Test func anAlternatingTopicAndEntryQueueIsReadPerTopic() async throws {
        let w = try await World()
        let (water, meds) = (Self.water, Self.meds)
        let base = Self.now.addingTimeInterval(-2 * 86_400)
        try await w.store.writer.write { db in
            for i in 0..<300 {
                for topic in [water, meds] {
                    try OutboxStorage.append(
                        db,
                        NewOutboxItem(
                            id: UUID(),
                            payload: i % 2 == 0
                                ? .topicArchive(topicId: topic.id.wireString)
                                : .topicUnarchive(topicId: topic.id.wireString),
                            baseRevision: nil, origin: .app, hold: nil),
                        now: base.addingTimeInterval(Double(i)))
                }
                try OutboxStorage.append(
                    db,
                    NewOutboxItem(
                        id: UUID(),
                        payload: .entryCreate(
                            topic: TopicRef(id: water.id, slug: water.slug, name: water.name),
                            body: EntryCreateDTO(
                                id: nil, answers: ["severity": .string("s1")], source: "ios",
                                capturedAt: base.addingTimeInterval(Double(i)), version: 1)),
                        baseRevision: nil, origin: .app, hold: nil),
                    now: base)
            }
            // Meds ends archived: one more archive.
            try OutboxStorage.append(
                db,
                NewOutboxItem(
                    id: UUID(), payload: .topicArchive(topicId: meds.id.wireString), baseRevision: nil, origin: .app,
                    hold: nil),
                now: base.addingTimeInterval(5_000))
            // Then an unarchive that failed: not applied.
            let failed = UUID()
            try OutboxStorage.append(
                db,
                NewOutboxItem(
                    id: failed, payload: .topicUnarchive(topicId: meds.id.wireString), baseRevision: nil,
                    origin: .app, hold: nil),
                now: base.addingTimeInterval(6_000))
            try db.execute(
                sql: "UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected' WHERE id = ?",
                arguments: [failed.wireString])
        }
        let (states, bounded, full) = try await w.store.writer.read { db in
            (try StoreView.queuedTopicStates(db), try StoreView.dueTopics(db), try StoreView.topics(db))
        }
        #expect(states.count == 2)
        #expect(bounded.map(\.topic.status) == full.map(\.topic.status))
        #expect(bounded.map(\.topic.archivedAt) == full.map(\.topic.archivedAt))
        #expect(bounded.map(\.topic.lastCapturedAt) == full.map(\.topic.lastCapturedAt))
        #expect(full.first { $0.id == meds.id }?.topic.status == .archived)
        // Meds is archived now, so only Water is due.
        #expect(await w.prepare(Self.reminder()).badge == 1)
    }

    // MARK: - Version caches

    /// A queue over 20 versions of a topic: the stream keeps at most 8 question sets decoded,
    /// and still agrees with the full view.
    @Test func theStreamKeepsAFewQuestionSets() async throws {
        let w = try await World()
        let water = Self.water
        try await w.store.writer.write { db in
            for version in 1...20 {
                _ = try ServerLayer.insert(
                    db,
                    version: TopicVersion(
                        version: version, questions: water.questions, changeNote: "v\(version)",
                        createdAt: water.createdAt),
                    id: UUID(), topicId: water.id)
            }
            for i in 0..<60 {
                try OutboxStorage.append(
                    db,
                    NewOutboxItem(
                        id: UUID(),
                        payload: .entryCreate(
                            topic: TopicRef(id: water.id, slug: water.slug, name: water.name),
                            body: EntryCreateDTO(
                                id: nil, answers: ["severity": .string("s1")], source: "ios",
                                capturedAt: water.createdAt.addingTimeInterval(Double(i)), version: i % 20 + 1)),
                        baseRevision: nil, origin: .app, hold: nil),
                    now: water.createdAt)
            }
        }
        let (sizes, bounded, full) = try await w.store.writer.read { db in
            var sizes: [Int] = []
            try StoreView.streamOverlays(db, onEntity: { _, sets in sizes.append(sets) }) { _ in true }
            return (sizes, try StoreView.lastCapturedAt(db), try StoreView.derived(db).mapValues(\.lastCapturedAt))
        }
        #expect(sizes.count == 60 && sizes.max() == StoreView.overlayQuestionSets)
        #expect(bounded == full.compactMapValues { $0 })
    }

    // MARK: - Tampered payloads

    /// A reminder that breaks the contract (ids, version, key and option grammar, counts, label
    /// lengths, number bounds) is delivered untouched and registers nothing.
    @Test(arguments: TamperCase.all)
    func aTamperedReminderIsUntouchedAndRegistersNothing(_ tamper: TamperCase) async throws {
        let w = try await World()
        let slot = try #require(Self.reminder().slot)
        w.fake.withState { $0.pending = [NotificationSnapshot(id: slot.localRequestIdentifier)] }
        var info = Self.reminder()
        tamper.apply(&info)
        let prepared = await w.prepare(info, category: "c")
        #expect(prepared == .init(body: "Time to log", categoryIdentifier: "c", badge: nil), "\(tamper.name)")
        #expect(try w.table.isEmpty && w.fake.withState { $0.categoryRegistrations.isEmpty }, "\(tamper.name)")
    }

    struct TamperCase: Sendable, CustomTestStringConvertible {
        let name: String
        let apply: @Sendable (inout QuickrNotificationInfo) -> Void
        var testDescription: String { name }

        static func choice(_ name: String, _ change: @escaping @Sendable (inout QuickLogDescriptor.Choice) -> Void)
            -> TamperCase
        {
            TamperCase(name: name) { info in
                guard case .choice(var choice) = info.quickLog else { return }
                change(&choice)
                info.quickLog = .choice(choice)
            }
        }

        static func number(_ name: String, _ change: @escaping @Sendable (inout QuickLogDescriptor.Number) -> Void)
            -> TamperCase
        {
            TamperCase(name: name) { info in
                var number = QuickLogDescriptor.Number(
                    type: "double", key: "hours", label: "Sleep", unit: "h", min: .double(0), max: .double(24),
                    decimals: 1, lastValue: .double(7.5))
                change(&number)
                info.quickLog = .number(number)
            }
        }

        static let all: [TamperCase] = [
            TamperCase(name: "server id not a UUID") { $0.serverId = "server-1" },
            TamperCase(name: "uppercase topic id") { $0.topicId = "AAAAAAAA-0000-4000-8000-000000000002" },
            TamperCase(name: "topic id not a UUID") { $0.topicId = "water" },
            TamperCase(name: "version 0") { $0.version = 0 },
            TamperCase(name: "no version") { $0.version = nil },
            choice("key with a bar") { $0.key = "a|b" },
            choice("key not in the grammar") { $0.key = "Severity" },
            choice("option value with a bar") { $0.options[0] = .init(value: "s0|x", label: "S0") },
            choice("duplicate option values") { $0.options[1] = .init(value: "s0", label: "S1") },
            choice("more shown than active") { $0.totalOptions = 1 },
            choice("4 of 5 shown") {
                $0.options += [.init(value: "s2", label: "S2"), .init(value: "s3", label: "S3")]
                $0.totalOptions = 5
            },
            choice("7 active options") { $0.totalOptions = 7 },
            choice("label over 64") { $0.label = String(repeating: "x", count: 65) },
            number("min above max") { $0.min = .double(30) },
            number("last value out of range") { $0.lastValue = .double(25) },
            number("unknown type") { $0.type = "str" },
            number("decimals 11") { $0.decimals = 11 },
            // Integers past 2^53 are compared exactly, not as doubles (CAT's lastInt).
            number("int last value 2^53 + 1 above max 2^53") {
                $0 = .init(
                    type: "int", key: "steps", label: "Steps", min: .int(0), max: .int(1 << 53),
                    lastValue: .int((1 << 53) + 1))
            },
            number("int min 2^53 + 1 above max 2^53") {
                $0 = .init(type: "int", key: "steps", label: "Steps", min: .int((1 << 53) + 1), max: .int(1 << 53))
            },
            number("int bounds that are doubles") {
                $0 = .init(type: "int", key: "steps", label: "Steps", min: .double(0), max: .int(10))
            },
        ]
    }

    /// The same values in order are fine: 2^53 + 1 between 2^53 and 2^53 + 2 registers.
    @Test func exactIntegerBoundsAreAccepted() async throws {
        let w = try await World()
        var info = Self.reminder()
        info.quickLog = .number(
            .init(
                type: "int", key: "steps", label: "Steps", min: .int(1 << 53), max: .int((1 << 53) + 2),
                lastValue: .int((1 << 53) + 1)))
        let prepared = await w.prepare(info)
        let table = try w.table
        #expect(prepared.categoryIdentifier.hasPrefix("quickr.t.") && table.count == 1)
    }

    @Test func userInfoIsReadFromTheQuickrKey() throws {
        let info = Self.reminder()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
        #expect(QuickrNotificationInfo(userInfo: ["quickr": object, "aps": ["alert": "x"]]) == info)
        #expect(QuickrNotificationInfo(userInfo: ["aps": ["alert": "x"]]) == nil)
        #expect(QuickrNotificationInfo(userInfo: ["quickr": ["v": 1]]) == nil)
    }
}

/// A fake center whose `deliveredNotifications()` waits until released: a preparation suspended on
/// the system when the NSE's time runs out.
final class GatedCenter: NotificationCenterProtocol, @unchecked Sendable {
    enum Query { case delivered, categories }
    let inner = FakeNotificationCenter()
    let query: Query

    init(_ query: Query = .delivered) { self.query = query }
    private let gate = Mutex<(held: CheckedContinuation<Void, Never>?, released: Bool)>((nil, false))

    func withState<T>(_ body: (inout FakeNotificationCenter.State) -> T) -> T { inner.withState(body) }

    func waitUntilHeld() async {
        while gate.withLock({ $0.held == nil }) { await Task.yield() }
    }

    func release() {
        let held = gate.withLock { state in
            state.released = true
            defer { state.held = nil }
            return state.held
        }
        held?.resume()
    }

    private func pass(_ asked: Query) async {
        guard asked == query else { return }
        await withCheckedContinuation { continuation in
            let released = gate.withLock { state in
                if !state.released { state.held = continuation }
                return state.released
            }
            if released { continuation.resume() }
        }
    }

    func deliveredNotifications() async -> [NotificationSnapshot] {
        await pass(.delivered)
        return await inner.deliveredNotifications()
    }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        inner.setNotificationCategories(categories)
    }
    func notificationCategories() async -> [NotificationCategorySpec] {
        await pass(.categories)
        return await inner.notificationCategories()
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        inner.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func pendingNotificationRequests() async -> [NotificationSnapshot] { await inner.pendingNotificationRequests() }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        inner.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func add(_ request: LocalNotificationRequest) async throws { try await inner.add(request) }
    func setBadgeCount(_ count: Int) async throws { try await inner.setBadgeCount(count) }
    func authorizationStatus() async -> NotificationAuthorization { await inner.authorizationStatus() }
    func requestAuthorization() async throws -> Bool { try await inner.requestAuthorization() }
}
