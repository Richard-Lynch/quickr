// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// timers.md §13.3 R5 with real processes and the real server: the app and the widget are
/// `ProcessHelper agent` children on one device's store files (as the MP suite runs them against
/// the fake server, MultiProcess/RunMultiProcessTests.swift), and both flush to the backend
/// through the proxy at once.
extension IntegrationTests {
    @Suite("Runs · MP") struct RunMPCases {
        @Test(
            "R5 · MP · the widget's Next and the app's Next for one segment, at one instant, both flushing: the server applies one"
        )
        func r5() async throws {
            let it = try await IT.start()
            let steps = [TopicTimer.Step(key: "wash", label: "Wash"), TopicTimer.Step(key: "dry", label: "Dry")]
            let topic = try await it.a.createTimedTopic(steps: steps)
            try await it.withTimedDevice(topic) { device, store in
                let children = try await MPDevice(device)
                try await children.run { app, widget in
                    let topicArgs = ["topicId": topic.id, "slug": topic.slug, "name": topic.name, "version": "1"]
                    try children.wall.set(Date())
                    let started = try await app.run("runStart", topicArgs)
                    let runId = try #require(started["runId"])
                    #expect(started["started"] == "true")
                    let startFlush = try await app.run("flush")
                    #expect(startFlush["acked"] == "1")

                    // Both surfaces showed segment 0, and tap at the same instant.
                    try children.wall.set(Date())
                    let tap = ["type": "next", "runId": runId, "seg": "0"]
                    let fromApp = try app.start("runTap", tap)
                    let fromWidget = try widget.start("runTap", tap)
                    let appTap = try await app.reply(fromApp).result
                    let widgetTap = try await widget.reply(fromWidget).result
                    #expect(appTap["result"] == "appended")
                    #expect(widgetTap["result"] == "appended")
                    let appNext: String = try #require(appTap["itemId"])
                    let widgetNext: String = try #require(widgetTap["itemId"])
                    let nextIds: [String] = [appNext, widgetNext]
                    try #require(nextIds.count == 2)

                    // Both processes flush at once; the flush lease lets one send both, or each its share.
                    let appFlush = try app.start("flush")
                    let widgetFlush = try widget.start("flush")
                    let appReport = try await app.reply(appFlush, timeout: .seconds(40))
                    let widgetReport = try await widget.reply(widgetFlush, timeout: .seconds(40))
                    let appAcked: Int = Int(appReport.result["acked"] ?? "") ?? 0
                    let widgetAcked: Int = Int(widgetReport.result["acked"] ?? "") ?? 0
                    let acked: Int = appAcked + widgetAcked
                    #expect(acked == 2, "\(appReport.result) \(widgetReport.result)")
                    let left: Int = try await store.items.count
                    #expect(left == 0)

                    let runUUID = try #require(UUID(uuidString: runId))
                    let run = try #require(try await it.serverRun(runUUID))
                    let open = try #require(run.state.open)
                    #expect(open.index == 1, "one advance")
                    let labels: [String] = run.state.segments.map(\.label)
                    #expect(labels == ["Wash"])
                    let effects: [RunEffect] = nextIds.compactMap { run.state.effects[$0] }
                    let applied: Int = effects.filter { $0 == .applied }.count
                    let stale: Int = effects.filter { $0 == .void(.stale) }.count
                    #expect(applied == 1)
                    #expect(stale == 1)
                    let events: Int = run.events.count
                    #expect(events == 3, "both Nexts stored")

                    // The device's view after the acks is the server's.
                    let local = try #require(try await store.runs.localRun(id: run.id))
                    let localOpen = try #require(local.state.open)
                    #expect(localOpen.index == 1)
                }
            }
        }
    }
}

/// The app (`app:A`) and the widget (`widget:B`) as child processes over `device`'s App Group
/// directory. Lease time is the production clock in the children (the test process holds no lease
/// while they run); wall time is a shared file the test sets to now before each tap, so the
/// server accepts the stamps.
final class MPDevice: Sendable {
    let device: Device
    let wall: FileWallClock
    let scope = "it-mp-\(UUID().uuidString.prefix(8))"

    init(_ device: Device) async throws {
        self.device = device
        wall = try FileWallClock.create(at: device.dir.appending(path: "wall-clock"), date: Date())
    }

    func spawn(_ owner: String, role: String) async throws -> HelperProcess {
        let child = try HelperProcess(
            name: owner,
            arguments: [
                "--root", device.dir.path, "--owner", owner, "--lease-clock", "system", "--wall-clock", wall.url.path,
                "--scope", scope,
            ])
        _ = try await child.run("ping")
        try await child.run("open", ["role": role])
        return child
    }

    /// Runs `body` with both children, and kills them on every path.
    func run(_ body: (HelperProcess, HelperProcess) async throws -> Void) async throws {
        var children: [HelperProcess] = []
        do {
            let app = try await spawn("app:A", role: "app")
            children.append(app)
            let widget = try await spawn("widget:B", role: "extension")
            children.append(widget)
            try await body(app, widget)
        } catch {
            for child in children { await child.killNow() }
            throw error
        }
        for child in children { await child.finish() }
    }
}
#endif
