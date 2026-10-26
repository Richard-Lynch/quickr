import Foundation
import QuickrCore
import Testing

/// The helper half of R12 (timers.md §5.1, §13.3): the server-time offset and the per-run clamp,
/// the same cases as the PWA's `clock.test.ts`.
@Suite struct RunClockTests {
    @Test func readsTheServerTimeHeader() {
        #expect(RunClock.serverTimeHeader == "X-QuickR-Server-Time")
        #expect(RunClock.parseServerTime("1792742400123") == 1_792_742_400_123)
        #expect(RunClock.parseServerTime(" 1792742400123 ") == 1_792_742_400_123)
        for value in [nil, "", "abc", "1792742400.5", "-5", "1e12", "99999999999999999999"] as [String?] {
            #expect(RunClock.parseServerTime(value) == nil, "\(value ?? "nil")")
        }
    }

    @Test func offsetIsServerTimeMinusTheRoundTripMidpoint() {
        #expect(RunClock.initialOffsetMs == 0)
        // Sent at 1000, received at 1200: the server's 5100 is taken as device 1100.
        #expect(RunClock.offsetSample(serverTime: 5100, sent: 1000, received: 1200) == 4000)
        // A device clock ahead of the server gives a negative offset.
        #expect(RunClock.offsetSample(serverTime: 1000, sent: 5000, received: 5400) == -4200)
        // A half-millisecond midpoint is floored to a whole millisecond, negative ones too.
        #expect(RunClock.offsetSample(serverTime: 5100, sent: 1000, received: 1201) == 3999)
        #expect(RunClock.offsetSample(serverTime: 1000, sent: 5000, received: 5401) == -4201)
    }

    @Test func takesARoundTripOfExactlyFiveSecondsOnly() {
        let max = RunClock.maxSampleRoundTripMs
        #expect(max == 5000)
        #expect(RunClock.offsetSample(serverTime: 10_000, sent: 0, received: max) == 7500)
        #expect(RunClock.offsetSample(serverTime: 10_000, sent: 0, received: max + 1) == nil)
        #expect(RunClock.offsetSample(serverTime: 10_000, sent: 100, received: 99) == nil)
    }

    @Test func offsetComesFromTheLatestQualifyingResponse() {
        var offset = RunClock.initialOffsetMs
        offset = RunClock.nextOffset(current: offset, serverTime: 5100, sent: 1000, received: 1200)
        #expect(offset == 4000)
        offset = RunClock.nextOffset(current: offset, serverTime: 9000, sent: 2000, received: 2000)
        #expect(offset == 7000)
        // A slow response, or one without the header, keeps the last offset.
        offset = RunClock.nextOffset(
            current: offset, serverTime: 0, sent: 3000, received: 3000 + RunClock.maxSampleRoundTripMs + 1)
        #expect(offset == 7000)
        offset = RunClock.nextOffset(current: offset, serverTime: nil, sent: 4000, received: 4010)
        #expect(offset == 7000)
    }

    @Test func stampIsDeviceNowPlusTheOffset() {
        #expect(RunClock.serverNow(deviceNow: 1000, offset: 250) == 1250)
        #expect(RunClock.serverNow(deviceNow: 1000, offset: -250) == 750)
        #expect(RunClock.stamp(deviceNow: Date(timeIntervalSince1970: 1.0009), offset: 0, runAts: []) == 1000)
    }

    @Test func offlineStampingUsesTheLastOffset() {
        let offset = RunClock.nextOffset(
            current: RunClock.initialOffsetMs, serverTime: 5100, sent: 1000, received: 1200)
        #expect(RunClock.stamp(deviceNow: 60_000, offset: offset, runAts: []) == 64_000)
        #expect(RunClock.stamp(deviceNow: 120_000, offset: offset, runAts: [64_000]) == 124_000)
    }

    @Test func stampIsClampedToJustAfterTheRunsLatestAt() {
        // The offset dropped (or the device clock jumped back) after the last event.
        #expect(RunClock.stamp(deviceNow: 10_000, offset: 0, runAts: [12_000, 11_000]) == 12_001)
        // Equal to the latest is moved 1 ms on; later is left alone.
        #expect(RunClock.stamp(deviceNow: 12_000, offset: 0, runAts: [12_000]) == 12_001)
        #expect(RunClock.stamp(deviceNow: 12_001, offset: 0, runAts: [12_000]) == 12_001)
        #expect(RunClock.stamp(deviceNow: 13_000, offset: 0, runAts: [12_000]) == 13_000)
        #expect(RunClock.clamp(7, after: nil) == 7)
        #expect(RunClock.clamp(7, after: 9) == 10)
        #expect(RunClock.clamp(9, after: 9) == 10)
    }

    /// Two Nexts in the same millisecond; the second's id sorts first. Clamped only to equal, the
    /// fold would apply the second (seg 1) first, void it as stale, then apply the first.
    @Test func clampKeepsOneDevicesTapsInOrderThroughTheFold() throws {
        let run = "0a000000-0000-4000-8000-000000000000"
        let steps = [("a", "A"), ("b", "B"), ("c", "C")].map { TopicTimer.Step(key: $0, label: $1) }
        let start = RunEvent(id: run, type: .start, at: 1000)
        var first = RunEvent(id: "ffffffff-0000-4000-8000-000000000001", type: .next, at: 0, seg: 0)
        first.at = RunClock.stamp(deviceNow: 5000, offset: 0, runAts: [start.at])
        var second = RunEvent(id: "00000000-0000-4000-8000-000000000002", type: .next, at: 0, seg: 1)
        second.at = RunClock.stamp(deviceNow: 5000, offset: 0, runAts: [start.at, first.at])
        #expect(second.at == first.at + 1)
        let state = try RunFold.fold(runId: run, steps: steps, events: [start, first, second])
        #expect(state.effects.values.allSatisfy { $0 == .applied })
        #expect(state.open?.step == "c")

        // Without the clamp, the same instant reorders them.
        second.at = first.at
        let unclamped = try RunFold.fold(runId: run, steps: steps, events: [start, first, second])
        #expect(unclamped.effects[second.id] == .void(.stale))
    }
}
