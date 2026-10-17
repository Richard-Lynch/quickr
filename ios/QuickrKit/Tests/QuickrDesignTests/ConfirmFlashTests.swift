import QuickrUI
import Testing

@MainActor @Suite struct ConfirmFlashTests {
    @Test func lightsForTheDurationThenClears() async {
        let sleeper = Sleeper()
        let flash = ConfirmFlash(sleep: { try await sleeper.sleep($0) })
        flash.confirm("mild")
        #expect(flash.value == "mild")
        await sleeper.waitFor(requested: 1, asleep: 1)
        #expect(await sleeper.requested == [.milliseconds(1600)])
        await sleeper.wakeAll()
        await waitUntil { flash.value == nil }
        #expect(flash.value == nil)
    }

    @Test func loggingTheSameOptionAgainRestartsTheInterval() async {
        let sleeper = Sleeper()
        let flash = ConfirmFlash(sleep: { try await sleeper.sleep($0) })
        flash.confirm("mild")
        await sleeper.waitFor(requested: 1, asleep: 1)
        flash.confirm("mild")
        // The first timer is cancelled; only the restarted one is pending.
        await sleeper.waitFor(requested: 2, asleep: 1)
        #expect(flash.value == "mild")
        #expect(flash.generation == 2)
        await sleeper.wakeAll()
        await waitUntil { flash.value == nil }
        #expect(flash.value == nil)
    }

    @Test func aNewerConfirmationIsNotClearedByAnOlderTimer() async {
        let sleeper = Sleeper()
        let flash = ConfirmFlash(sleep: { try await sleeper.sleep($0) })
        flash.confirm("mild")
        await sleeper.waitFor(requested: 1, asleep: 1)
        flash.confirm("severe")
        await sleeper.waitFor(requested: 2, asleep: 1)
        #expect(flash.value == "severe")
        await sleeper.wakeAll()
        await waitUntil { flash.value == nil }
        #expect(flash.value == nil)
    }

    @Test func aStaleTimerThatOutlivesCancellationDoesNotClear() async {
        // `try?` swallows the cancellation, so the first timer runs on while the second sleeps.
        let sleeper = Sleeper()
        let flash = ConfirmFlash(sleep: { try? await sleeper.sleep($0) })
        flash.confirm("mild")
        await sleeper.waitFor(requested: 1, asleep: 1)
        flash.confirm("severe")
        await sleeper.waitFor(requested: 2, asleep: 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(flash.value == "severe")
        await sleeper.wakeAll()
        await waitUntil { flash.value == nil }
        #expect(flash.value == nil)
    }
}
