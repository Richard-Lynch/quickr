// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// sync-protocol.md §13 S3, S4, S7, S11–S13 and S16–S19, and notifications.md N4, with real
/// processes: each coordinator, flusher, widget and NSE is a `ProcessHelper` child with its own
/// SQLite connections; the feed is `FakeFeedServer` over loopback HTTP.
extension MultiProcessTests {
    @Suite struct SyncMP {
        static let e2 = SyncRebuildTests.e2
        static let serverId = FakeFeedServer.defaultServerId
        static let water = ["topicId": FakeFeedServer.water, "slug": "water", "name": "Water", "key": "glasses"]

        /// S3: coordinator A has fetched page P and is SIGSTOPped past its 60 s lease; B pulls and
        /// rebuilds. A resumes and applies P: its fence fails (token and `layer_gen`), nothing is
        /// written.
        @Test("S3 · MP: a SIGSTOPped coordinator's page after a takeover writes nothing")
        func s3() async throws {
            try await SyncWorld.run { w in
                let store = try await w.connect()
                let start = w.afters.count
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("app:B")
                w.feed.addEntry()
                let gate = w.world.gate()
                w.router.holdFeed(where: { $0 == 16 }, at: gate)
                let syncA = try a.start("sync")
                try await gate.arrived()  // A has its page (built now), the answer is held
                a.suspend()
                try w.world.leaseClock.advance(by: .seconds(61))
                w.rotateEpoch(to: Self.e2)

                #expect(try await b.run("sync")["result"] == "synced")
                let rebuilt = try await store.mpState()
                #expect(rebuilt.layerGen == 2 && rebuilt.epoch == Self.e2)
                // A's page; B's live page (epoch mismatch), staged page, live page after the swap.
                #expect(Array(w.afters.dropFirst(start)) == [16, 16, 0, 17])
                let before = try await store.fingerprint()

                a.resume()
                gate.open()
                #expect(try await a.reply(syncA).result["result"] == "superseded")
                #expect(try await store.fingerprint() == before)
                #expect(Array(w.afters.dropFirst(start)) == [16, 16, 0, 17])  // A sent nothing more
            }
        }

        /// S4: staging for E2 is part-way when the coordinator is SIGKILLed holding `sync`. The
        /// relaunched coordinator reads `rebuilding` before any request, fetches `after =
        /// stage cursor` with the staging context, never pulls live or restarts staging, swaps
        /// exactly once and then pulls live from the new cursor.
        @Test("S4 · MP: a coordinator killed mid-staging; the relaunch resumes staging first")
        func s4() async throws {
            try await SyncWorld.run { w in
                let store = try await w.connect()
                #expect(try await store.mpState().cursor == 16)
                w.rotateEpoch(to: Self.e2)
                for minute in 0..<30 { w.feed.addEntry(minutes: minute) }
                let head = w.feed.head
                let a = try await w.world.spawn("app:A", pageLimit: 5)
                let gate = w.world.gate()
                w.router.holdFeed(where: { $0 > 20 && $0 != 16 }, at: gate)
                _ = try a.start("sync")
                try await gate.arrived()  // A is mid-staging, holding `sync`
                await a.killNow()
                gate.open()

                let stageCursor = try await store.writer.read { db in
                    try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state")
                }
                let c = try #require(stageCursor)
                #expect(c > 20 && c < head)
                #expect(try await store.mpState().rebuilding == Self.e2)
                #expect(try await store.count("stage_entry") > 0)
                #expect(try await store.leases.record(.sync).owner == "app:A")

                let relaunched = try await w.world.spawn("app:B", pageLimit: 5)
                let index = w.afters.count
                #expect(try await relaunched.run("sync")["result"] == "busy")
                try w.world.leaseClock.advance(by: .seconds(61))
                #expect(try await relaunched.run("sync")["result"] == "synced")
                let afters = Array(w.afters.dropFirst(index))
                #expect(afters.first == c)
                #expect(!afters.contains(16) && !afters.contains(0))
                #expect(afters.last == head && afters.filter { $0 == head }.count == 1)
                #expect(afters.dropLast().allSatisfy { $0 >= c && $0 < head })
                let state = try await store.mpState()
                #expect(state.layerGen == 2 && state.epoch == Self.e2 && state.cursor == head)
                #expect(try await store.ids("entry") == Set(w.feed.liveEntries().keys))
            }
        }

        /// S7: widget and NSE processes have pools open on `g1` during a reset. Their next
        /// transaction sees `retired`; they reopen `g2`; the widget's write lands in `g2`. `g1` is
        /// deleted once retired for 10 minutes of lease time.
        @Test("S7 · MP: extension processes with pools open on g1 reopen g2 after a reset")
        func s7() async throws {
            try await SyncWorld.run { w in
                let g1 = try await w.connect()
                let widget = try await w.world.spawn("widget:W", open: "extension")
                let nse = try await w.world.spawn("nse:N", open: "extension")
                let app = try await w.world.spawn("app:A")
                #expect(try await app.run("resetWarning")["count"] == "0")
                let start = w.afters.count
                let outcome = try await app.run("performReset")["outcome"] ?? ""
                #expect(outcome.hasPrefix("completed(storeGen: 2"))
                #expect(Array(w.afters.dropFirst(start)) == [0])  // g2's bootstrap
                #expect(try await widget.run("isRetired")["retired"] == "true")
                #expect(try await nse.run("isRetired")["retired"] == "true")

                let id = UUID()
                let logged = try await widget.run("log", Self.water.merging(["id": id.wireString]) { $1 })
                #expect(logged["reopened"] == "true" && logged["storeGen"] == "2")
                let g2 = try await w.world.activeStore()
                #expect(g2.storeGen == 2)
                #expect(try await g2.item(id.wireString) != nil)
                #expect(try await g1.item(id.wireString) == nil)
                #expect(try await nse.run("open", ["role": "extension"])["storeGen"] == "2")

                try w.world.leaseClock.advance(by: .seconds(601))
                #expect(try await w.world.partitions.deleteRetiredFiles() == ["stores/\(Self.serverId).g1.sqlite"])
            }
        }

        /// S11: while A holds `sync`, the wall clock moves 3 h back, then 3 h forward. B is refused
        /// both times; only lease time (and A's renewals) decide.
        @Test("S11 · MP: wall-clock jumps neither free the sync lease early nor strand it")
        func s11() async throws {
            try await SyncWorld.run { w in
                try await w.connect()
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("app:B")
                #expect(try await a.run("leaseAcquire", ["name": "sync"])["acquired"] == "true")
                try w.world.wall.advance(by: -3 * 3600)
                #expect(try await b.run("leaseAcquire", ["name": "sync"])["acquired"] == "false")
                #expect(try await b.run("sync")["result"] == "busy")
                try w.world.wall.advance(by: 6 * 3600)
                #expect(try await b.run("leaseAcquire", ["name": "sync"])["acquired"] == "false")
                try w.world.leaseClock.advance(by: .seconds(59))
                #expect(try await a.run("leaseRenew", ["name": "sync"])["renewed"] == "true")
                try w.world.leaseClock.advance(by: .seconds(59))
                #expect(try await b.run("leaseAcquire", ["name": "sync"])["acquired"] == "false")
                try w.world.leaseClock.advance(by: .seconds(2))
                #expect(try await b.run("leaseAcquire", ["name": "sync"])["acquired"] == "true")
                #expect(try await a.run("leaseRenew", ["name": "sync"])["renewed"] == "false")
            }
        }

        /// The production lease clock (`mach_continuous_time` + `kern.bootsessionuuid`) agrees
        /// across processes: a lease one process holds is valid in another.
        @Test("S11 · MP: production lease time is consistent across processes")
        func s11SystemClock() async throws {
            try await SyncWorld.run { w in
                try await w.connect()
                let a = try await w.world.spawn("app:A", leaseClock: "system")
                let b = try await w.world.spawn("app:B", leaseClock: "system")
                #expect(try await a.run("leaseAcquire", ["name": "sync"])["acquired"] == "true")
                #expect(try await b.run("leaseAcquire", ["name": "sync"])["acquired"] == "false")
                #expect(try await a.run("leaseRenew", ["name": "sync"])["renewed"] == "true")
                #expect(try await a.run("leaseRelease", ["name": "sync"])["released"] == "true")
                #expect(try await b.run("leaseAcquire", ["name": "sync"])["acquired"] == "true")
            }
        }

        /// S12: a `sync` lease left by a process from a previous boot is taken at once.
        @Test("S12 · MP: a lease row from a previous boot is acquired immediately")
        func s12() async throws {
            try await SyncWorld.run { w in
                let store = try await w.connect()
                let old = try await w.world.spawn("app:old")
                #expect(try await old.run("leaseAcquire", ["name": "sync"])["acquired"] == "true")
                await old.killNow()
                let app = try await w.world.spawn("app:A")
                let start = w.afters.count
                #expect(try await app.run("sync")["result"] == "busy")
                try w.world.leaseClock.reboot(bootId: "boot-2", ct: 5)
                w.feed.addEntry()
                #expect(try await app.run("sync")["result"] == "synced")
                #expect(try await store.mpState().cursor == 17)
                #expect(Array(w.afters.dropFirst(start)) == [16])  // busy sent nothing
            }
        }

        /// S13: a rebuild (A) and a reset (B) are requested together. Both take `sync` then
        /// `flush`; B waits for A, then resets. No deadlock.
        @Test("S13 · MP: a rebuild and a reset in two processes run one after the other")
        func s13() async throws {
            try await SyncWorld.run { w in
                let g1 = try await w.connect()
                let start = w.afters.count
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("app:B")
                w.rotateEpoch(to: Self.e2)
                let gate = w.world.gate()
                w.router.holdFeed(where: { $0 == 0 }, at: gate)  // A's first staged page
                let rebuild = try a.start("sync")
                try await gate.arrived()
                #expect(try await b.run("resetWarning")["count"] == "0")
                let reset = try b.start("performReset")
                try await eventually("B persisted its intent") {
                    try await w.world.server(Self.serverId).pendingGen == 2
                }
                #expect(try await !g1.isRetired())  // B waits for `sync`
                gate.open()
                #expect(try await a.reply(rebuild).result["result"] == "synced")
                let outcome = try await b.reply(reset, timeout: .seconds(60)).result["outcome"] ?? ""
                #expect(
                    outcome == "completed(storeGen: 2, bootstrap: QuickrData.SyncResult.synced)"
                        || outcome.hasPrefix("completed(storeGen: 2"))
                #expect(try await g1.mpState().layerGen == 2)
                #expect(try await g1.isRetired())
                let server = try await w.world.server(Self.serverId)
                #expect(server.storeGen == 2 && server.pendingGen == nil)
                // A: live (mismatch), staged, live after its swap; then B bootstraps g2.
                #expect(Array(w.afters.dropFirst(start)) == [16, 0, 16, 0])
                let g2 = try await w.world.activeStore()
                let g2State = try await g2.mpState()
                #expect(g2State.epoch == Self.e2 && g2State.bootstrapComplete)
            }
        }

        /// S16: a widget flusher holding `flush` gets 409 `epoch_mismatch`. Its outcome
        /// transaction sets `epoch_suspect`; it releases `flush`, then posts `sync-requested`.
        /// The app's coordinator (listening) takes `sync` → `flush` without deadlock; claims stay
        /// refused until the swap clears `epoch_suspect`; the item is then resent with the new
        /// epoch.
        @Test("S16 · MP: a flusher's epoch_mismatch signals the app's coordinator after releasing flush")
        func s16() async throws {
            try await SyncWorld.run { w in
                let store = try await w.connect()
                let start = w.afters.count
                let water = try #require(try await store.topics.topic(id: UUID(uuidString: FakeFeedServer.water)!))
                w.api.put(water.topic)
                let app = try await w.world.spawn("app:A")
                try await app.run("listen")
                let widget = try await w.world.spawn("widget:W", open: "extension")
                let id = UUID()
                try await widget.run("log", Self.water.merging(["id": id.wireString]) { $1 })
                w.rotateEpoch(to: Self.e2)
                let gate = w.world.gate()
                w.router.holdFeed(where: { $0 == 16 }, at: gate)  // the coordinator's live page

                let report = try await widget.run("flush")
                #expect(
                    report["ending"] == "mismatch(QuickrData.OutboxMismatch.epoch)"
                        || report["ending"] == "mismatch(epoch)")
                #expect(try await store.leases.record(.flush).owner == nil)  // released before the signal
                try await gate.arrived()  // the signal reached the app: its coordinator is pulling
                #expect(try await store.mpState().epochSuspect)
                #expect(try await store.item(id.wireString)?.state == .pending)
                #expect(try await widget.run("flush")["ending"] == "paused")  // claims refused

                gate.open()
                try await eventually("the app's coordinator swapped") {
                    let state = try await store.mpState()
                    return state.layerGen == 2 && !state.epochSuspect
                }
                try await app.run("waitIdle")  // its live pull after the swap is done too
                #expect(try await widget.run("flush")["acked"] == "1")
                // The coordinator: live (held, then mismatch), staged, live after the swap.
                #expect(Array(w.afters.dropFirst(start)) == [16, 0, 16])
                #expect(w.api.requests.count == 2)
                let posts = w.api.requests.filter { $0.method == .post }
                #expect(posts.count == 2)
                #expect(posts.first?.headers[QuickrHeader.expectEpoch] == FakeFeedServer.fixtureEpoch)
                #expect(posts.last?.headers[QuickrHeader.expectEpoch] == Self.e2)
                #expect(w.api.entry(id) != nil)
            }
        }

        /// S17: the intent is persisted (step 2) and the app is killed before step 4. An extension
        /// keeps using the old file; the relaunched app resumes at step 3, re-checks against the
        /// persisted count, retires, advances and bootstraps the new file.
        @Test("S17 · MP: the app killed after persisting the reset intent; the relaunch completes it")
        func s17() async throws {
            try await SyncWorld.run { w in
                let g1 = try await w.connect()
                let app = try await w.world.spawn("app:A")
                #expect(try await app.run("persistIntent")["pendingGen"] == "2")
                await app.killNow()

                let widget = try await w.world.spawn("widget:W", open: "extension")
                #expect(try await widget.run("isRetired")["retired"] == "false")
                #expect(try await w.world.server(Self.serverId).storeGen == 1)

                let relaunched = try await w.world.spawn("app:B", open: nil)
                let start = w.afters.count
                let result = try await relaunched.run("bootstrap")
                #expect(result["result"] == "synced")
                #expect(Array(w.afters.dropFirst(start)) == [0])  // g2's bootstrap, once
                #expect(result["resumedReset"]?.hasPrefix("completed(storeGen: 2") == true)
                #expect(try await g1.isRetired())
                let server = try await w.world.server(Self.serverId)
                #expect(server.storeGen == 2 && server.pendingGen == nil)
                let g2 = try await w.world.activeStore()
                #expect(try await !g2.isRetired())
                #expect(try await g2.mpState().bootstrapComplete)
            }
        }

        /// S18: the old file is retired (step 4) and the app is killed before step 6. A widget
        /// opening the store completes step 6 itself, opens the new empty file, and its enqueue
        /// lands there. A later app launch bootstraps the file and doesn't repeat step 6.
        @Test("S18 · MP: the app killed after retiring; a widget completes the advance")
        func s18() async throws {
            try await SyncWorld.run { w in
                let g1 = try await w.connect()
                let app = try await w.world.spawn("app:A")
                try await app.run("persistIntent")
                #expect(try await app.run("leaseAcquire", ["name": "sync"])["acquired"] == "true")
                #expect(try await app.run("leaseAcquire", ["name": "flush"])["acquired"] == "true")
                #expect(try await app.run("retire")["outcome"] == "retired")
                await app.killNow()
                #expect(try await g1.isRetired())
                #expect(try await w.world.server(Self.serverId).storeGen == 1)

                let widget = try await w.world.spawn("widget:W", open: "extension")
                #expect(try await w.world.server(Self.serverId).storeGen == 2)
                let id = UUID()
                let logged = try await widget.run("log", Self.water.merging(["id": id.wireString]) { $1 })
                #expect(logged["result"] == "appended" && logged["reopened"] == nil)
                let g2 = try await w.world.activeStore()
                #expect(try await g2.item(id.wireString) != nil)
                #expect(try await !g2.mpState().bootstrapComplete)

                let relaunched = try await w.world.spawn("app:B", open: nil)
                let start = w.afters.count
                #expect(try await relaunched.run("bootstrap")["result"] == "synced")
                #expect(Array(w.afters.dropFirst(start)) == [0])  // g2's bootstrap, once
                let state = try await g2.mpState()
                #expect(state.bootstrapComplete && state.cursor == 16)
                #expect(try await g2.item(id.wireString)?.state == .pending)
                let server = try await w.world.server(Self.serverId)
                #expect(server.storeGen == 2 && server.pendingGen == nil)
                #expect(try await w.world.partitions.registry.retiredFiles().count == 1)
            }
        }

        /// S19: the user confirmed a reset with N = 2; a widget process enqueues a third before
        /// step 4. The re-check sees 3 > 2: the reset aborts, nothing is retired, the intent is
        /// cleared, and the warning comes back with N = 3.
        @Test("S19 · MP: a widget's enqueue after the warning aborts the app's reset")
        func s19() async throws {
            try await SyncWorld.run { w in
                let g1 = try await w.connect()
                let app = try await w.world.spawn("app:A")
                let widget = try await w.world.spawn("widget:W", open: "extension")
                for _ in 0..<2 {
                    try await app.run("log", Self.water.merging(["id": UUID().wireString]) { $1 })
                }
                #expect(try await app.run("resetWarning")["count"] == "2")
                let start = w.afters.count
                try await widget.run("log", Self.water.merging(["id": UUID().wireString]) { $1 })
                let outcome = try await app.run("performReset")["outcome"] ?? ""
                #expect(outcome.hasPrefix("writesArrived") && outcome.contains("count: 3"))
                #expect(try await !g1.isRetired())
                let server = try await w.world.server(Self.serverId)
                #expect(server.storeGen == 1 && server.pendingGen == nil)
                #expect(try await g1.outbox.summary().count == 3)
                #expect(w.afters.count == start && w.api.requests.isEmpty)  // an aborted reset pulls nothing
            }
        }

        /// N4: two processes insert and register categories at the same time, 100 times each, in
        /// lockstep (both register in every round, in whichever order the registry lock grants).
        /// Each registration (one registry `IMMEDIATE` transaction: insert, read all, register) saw
        /// exactly the union of everything committed before it; the table holds the union; and the
        /// final registration in each process carries the whole durable table. Uncapped, as the
        /// union is what shows the lock at work; `n4Capped` runs it with the cap.
        @Test("N4 · MP: concurrent category registration always registers the union")
        func n4() async throws {
            try await SyncWorld.run { w in
                try await w.connect()
                let app = try await w.world.spawn("app:A", open: nil)
                let nse = try await w.world.spawn("nse:N", open: nil)
                let log = w.world.root.appending(path: "registrations.log")
                let args = ["count": "100", "log": log.path, "participants": "2"]
                let first = try app.start("registerCategories", args.merging(["prefix": "a"]) { $1 })
                let second = try nse.start("registerCategories", args.merging(["prefix": "b"]) { $1 })
                #expect(try await app.reply(first, timeout: .seconds(90)).ok)
                #expect(try await nse.reply(second, timeout: .seconds(90)).ok)

                let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                    $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                }
                try #require(lines.count == 202 && lines.allSatisfy { $0.count == 3 })
                let table = Set(try await w.world.partitions.registry.repository.notificationCategories().map(\.id))
                #expect(table.count == 200)
                var inserted: Set<String> = []
                for (index, line) in lines.enumerated() {
                    if line[1] != "final" { inserted.insert(line[1]) }
                    #expect(Set(line[2].split(separator: ",").map(String.init)) == inserted, "line \(index)")
                }
                // Overlap: every round has one registration from each process.
                for round in 0..<100 {
                    #expect(
                        Set([lines[2 * round][0], lines[2 * round + 1][0]]) == ["app:A", "nse:N"], "round \(round)")
                }
                // The last registration in each process received the final union.
                let finals = lines.suffix(2)
                #expect(Set(finals.map { $0[0] }) == ["app:A", "nse:N"] && finals.allSatisfy { $0[1] == "final" })
                for final in finals { #expect(Set(final[2].split(separator: ",").map(String.init)) == table) }
                #expect(inserted == table)
            }
        }

        /// N4 with the cap (§5.2): the same lockstep, each process capped at 50 of 120 rows. Every
        /// registration is a capped subset of what was committed before it, and the final ones
        /// carry the 50 most recently wanted rows, the same in both processes.
        @Test("N4 · MP: capped concurrent registration selects the same rows in every process")
        func n4Capped() async throws {
            try await SyncWorld.run { w in
                try await w.connect()
                let app = try await w.world.spawn("app:A", open: nil)
                let nse = try await w.world.spawn("nse:N", open: nil)
                let log = w.world.root.appending(path: "registrations.log")
                let args = ["count": "60", "log": log.path, "participants": "2", "cap": "50"]
                let first = try app.start("registerCategories", args.merging(["prefix": "a"]) { $1 })
                let second = try nse.start("registerCategories", args.merging(["prefix": "b"]) { $1 })
                #expect(try await app.reply(first, timeout: .seconds(90)).ok)
                #expect(try await nse.reply(second, timeout: .seconds(90)).ok)

                let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                    $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                }
                try #require(lines.count == 122 && lines.allSatisfy { $0.count == 3 })
                var inserted: Set<String> = []
                for (index, line) in lines.enumerated() {
                    if line[1] != "final" { inserted.insert(line[1]) }
                    let registered = Set(line[2].split(separator: ",").map(String.init))
                    #expect(registered.isSubset(of: inserted), "line \(index)")
                    #expect(registered.count == min(50, inserted.count), "line \(index)")
                    if line[1] != "final" { #expect(registered.contains(line[1]), "the new row is in: line \(index)") }
                }
                // Every row is current, so none was deleted; the finals are the 50 most recent.
                let rows = try await w.world.partitions.registry.writer.read { db in
                    try String.fetchAll(
                        db, sql: "SELECT id FROM notification_category ORDER BY used_at DESC, id LIMIT 50")
                }
                let finals = lines.suffix(2)
                #expect(inserted.count == 120)
                for final in finals { #expect(Set(final[2].split(separator: ",").map(String.init)) == Set(rows)) }
            }
        }
    }
}
#endif
