import Foundation
import QuickrCore
import QuickrData
import Testing

/// sync-protocol.md §13.1 S1, S8 and S9 against the real backend.
extension IntegrationTests {
    @Suite("Sync") struct SyncCases {
        @Test("S1 · empty device: pages commit with their cursor; interrupted, it resumes and matches the server")
        func s1() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTopic()
            var ids: [UUID] = []
            for n in 0..<24 { ids.append(try await it.a.createEntry(topic: topic, n: n)) }
            for id in ids.prefix(3) { try await it.a.updateEntry(id, n: 99) }
            for id in ids.suffix(2) { try await it.a.deleteEntry(id) }

            // Two feed pages go through; the third request fails before the server sees it (a 503
            // from the proxy: a dropped connection would be retried by URLSession, a GET being
            // idempotent).
            let limit = 10
            try await it.proxy.add(["action": "pass", "method": "GET", "path": "/api/v1/changes", "times": 2])
            try await it.proxy.add(["action": "status", "status": 503, "method": "GET", "path": "/api/v1/changes"])
            let device = try Device(it.config, pageLimit: limit)
            try await device.run {
                let result = await device.coordinator.connect(baseURL: it.config.proxyURL)
                guard case .connected(_, _, .failed) = result else {
                    Issue.record("connect: \(result)")
                    return
                }

                // Each committed page came with its cursor: the store holds exactly pages 1 and 2.
                let store = try await device.store()
                let state = try await store.state()
                #expect(!state.bootstrapComplete && state.cursor > 0)
                let feedAfters = device.sent(.get).compactMap(\.after)
                #expect(feedAfters.count == 3 && feedAfters.last == state.cursor)
                let committed = try await Self.pages(it.a, limit: limit, upTo: state.cursor)
                #expect(try await store.entryRevisions() == committed)

                // The app is killed and relaunched: it resumes from the cursor, not from 0.
                let index = device.sent().count
                let relaunched = try device.relaunch(pageLimit: limit)
                #expect(await relaunched.bootstrapIfNeeded() == .synced)
                #expect(device.sent(from: index, .get).compactMap(\.after).first == state.cursor)

                let live = try await it.a.live()
                let final = try await store.state()
                #expect(final.bootstrapComplete && final.rebuilding == nil)
                #expect(try await store.entryRevisions() == live.entries)
                #expect(try await store.topicIds() == live.topics)
                let epoch = try await it.a.identity().epoch
                #expect(final.epoch == epoch)
            }
        }

        @Test("S8 · the URL now reaches another server: server_mismatch, item unchanged, nothing reaches it")
        func s8() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let outbox = try await device.outbox()
                let id = UUID()
                try await outbox.createEntry(id: id, topic: topic, body: logBody(), origin: .app)
                let before = try #require(try await store.item(id))
                let headB = try await it.b.live()

                try await it.proxy.route(to: "b")
                let report = try await outbox.flush(force: true, budget: .seconds(20))
                #expect(report.ending == .mismatch(.identity))

                // Server b refused it without executing; the item is as it was.
                let post = try #require(try await it.proxy.log().first { $0.method == "POST" })
                #expect(post.upstream == "b" && post.upstreamStatus == 409)
                let item = try #require(try await store.item(id))
                #expect(item.state == .pending && !item.maybeDelivered && item.attempts == before.attempts)
                #expect(item.payloadJSON == before.payloadJSON && item.claimToken == nil)

                // The outbox's signal ran the coordinator, which sees the other server too.
                try await eventually("the store is in identity mismatch") { try await store.state().identityMismatch }
                #expect(await device.coordinator.sync(reason: .requested) == .identityMismatch)
                #expect(try await outbox.flush(force: true, budget: .seconds(10)).ending == .paused)

                // Nothing reached server b's data; server a doesn't have it either.
                let afterB = try await it.b.live()
                #expect(afterB.entries == headB.entries && afterB.topics == headB.topics)
                #expect(try await it.b.entry(id) == nil)
                #expect(try await it.a.entry(id) == nil)
            }
        }

        @Test("S9 · the epoch rotates with an item queued: epoch_mismatch, unchanged, rebuild, resend")
        func s9() async throws {
            let it = try await IT.start()
            try await it.withDevice { device, store, topic in
                let outbox = try await device.outbox()
                let scheduler = await device.scheduler(outbox)
                let id = UUID()
                try await outbox.createEntry(id: id, topic: topic, body: logBody(n: 7), origin: .app)
                let before = try #require(try await store.item(id))
                let oldState = try await store.state()
                let epoch = try await rotateEpoch(it.config)
                #expect(epoch != oldState.epoch)

                // Park the coordinator's feed so the restored item can be checked before the rebuild.
                let feed = try await it.proxy.add([
                    "action": "hold", "method": "GET", "path": "/api/v1/changes", "sticky": true,
                ])
                let index = device.sent().count
                let report = try await outbox.flush(force: true, budget: .seconds(20))
                #expect(report.ending == .mismatch(.epoch))
                let refused = try #require(device.sent(from: index, .post).first)
                #expect(refused.headers[QuickrHeader.expectEpoch] == oldState.epoch)
                let item = try #require(try await store.item(id))
                #expect(item.state == .pending && !item.maybeDelivered && item.attempts == before.attempts)
                #expect(item.payloadJSON == before.payloadJSON && item.claimToken == nil)
                #expect(try await it.a.entry(id) == nil)
                try await it.proxy.waitUntilHolding(feed)
                try await it.proxy.release(feed)

                // The signal runs the coordinator: it rebuilds from the new epoch, swaps, and asks the
                // outbox to flush; the item goes out with the new Expect-Epoch.
                try await eventually("the item is delivered after the swap") {
                    try await store.item(id) == nil
                }
                _ = await scheduler.waitUntilIdle()
                let state = try await store.state()
                #expect(state.epoch == epoch && state.layerGen > oldState.layerGen && !state.epochSuspect)
                let resent = try #require(device.sent(from: index, .post).last)
                #expect(resent.headers[QuickrHeader.expectEpoch] == epoch)
                #expect(try await it.a.entry(id)?["revision"] as? Int == 1)
                #expect(try await store.serverRevision(id) == 1)
            }
        }

        /// What the server's feed delivered in its pages of `limit` up to `cursor`: entry id → revision.
        static func pages(_ server: WebServer, limit: Int, upTo cursor: Int) async throws -> [String: Int] {
            var after = 0
            var entries: [String: Int] = [:]
            while after < cursor {
                let page = try await server.http.call("GET", "/api/v1/changes?after=\(after)&limit=\(limit)").object
                var changes: [(seq: Int, id: String, revision: Int?)] = []
                for item in page["items"] as? [[String: Any]] ?? [] where item["kind"] as? String == "entry" {
                    let entry = item["entry"] as? [String: Any] ?? [:]
                    changes.append((item["seq"] as? Int ?? 0, entry["id"] as? String ?? "", entry["revision"] as? Int))
                }
                for item in page["deleted"] as? [[String: Any]] ?? [] where item["kind"] as? String == "entry" {
                    changes.append((item["seq"] as? Int ?? 0, item["id"] as? String ?? "", nil))
                }
                for change in changes.sorted(by: { $0.seq < $1.seq }) { entries[change.id] = change.revision }
                after = try #require(page["next"] as? Int)
            }
            #expect(after == cursor)
            return entries
        }
    }
}

extension HTTPRequest {
    /// The feed's `after` query value.
    var after: Int? {
        guard url.path.hasSuffix("/changes") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "after" }?.value.flatMap(Int.init)
    }
}
