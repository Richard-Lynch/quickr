// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// R5 (timers.md §8.1, §8.3, §10.3) with real processes: the app and the widget each tap through
/// `RunWrites` on their own connection to the shared store file, at the same wall-clock instant.
extension MultiProcessTests {
    @Suite struct RunMP {
        @Test("R5 · MP: the widget's Next and the app's Next for one segment, at one instant: both queued, one applies")
        func twoNextsOneSegment() async throws {
            try await OutboxWorld.run { w in
                let steps = [TopicTimer.Step(key: "wash", label: "Wash"), TopicTimer.Step(key: "dry", label: "Dry")]
                w.server.time(w.topic.id, FakeTimer(steps: steps))
                let version = TopicVersion(
                    version: 1, questions: [], timer: TopicTimer(steps: steps), createdAt: Make.t0)
                let topicId = w.topic.id
                try await w.store.writer.write { db in
                    _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topicId)
                }
                let app = try await w.world.spawn("app:A")
                let widget = try await w.world.spawn("widget:B", open: "extension")
                let started = try await app.run("runStart", w.topicArgs)
                let runId = try #require(started["runId"])
                #expect(started["started"] == "true")

                // Both surfaces showed segment 0, and tap at the same instant.
                let tap = ["type": "next", "runId": runId, "seg": "0"]
                let fromApp = try app.start("runTap", tap)
                let fromWidget = try widget.start("runTap", tap)
                let appReply = try await app.reply(fromApp)
                let widgetReply = try await widget.reply(fromWidget)
                #expect(appReply.result["result"] == "appended")
                #expect(widgetReply.result["result"] == "appended")

                let nexts = w.items.filter { $0.kind == .runEvent && $0.id != runId }
                #expect(nexts.count == 2)
                let payloads = try nexts.map { try #require(try $0.runEventPayload()) }
                let segs: [Int?] = payloads.map(\.event.seg)
                #expect(segs == [0, 0])
                let ats = payloads.compactMap { RunInstant.parse($0.event.at) }
                #expect(Set(ats).count == 2, "one device's taps never share an at")
                let origins: Set<OutboxOrigin> = Set(nexts.map(\.origin))
                #expect(origins == [.app, .widget])

                // The local view, the fold the server runs, already shows one advance.
                let local = try await w.store.runs.localRun(id: UUID(uuidString: runId)!)
                let run = try #require(local)
                let open = try #require(run.state.open)
                #expect(open.index == 1)
                let effects = nexts.compactMap { run.state.effects[$0.id] }
                #expect(effects.filter { $0 == .applied }.count == 1)
                #expect(effects.filter { $0 == .void(.stale) }.count == 1)

                let report = try await app.run("flush")
                #expect(report["acked"] == "3")
                let server = try #require(w.server.run(runId))
                let serverOpen = try #require(server.state.open)
                #expect(serverOpen.index == 1)
                #expect(server.state.segments.map(\.label) == ["Wash"])
                let serverEffects = nexts.compactMap { server.state.effects[$0.id] }
                #expect(serverEffects.filter { $0 == .applied }.count == 1)
                #expect(serverEffects.filter { $0 == .void(.stale) }.count == 1)
            }
        }
    }
}
#endif
