import Foundation
import Testing

@testable import QuickrCore

/// active-surfaces.md §2.1, §2.4, §3.3: the run header's state badge ("Resuming…" first), the alert
/// line (a fired alert's label for its 10 s, else the countdown), the typed lap rows' badges and
/// an idle Resume's title.
@Suite struct RunHeaderTextTests {
    @Test("State badge: Resuming… while a reopen waits for its ack, else Paused or Running")
    func state() {
        #expect(RunHeaderText.state(resuming: true, paused: false) == "Resuming…")
        #expect(RunHeaderText.state(resuming: true, paused: true) == "Resuming…")
        #expect(RunHeaderText.state(resuming: false, paused: true) == "Paused")
        #expect(RunHeaderText.state(resuming: false, paused: false) == "Running")
    }

    @Test("Alert line: the fired label wins for its 10 s, then the countdown; nothing without either")
    func alert() {
        #expect(
            RunHeaderText.alert(fired: "Half way", next: "Cool down · in 0:12")
                == .init(text: "Half way", fired: true))
        #expect(
            RunHeaderText.alert(fired: nil, next: "Cool down · in 0:12")
                == .init(text: "Cool down · in 0:12", fired: false))
        #expect(RunHeaderText.alert(fired: "", next: "x · in 0:01")?.fired == false, "an empty label isn't shown")
        #expect(RunHeaderText.alert(fired: "Half way", next: nil)?.text == "Half way", "paused: no countdown")
        #expect(RunHeaderText.alert(fired: nil, next: nil) == nil)
    }

    @Test("Lap badges: each typed lap row (closed, then open) gets its type's label; untyped none")
    func lapBadges() {
        let timer = TopicTimer(
            steps: [],
            laps: [TopicTimer.LapType(key: "run", label: "Run"), TopicTimer.LapType(key: "rest", label: "Rest")])
        func lap(_ index: Int, _ type: String?) -> RunSegment {
            RunSegment(
                kind: .lap, step: nil, label: type ?? "Lap \(index + 1)", startedAt: index, endedAt: index + 1,
                activeMs: 1, pausedMs: 0, lapType: type)
        }
        let state = RunState(
            status: .running, startedAt: 0, endedAt: nil,
            open: RunOpenSegment(index: 3, kind: .lap, step: nil, label: "Rest 2", startedAt: 3, lapType: "rest"),
            nextStep: nil, pausedSince: nil, segments: [lap(0, "run"), lap(1, "rest"), lap(2, "gone")],
            skipped: [], pauses: [], effects: [:])
        #expect(
            RunHeaderText.lapTypeBadges(state, timer: timer)
                == ["lap.1": "Run", "lap.2": "Rest", "lap.3": "gone", "lap.4": "Rest"])
        #expect(RunHeaderText.lapTypeBadges(state, timer: nil).isEmpty, "the timer isn't known")
        var untyped = state
        untyped.segments = [lap(0, nil)]
        untyped.open = nil
        #expect(RunHeaderText.lapTypeBadges(untyped, timer: timer).isEmpty)
    }

    @Test("Idle Resume title: Resume · {total}")
    func reopenTitle() {
        #expect(RunHeaderText.reopenTitle(totalMs: 104_000) == "Resume · 1:44")
        #expect(RunHeaderText.reopenTitle(totalMs: 3_725_000) == "Resume · 1:02:05")
    }
}
