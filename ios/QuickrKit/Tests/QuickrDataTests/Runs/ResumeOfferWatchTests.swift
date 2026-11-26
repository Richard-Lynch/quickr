import Foundation
import QuickrCore
import QuickrData
import Testing

/// The stop toast's Resume (active-surfaces.md §3.2): `ResumableRun.watchOffer` dismisses the toast
/// once the offer lapses (another run is the latest stop, none is, the observation fails or ends,
/// the window closes on the run clock) and leaves a toast that went by itself alone.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ResumeOfferWatchTests {
    static let runId = "0a000000-0000-4000-8000-000000000001"
    static let stopAt = 1_000_000

    static func offer(_ runId: String = runId) -> ResumableRun {
        ResumableRun(
            runId: runId, topicId: UUID(), terminalId: UUID(), endedAt: stopAt, totalMs: 7000)
    }

    /// Set from the stream's `onTermination` (any thread).
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// A toast and a clock the test moves; `sleep` yields, so the window check spins on the clock.
    /// `clockReads` counts the window checks: the watch reads the clock only once it holds an
    /// offer, so a read proves the offer was consumed and checked.
    @MainActor final class Rig {
        var shown = true
        var dismissed = 0
        var now = ResumeOfferWatchTests.stopAt
        var clockReads = 0
        let terminated = Flag()
        let (offers, feed) = AsyncThrowingStream<ResumableRun?, any Error>.makeStream()

        init() {
            let terminated = terminated
            feed.onTermination = { _ in terminated.raise() }
        }

        /// Yields until `condition` holds (bounded, so a broken watch fails instead of hanging).
        func until(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<10_000 {
                if condition() { return true }
                await Task.yield()
            }
            return condition()
        }

        func watch() async {
            await ResumableRun.watchOffer(
                runId: ResumeOfferWatchTests.runId, offers: offers,
                now: {
                    self.clockReads += 1
                    return self.now
                },
                isShown: { self.shown },
                dismiss: {
                    self.dismissed += 1
                    self.shown = false
                }, tick: .zero,
                sleep: { _ in
                    try Task.checkCancellation()
                    await Task.yield()
                })
        }
    }

    @Test("Another run becomes the latest stop: the toast is dismissed")
    func anotherRunDismisses() async {
        let rig = Rig()
        rig.feed.yield(Self.offer())
        rig.feed.yield(Self.offer("0a000000-0000-4000-8000-000000000002"))
        await rig.watch()
        #expect(rig.dismissed == 1)
        #expect(await rig.until { rig.terminated.value }, "the observation ends with the watch")
    }

    @Test("Nothing offered any more (a start, an edit): dismissed")
    func noOfferDismisses() async {
        let rig = Rig()
        rig.feed.yield(Self.offer())
        rig.feed.yield(nil)
        await rig.watch()
        #expect(rig.dismissed == 1)
    }

    @Test("The observation fails or ends: dismissed")
    func failureDismisses() async {
        struct Closed: Error {}
        let failed = Rig()
        failed.feed.yield(Self.offer())
        failed.feed.finish(throwing: Closed())
        await failed.watch()
        #expect(failed.dismissed == 1)

        let ended = Rig()
        ended.feed.finish()
        await ended.watch()
        #expect(ended.dismissed == 1)
    }

    @Test("The window closes on the run clock, from the stop: dismissed; not a moment before")
    func windowDismisses() async {
        let rig = Rig()
        rig.feed.yield(Self.offer())
        rig.now = Self.stopAt + RunPresentation.reopenWindowMs
        let watching = Task { await rig.watch() }
        #expect(await rig.until { rig.clockReads >= 2 }, "the offer was consumed and the clock read")
        #expect(rig.dismissed == 0, "15 minutes exactly is still offered")
        rig.now += 1
        await watching.value
        #expect(rig.dismissed == 1)
        #expect(await rig.until { rig.terminated.value }, "the observation ends with the watch")
    }

    @Test("The toast went by itself: the watch ends without dismissing")
    func goneByItself() async {
        let rig = Rig()
        rig.feed.yield(Self.offer())
        let watching = Task { await rig.watch() }
        #expect(await rig.until { rig.clockReads >= 1 }, "watching the offer")
        rig.shown = false
        await watching.value
        #expect(rig.dismissed == 0)
        #expect(await rig.until { rig.terminated.value }, "the observation ends with the toast")
    }

    @Test("The caller is cancelled: the watch ends and its observation with it")
    func cancelledEnds() async {
        let rig = Rig()
        rig.feed.yield(Self.offer())
        let watching = Task { await rig.watch() }
        #expect(await rig.until { rig.clockReads >= 1 })
        watching.cancel()
        await watching.value
        #expect(rig.dismissed == 0, "cancelled, not lapsed")
        #expect(await rig.until { rig.terminated.value }, "the observation ends with the watch")
    }
}
