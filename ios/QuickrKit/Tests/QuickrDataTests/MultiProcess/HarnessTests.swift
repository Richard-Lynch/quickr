// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import QuickrData
import QuickrTestSupport
import Testing

/// The multi-process harness itself: a broken child can fail a test, never hang it or its
/// teardown.
extension MultiProcessTests {
    @Suite struct Harness {
        @Test("a child that never replies times out; cancellation ends a wait; shutdown reaps the child")
        func unrepliedCommandsAreBounded() async throws {
            let w = try await OutboxWorld()
            let child = try await w.world.spawn("app:A")
            let pid = child.pid

            // A command the child never answers: the wait ends at its timeout.
            let hung = try child.start("hang")
            let started = ContinuousClock.now
            await #expect(throws: HelperError.self) { try await child.reply(hung, timeout: .milliseconds(300)) }
            #expect(ContinuousClock.now - started < .seconds(10))

            // A SIGSTOPped child can't answer even a ping.
            child.suspend()
            await #expect(throws: HelperError.self) { try await child.run("ping", timeout: .milliseconds(300)) }

            // Cancellation ends a wait, also when it comes before the wait registers.
            let early = Task { try await child.reply(try child.start("ping"), timeout: .seconds(600)) }
            early.cancel()
            await #expect(throws: (any Error).self) { try await early.value }
            let late = Task { try await child.reply(try child.start("ping"), timeout: .seconds(600)) }
            try await Task.sleep(for: .milliseconds(50))
            late.cancel()
            let cancelled = ContinuousClock.now
            await #expect(throws: CancellationError.self) { try await late.value }
            #expect(ContinuousClock.now - cancelled < .seconds(10))

            // Teardown still reaps the stopped, hung child.
            await w.world.shutdown()
            #expect(!child.isRunning)
            #expect(kill(pid, 0) != 0)
        }
    }
}
#endif
