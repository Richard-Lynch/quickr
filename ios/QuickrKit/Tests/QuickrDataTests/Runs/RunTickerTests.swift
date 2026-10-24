import Foundation
import QuickrCore
import QuickrData
import Synchronization
import Testing

/// The one shared run clock (`RunTicker`): it ticks on whole server seconds only while a view
/// holds it, and its loop ends with the last holder.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RunTickerTests {
    /// A device clock and a sleep the test drives: each sleep records its length, moves the clock
    /// by it and returns at once.
    final class Time: Sendable {
        private let state = Mutex<(now: Int, sleeps: [Int])>((1_000_250, []))
        var now: Int { state.withLock { $0.now } }
        var sleeps: [Int] { state.withLock { $0.sleeps } }

        func sleep(_ duration: Duration) async throws {
            let ms = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
            state.withLock { state in
                state.sleeps.append(ms)
                state.now += ms
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func ticksOnWholeServerSecondsWhileHeldAndStopsWithTheLastHolder() async throws {
        let time = Time()
        let ticker = RunTicker(clock: { time.now }, sleep: { try await time.sleep($0) })
        ticker.offsetMs = 100
        #expect(ticker.isTicking == false)
        ticker.retain()
        ticker.retain()
        #expect(ticker.isTicking)
        let first = ticker.serverNow
        #expect(first == 1_000_350)
        while time.sleeps.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        // The first wait reaches the next whole second of the server's clock: 1_001_000.
        let waits = time.sleeps
        let firstWait: Int = waits[0]
        #expect(firstWait == 650)
        let secondWait: Int = waits[1]
        #expect(secondWait == 1000)
        let later = ticker.serverNow
        #expect(later > first)

        ticker.release()
        #expect(ticker.isTicking, "one view still shows a running clock")
        ticker.release()
        #expect(ticker.isTicking == false)
        let holders = ticker.holders
        #expect(holders == 0)
        let count = time.sleeps.count
        try await Task.sleep(for: .milliseconds(50))
        let after = time.sleeps.count
        #expect(after <= count + 1, "no tick loop runs once released")
    }
}
