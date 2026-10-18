import Foundation
import GRDB
import QuickrCore
import QuickrData
import Testing

/// outbox.md §13 INT cases 12, 17, 18, 32 (INT half), 38, 49, 51 and 59 against the real backend,
/// and the outbox's `pull_requested` signal driving the coordinator end to end.
extension IntegrationTests {
    @Suite("Outbox") struct OutboxCases {
        static let entriesPath = "/api/v1/topics/*/entries"
        static let entryPath = "/api/v1/entries/*"

        // MARK: Undo against a POST still in the network (§9.1, §6a rule 2)

        /// Logs E, parks its POST at the proxy past the request deadline (uncertain), then undoes it.
        static func uncertainCreateHeldInTheNetwork(_ it: IT, _ device: Device, _ store: LocalStore, _ topic: TopicRef)
            async throws -> (outbox: Outbox, id: UUID, hold: Int)
        {
            let outbox = try await device.outbox()
            let id = UUID()
            try await outbox.createEntry(id: id, topic: topic, body: logBody(), origin: .app)
            let hold = try await it.proxy.add(["action": "hold", "method": "POST", "path": entriesPath])
            _ = try await outbox.flush(force: true, budget: .seconds(3))
            try await it.proxy.waitUntilHolding(hold)
            let item = try #require(try await store.item(id))
            #expect(item.state == .uncertain && item.maybeDelivered)
            #expect(try await it.a.entry(id) == nil, "the POST hasn't reached the server")
            return (outbox, id, hold)
        }

        @Test("12 · a POST delayed in the network arrives after the undo's DELETE: 409 entry_deleted")
        func case12() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let (outbox, id, hold) = try await Self.uncertainCreateHeldInTheNetwork(it, device, store, topic)

                #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
                #expect(try await outbox.flush(force: true, budget: .seconds(20)).acked == 1)
                #expect(try await store.items.isEmpty)

                // The DELETE has committed; now the delayed POST reaches the server.
                try await it.proxy.release(hold)
                try await eventually("the late POST is answered") {
                    try await it.proxy.log().contains { $0.method == "POST" && $0.upstreamStatus != nil }
                }
                let post = try #require(try await it.proxy.log().first { $0.method == "POST" })
                #expect(post.upstream == "a" && post.upstreamStatus == 409)
                #expect(try await it.a.entry(id) == nil)
                // The id stays reserved: the same create, sent again, is refused the same way.
                let replay = try await it.a.http.call(
                    "POST", "/api/v1/topics/\(topic.id)/entries",
                    ["id": id.wireString, "answers": ["n": 1], "captured_at": WireDate.format(Date())])
                #expect(replay.status == 409 && replay.object["code"] as? String == "entry_deleted")
            }
        }

        @Test("51 · undo of an uncertain create: only DELETE E is sent (204); the late POST changes nothing")
        func case51() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let (outbox, id, hold) = try await Self.uncertainCreateHeldInTheNetwork(it, device, store, topic)
                let index = device.sent().count

                #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
                #expect(try await store.view(id) == nil)
                _ = try await outbox.flush(force: true, budget: .seconds(20))
                let sent = device.sent(from: index)
                #expect(sent.map(\.method) == [.delete] && sent.first?.url.path == "/api/v1/entries/\(id.wireString)")
                let delete = try #require(try await it.proxy.log().first { $0.method == "DELETE" })
                #expect(delete.upstreamStatus == 204, "E doesn't exist yet, and the DELETE still succeeds")
                #expect(try await store.items.isEmpty)
                #expect(try await store.view(id) == nil)

                try await it.proxy.release(hold)
                try await eventually("the late POST is answered") {
                    try await it.proxy.log().contains { $0.method == "POST" && $0.upstreamStatus != nil }
                }
                #expect(try await it.proxy.log().first { $0.method == "POST" }?.upstreamStatus == 409)
                // Undone holds: nothing on the server, nothing on the device.
                #expect(try await it.a.entry(id) == nil)
                _ = await device.coordinator.sync(reason: .requested)
                #expect(try await store.view(id) == nil)
                #expect(try await store.serverRevision(id) == nil)
            }
        }

        // MARK: Remote deletes (§5.2, sync §4.3)

        /// E logged on the web and pulled by the device, with an update pending for it.
        static func pendingUpdateOfWebEntry(_ it: IT, _ device: Device, _ store: LocalStore, _ topic: TopicRef)
            async throws -> (Outbox, UUID, String)
        {
            let id = try await it.a.createEntry(topic: topic, n: 1)
            #expect(await device.coordinator.sync(reason: .requested) == .synced)
            #expect(try await store.serverRevision(id) == 1)
            let outbox = try await device.outbox()
            try await outbox.updateEntry(
                id: id, topicId: try #require(UUID(uuidString: topic.id)),
                patch: EntryUpdateDTO(answers: ["n": .int(2)]),
                origin: .app)
            let update = try #require(try await store.items.single)
            return (outbox, id, update.id)
        }

        @Test(
            "17 · E deleted on the web, update pending, flush: PATCH 404 tombstones E, update failed deleted_elsewhere")
        func case17() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let (outbox, id, update) = try await Self.pendingUpdateOfWebEntry(it, device, store, topic)
                try await it.a.deleteEntry(id)

                _ = try await outbox.flush(force: true, budget: .seconds(20))
                let patch = try #require(try await it.proxy.log().first { $0.method == "PATCH" })
                #expect(patch.upstreamStatus == 404)
                let item = try #require(try await store.item(update))
                #expect(item.state == .failed && item.failureReason == .deletedElsewhere)
                #expect(try await store.isTombstoned(id))
                #expect(try await store.view(id) == nil)
                #expect(try await store.serverRevision(id) == nil)
                #expect(try await it.a.entry(id) == nil)
            }
        }

        @Test("18 · E deleted on the web, update pending, pull first: failed without a request, no zombie row")
        func case18() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let (outbox, id, update) = try await Self.pendingUpdateOfWebEntry(it, device, store, topic)
                try await it.a.deleteEntry(id)
                let index = device.sent().count

                #expect(await device.coordinator.sync(reason: .requested) == .synced)
                let item = try #require(try await store.item(update))
                #expect(item.state == .failed && item.failureReason == .deletedElsewhere)
                #expect(try await store.isTombstoned(id))
                #expect(try await store.view(id) == nil)
                #expect(try await store.serverRevision(id) == nil)

                _ = try await outbox.flush(force: true, budget: .seconds(10))
                #expect(device.sent(from: index, .patch).isEmpty)
                #expect(try await it.proxy.log().allSatisfy { $0.method != "PATCH" })
                #expect(try await store.view(id) == nil)
            }
        }

        // MARK: Stale rebasing by a superseded sender (§7.4)

        @Test("32 · INT half: a superseded sender's late PATCH gets stale_revision; it doesn't rebase or resend")
        func case32() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let topicId = try #require(UUID(uuidString: topic.id))
                let id = try await it.a.createEntry(topic: topic, n: 1)
                try await it.a.updateEntry(id, n: 2)
                try await it.a.updateEntry(id, n: 3)
                #expect(await device.coordinator.sync(reason: .requested) == .synced)
                #expect(try await store.serverRevision(id) == 3)

                let a = try await device.outbox(owner: "app:A")
                let b = try await device.outbox(owner: "widget:B")
                try await a.updateEntry(
                    id: id, topicId: topicId, patch: EntryUpdateDTO(answers: ["n": .int(10)]), origin: .app)
                let hold = try await it.proxy.add(["action": "hold", "method": "PATCH", "path": Self.entryPath])
                let flushA = Task { try await a.flush(force: true, budget: .seconds(120)) }
                try await it.proxy.waitUntilHolding(hold)  // U1 (expected 3) is in the network
                try await b.updateEntry(
                    id: id, topicId: topicId, patch: EntryUpdateDTO(answers: ["n": .int(20)]), origin: .widget)
                device.clock.advance(by: .seconds(31))  // A's flush lease is past its TTL

                let reportB = try await b.flush(force: true, budget: .seconds(30))
                #expect(reportB.acked == 2)
                #expect(try await it.a.entry(id)?["revision"] as? Int == 5)
                let before = try await store.fingerprint()

                try await it.proxy.release(hold)  // A's original PATCH lands late
                let reportA = try await flushA.value
                #expect(reportA.ending == .superseded)

                let patches = try await it.proxy.log().filter { $0.method == "PATCH" }
                #expect(patches.count == 3, "\(patches)")
                #expect(patches.first?.upstreamStatus == 409, "A's late PATCH is stale")
                let sent = device.sent(.patch)
                #expect(sent.count == 3 && sent.map(\.expectedRevision) == [3, 3, 4])
                #expect(!sent.contains { $0.expectedRevision == 5 })
                #expect(device.sent(.get).allSatisfy { !$0.url.path.hasPrefix("/api/v1/entries/") })
                let server = try #require(try await it.a.entry(id))
                #expect(server["revision"] as? Int == 5 && WebServer.answer(server) == 20)
                #expect(try await store.fingerprint() == before, "A wrote nothing locally")
            }
        }

        // MARK: Server identity and epoch (§5.2, sync §7, F10)

        @Test("38 · epoch rotation with pending, uncertain and failed items: restored, rebuilt, resent; failed stays")
        func case38() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let topicId = try #require(UUID(uuidString: topic.id))
                let outbox = try await device.outbox()
                let edited = try await it.a.createEntry(topic: topic, n: 1)
                #expect(await device.coordinator.sync(reason: .requested) == .synced)

                let rejected = UUID()  // n is 0…100: 422, failed/rejected
                try await outbox.createEntry(id: rejected, topic: topic, body: logBody(n: 500), origin: .app)
                _ = try await outbox.flush(force: true, budget: .seconds(20))
                // Two uncertain creates from one flush: the first POST commits but its 201 is garbled;
                // the second is held in the network past the request deadline.
                let committed = UUID()
                let lost = UUID()
                try await outbox.createEntry(id: committed, topic: topic, body: logBody(n: 5), origin: .app)
                try await outbox.createEntry(id: lost, topic: topic, body: logBody(n: 6), origin: .app)
                try await it.proxy.add(["action": "garble", "method": "POST", "path": Self.entriesPath])
                let held = try await it.proxy.add(["action": "hold", "method": "POST", "path": Self.entriesPath])
                _ = try await outbox.flush(force: true, budget: .seconds(3))
                try await it.proxy.waitUntilHolding(held)
                #expect(try await it.a.entry(committed) != nil)
                #expect(try await it.a.entry(lost) == nil)
                try await outbox.updateEntry(
                    id: edited, topicId: topicId, patch: EntryUpdateDTO(answers: ["n": .int(42)]), origin: .app)
                device.clock.advance(by: .seconds(3600))  // the uncertain creates' backoff has passed
                let before = try await store.items
                let log = try await it.proxy.log()
                try #require(before.map(\.state) == [.failed, .uncertain, .uncertain, .pending], "\(before) \(log)")
                #expect(before[0].failureReason == .rejected && before[1].maybeDelivered && before[2].maybeDelivered)

                let oldState = try await store.state()
                let oldEpoch = try #require(oldState.epoch)
                let epoch = try await rotateEpoch(it.config)
                // The held POST arrives after the rotation with the old Expect-Epoch: refused without
                // executing, so the lost create never committed.
                try await it.proxy.release(held)
                try await eventually("the held POST is refused") {
                    try await it.proxy.log().contains { $0.method == "POST" && $0.upstreamStatus == 409 }
                }
                #expect(try await it.a.entry(lost) == nil)
                // Park the coordinator's feed so the restored state can be checked before the rebuild.
                let feed = try await it.proxy.add([
                    "action": "hold", "method": "GET", "path": "/api/v1/changes", "sticky": true,
                ])
                let index = device.sent().count
                let report = try await outbox.flush(force: true, budget: .seconds(20))
                #expect(report.ending == .mismatch(.epoch))
                // Everything but `updated_at`, which the claim stamps with the (real) wall clock.
                let restored = try await store.items
                #expect(
                    restored.ignoringUpdatedAt == before.ignoringUpdatedAt,
                    "409 epoch_mismatch restores the pre-claim state")
                #expect(try await store.state().epochSuspect)
                try await it.proxy.waitUntilHolding(feed)  // the signal ran the coordinator
                try await it.proxy.release(feed)

                // Forwarding is paused (no scheduler bound) through the rebuild and swap, so the
                // durable items can be compared after the swap and before anything is resent.
                try await eventually("the rebuild swaps") {
                    let state = try await store.state()
                    return state.epoch == epoch && state.layerGen > oldState.layerGen && !state.epochSuspect
                }
                // The rebuilt layer has the committed create's entry, so the swap's pull-ack settles
                // it (sync §4.3) without a resend; every other item is exactly as it was.
                let swapped = try await store.items
                let kept = before.filter { $0.id != committed.wireString }
                #expect(
                    swapped.ignoringUpdatedAt == kept.ignoringUpdatedAt,
                    "the swap keeps the other items as they were:\n\(kept)\n\(swapped)")
                #expect(try await store.serverRevision(committed) == 1)
                #expect(device.sent(from: index).filter { $0.method != .get }.count == 1, "only the refused send")

                // Resume forwarding as the app does once a scheduler is bound: the swap's flush.
                let scheduler = await device.scheduler(outbox)
                device.bridge.requestFlush(reason: .afterSwap)
                try await eventually("the kept items are resent after the swap") {
                    try await store.items.map(\.id) == [rejected.wireString]
                }
                _ = await scheduler.waitUntilIdle()
                let state = try await store.state()
                #expect(state.epoch == epoch && epoch != oldEpoch && !state.epochSuspect)
                let failed = try #require(try await store.item(rejected))
                #expect(
                    failed.state == .failed && failed.failureReason == .rejected
                        && failed.attempts == before[0].attempts)
                let resent = Array(device.sent(from: index).filter { $0.method != .get }.dropFirst())
                #expect(resent.map(\.method) == [.post, .patch], "the lost create and the update; not the settled one")
                #expect(resent.first?.url.path.hasSuffix("/entries") == true)
                #expect(resent.first?.json?["id"] as? String == lost.wireString)
                #expect(
                    resent.allSatisfy { $0.headers[QuickrHeader.expectEpoch] == epoch },
                    "after the swap every send expects the new epoch")
                #expect(try await it.a.entry(committed)?["revision"] as? Int == 1)
                #expect(try await it.a.entry(lost)?["revision"] as? Int == 1)
                #expect(WebServer.answer(try await it.a.entry(edited)) == 42)
                #expect(try await it.a.entry(rejected) == nil)
            }
        }

        @Test("49 · a queued create, the URL now reaches server b: restored with maybe_delivered 0, b has no entry")
        func case49() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let outbox = try await device.outbox()
                let id = UUID()
                try await outbox.createEntry(id: id, topic: topic, body: logBody(), origin: .app)
                let before = try #require(try await store.item(id))

                #expect(!device.coordinator.status.identityMismatch)
                try await it.proxy.route(to: "b")
                #expect(try await outbox.flush(force: true, budget: .seconds(20)).ending == .mismatch(.identity))
                let item = try #require(try await store.item(id))
                #expect(item.state == .pending && !item.maybeDelivered && item.attempts == before.attempts)
                #expect(item.due == before.due && item.claimToken == nil && item.payloadJSON == before.payloadJSON)
                #expect(try await store.state().identityMismatch)
                #expect(try await outbox.flush(force: true, budget: .seconds(10)).ending == .paused)

                // The identity_mismatch signal ran the coordinator, which now reports the mismatch (no
                // test code calls it; with the flag set it pulls nothing).
                try await eventually("the coordinator reports the mismatch") {
                    device.coordinator.status.identityMismatch
                }
                #expect(try await it.proxy.log().filter { $0.method == "POST" }.allSatisfy { $0.upstreamStatus == 409 })
                #expect(try await it.b.entry(id) == nil)
                #expect(try await it.a.entry(id) == nil)
            }
        }

        // MARK: Garbled success (§5.1, §9.1)

        @Test(
            "59 · POST commits but its 201 is garbled: uncertain; Undo deletes it on the server",
            arguments: [["garble": "truncate"], ["garble": "drop_field", "field": "revision"]])
        func case59(_ garble: [String: String]) async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let outbox = try await device.outbox()
                let id = UUID()
                try await outbox.createEntry(id: id, topic: topic, body: logBody(), origin: .app)
                var rule: [String: Any] = ["action": "garble", "method": "POST", "path": Self.entriesPath]
                rule.merge(garble) { $1 }
                try await it.proxy.add(rule)

                _ = try await outbox.flush(force: true, budget: .seconds(20))
                let item = try #require(try await store.item(id))
                #expect(item.state == .uncertain && item.maybeDelivered)
                #expect(try await it.a.entry(id) != nil, "the POST committed")

                #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
                #expect(try await store.view(id) == nil)
                let index = device.sent().count
                _ = try await outbox.flush(force: true, budget: .seconds(20))
                #expect(device.sent(from: index).map(\.method) == [.delete])
                #expect(try await it.proxy.log().last { $0.method == "DELETE" }?.upstreamStatus == 204)
                #expect(try await it.a.entry(id) == nil)
                #expect(try await store.items.isEmpty)
            }
        }

        // MARK: The production wiring under overlap

        @Test("wiring: scheduler bound from the store's opening; logs, web writes and pulls overlap and converge")
        func wiringBoundThroughout() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTopic()
            let device = try Device(it.config)
            try await device.run {
                let store = try await device.connect()
                let outbox = try await device.outbox()
                let scheduler = await device.scheduler(outbox)  // as the app binds it when a store opens

                // The app logs (each enqueue asks the scheduler to flush) while the web logs and the
                // coordinator pulls; every pull asks the bridge for a flush too.
                var logged: [UUID] = []
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { for n in 0..<6 { try await it.a.createEntry(topic: topic, n: n) } }
                    group.addTask { for _ in 0..<6 { _ = await device.coordinator.sync(reason: .requested) } }
                    for n in 0..<12 {
                        let id = UUID()
                        logged.append(id)
                        try await outbox.createEntry(id: id, topic: topic, body: logBody(n: n), origin: .app)
                        await scheduler.requestFlush(reason: .enqueue)
                    }
                    try await group.waitForAll()
                }

                try await eventually("every log is delivered") { try await store.items.isEmpty }
                _ = await scheduler.waitUntilIdle()
                #expect(await device.coordinator.sync(reason: .requested) == .synced)

                // Each log reached the server exactly once, and the device converged on the server.
                let posts = try await it.proxy.log().filter { $0.method == "POST" && $0.upstreamStatus == 201 }
                #expect(posts.count == logged.count, "\(posts)")
                for id in logged { #expect(try await it.a.entry(id)?["revision"] as? Int == 1) }
                let live = try await it.a.live()
                #expect(try await store.entryRevisions() == live.entries)
                #expect(device.sent(.post).count == logged.count, "no send was repeated")
            }
        }

        // MARK: pull_requested end to end (sync §5.6)

        @Test("a create for a topic deleted on the web: topic_missing, the signal pulls, then deleted_elsewhere")
        func pullRequested() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let outbox = try await device.outbox()
                let id = UUID()
                try await outbox.createEntry(id: id, topic: topic, body: logBody(), origin: .app)
                try await it.a.deleteTopic(topic)
                let pulls = try await it.proxy.log().count { $0.route == "/api/v1/changes" }

                _ = try await outbox.flush(force: true, budget: .seconds(20))
                #expect(try await it.proxy.log().first { $0.method == "POST" }?.upstreamStatus == 404)
                // No test code calls the coordinator: the outbox's signal does.
                try await eventually("the pull tombstones the topic and the create follows it") {
                    try await store.item(id)?.failureReason == .deletedElsewhere
                }
                #expect(try await it.proxy.log().count { $0.route == "/api/v1/changes" } > pulls)
                #expect(try await !store.topicIds().contains(topic.id))
            }
        }
    }
}

extension Array {
    var single: Element? { count == 1 ? first : nil }
}

extension [OutboxItem] {
    var ignoringUpdatedAt: [OutboxItem] {
        map {
            var item = $0
            item.updatedAt = .distantPast
            return item
        }
    }
}

extension LocalStore {
    /// Every row of the server layer and the outbox, for "nothing was written".
    func fingerprint() async throws -> String {
        try await writer.read { db in
            var out = ""
            for table in ["topic", "entry", "tombstone", "outbox_item"] {
                out += "\(table): \(try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2"))\n"
            }
            return out
        }
    }
}
