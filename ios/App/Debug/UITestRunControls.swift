#if DEBUG
import SwiftUI

// T2-M1 (timers2.md §6.2, §6.4, §12.3 R14)
/// `-QuickrUITest -QuickrRunControls`: buttons the run UI tests use for another device's write to
/// the run started last on the fake server: "Reopen" reopens it (its terminal stop), "Lap 2"
/// removes its second lap boundary. Each is recorded on the fake server
/// (`FakeServerState.reopenElsewhere`, `removeElsewhere`), which logs the run in the feed, and
/// then this device pulls, as it would on the push that follows. `debug.runResult` shows the
/// server's answer: "reopened", "removed", or what was refused; `debug.serverRun` the latest run
/// as the server holds it ("stopped · laps 3").
struct UITestRunControls: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var result = ""

    static var isShown: Bool {
        UITestLaunch.isActive && ProcessInfo.processInfo.arguments.contains("-QuickrRunControls")
    }

    var body: some View {
        HStack(spacing: 8) {
            control("Reopen", "debug.reopenElsewhere") {
                guard let run = UITestLaunch.server.latestRunId else { return "no run" }
                return UITestLaunch.server.reopenElsewhere(runId: run) ? "reopened" : "reopen refused"
            }
            control("Lap 2", "debug.removeLap2Elsewhere") {
                guard let run = UITestLaunch.server.latestRunId else { return "no run" }
                guard let lap = UITestLaunch.server.lapEventId(runId: run, n: 2) else { return "no lap 2" }
                return UITestLaunch.server.removeElsewhere(runId: run, target: lap) ? "removed" : "remove refused"
            }
            Text(result.isEmpty ? "–" : result)
                .accessibilityLabel(result.isEmpty ? "none" : result)
                .accessibilityIdentifier("debug.runResult")
            // The server's side, so a test can wait for its writes to land before another device's.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let summary = UITestLaunch.server.latestRunSummary ?? "no run"
                Text(summary).accessibilityLabel(summary).accessibilityIdentifier("debug.serverRun")
            }
        }
        .font(.caption)
        .padding(6)
        .background(.thinMaterial, in: Capsule())
    }

    private func control(_ title: String, _ id: String, _ write: @escaping @MainActor () -> String) -> some View {
        Button(title) {
            Task {
                let answer = write()
                _ = await environment.session?.coordinator.sync(reason: .pullToRefresh)
                result = answer
            }
        }
        .accessibilityIdentifier(id)
    }
}
// end T2-M1
#endif
