import Foundation
import QuickrCore
import Testing

@testable import QuickrData

/// timers2.md §9.1, R17: `RunAlertPlan.requests(run:timer:now:)`.
@Suite(.timeLimit(.minutes(1))) struct RunAlertPlanTests {
    typealias K = RunAlertKit

    private func fireMs(_ requests: [LocalNotificationRequest]) -> [Int] {
        requests.map { Int(($0.fireAt!.timeIntervalSince1970 * 1000).rounded()) }
    }

    @Test("a 60 s rest lap with t/2 and t: two requests at +30 s and +60 s from the lap's start")
    func restLap() throws {
        let run = try K.resting()
        #expect(run.state.open?.label == "Rest 1")
        let plan = K.plan(run, now: 12)
        #expect(fireMs(plan) == [K.at(40), K.at(70)])
        #expect(plan.map(\.id) == ["quickr.alert.\(K.runId).1.half", "quickr.alert.\(K.runId).1.go"])
        #expect(plan.map(\.body) == ["Half way · Rest 1", "Go · Rest 1"])
        #expect(plan.allSatisfy { $0.title == "Intervals" })
        #expect(plan.allSatisfy { $0.threadIdentifier == "topic-\(K.topicId.wireString)" })
        #expect(plan.allSatisfy { $0.sound })
        #expect(plan.allSatisfy { $0.fireDate == nil }, "an interval trigger, not a calendar one")
        #expect(plan.allSatisfy { $0.categoryIdentifier == nil })
        let info = try #require(plan.first?.quickr)
        #expect(info.kind == "alert")
        #expect(info.origin == .local)
        #expect(info.serverId == K.serverId)
        #expect(info.topicId == K.topicId.wireString)
        #expect(info.runId == K.runId)
        #expect(info.alertLabel == "Half way")
        #expect(info.fireAtMs == K.at(40))
        #expect(info.serverFireAtMs == K.at(40))
    }

    @Test("the interruption level is the one constant RunAlerts holds (OQ-6: time-sensitive)")
    func timeSensitive() throws {
        let plan = K.plan(try K.resting(), now: 12)
        #expect(RunAlerts.interruptionLevel == .timeSensitive)
        #expect(!plan.isEmpty)
        #expect(plan.allSatisfy { $0.interruptionLevel == RunAlerts.interruptionLevel })
    }

    @Test("a 10 s pause in the segment shifts both alerts by 10 s")
    func pauseShifts() throws {
        let run = try K.resting([K.pause("p1", 15), K.resume("r1", 25, pause: "p1")])
        #expect(fireMs(K.plan(run, now: 26)) == [K.at(50), K.at(80)])
        // Stable while time passes: the same plan a second later.
        #expect(fireMs(K.plan(run, now: 27)) == [K.at(50), K.at(80)])
    }

    @Test("a pause before the segment started doesn't shift its alerts")
    func earlierPauseDoesNotShift() throws {
        let run = try K.run([K.pause("p1", 2), K.resume("r1", 5, pause: "p1"), K.lap("l1", 10, seg: 0)])
        #expect(fireMs(K.plan(run, now: 12)) == [K.at(40), K.at(70)])
    }

    @Test("while paused the plan is empty")
    func pausedIsEmpty() throws {
        let run = try K.resting([K.pause("p1", 15)])
        #expect(run.state.pausedSince != nil)
        #expect(K.plan(run, now: 16).isEmpty)
        #expect(K.plan(run, now: 100).isEmpty)
    }

    @Test("an instant already past is not planned; an alert exactly now has fired")
    func pastInstants() throws {
        let run = try K.resting()
        #expect(fireMs(K.plan(run, now: 45)) == [K.at(70)])
        #expect(fireMs(K.plan(run, now: 40)) == [K.at(70)])
        #expect(K.plan(run, now: 70).isEmpty)
    }

    @Test("a segment without alerts plans nothing; the lap moves the plan to the new segment")
    func lapMovesSegment() throws {
        let running = try K.run([])
        #expect(running.state.open?.label == "Run 1")
        #expect(K.plan(running, now: 5).isEmpty)
        let rest2 = try K.run([K.lap("l1", 10, seg: 0), K.lap("l2", 20, seg: 1), K.lap("l3", 30, seg: 2)])
        #expect(rest2.state.open?.label == "Rest 2")
        let plan = K.plan(rest2, now: 31)
        #expect(plan.map(\.id) == ["quickr.alert.\(K.runId).3.half", "quickr.alert.\(K.runId).3.go"])
        #expect(fireMs(plan) == [K.at(60), K.at(90)])
        #expect(plan.first?.body == "Half way · Rest 2")
    }

    @Test("stopped, discarded or finishing: none")
    func closedIsEmpty() throws {
        #expect(K.plan(try K.resting([K.stop(15)]), now: 16).isEmpty)
        #expect(K.plan(try K.resting([K.discard(15)]), now: 16).isEmpty)
        var finishing = try K.resting()
        finishing.status = .finishing
        #expect(K.plan(finishing, now: 12).isEmpty)
    }

    @Test("at most the next 8, earliest first then by position")
    func capEight() throws {
        let alerts =
            (0..<12).map { K.alert("a\($0)", "A\($0)", "\(12 - $0)s", (12 - $0) * 1_000) }
            + [K.alert("tie", "Tie", "1s", 1_000)]
        let timer = TopicTimer(steps: [], laps: [TopicTimer.LapType(key: "only", label: "Lap", alerts: alerts)])
        let run = try K.run([], timer: timer)
        let plan = K.plan(run, now: 0.5, timer: timer)
        #expect(plan.count == RunAlertPlan.maxPerRun)
        #expect(RunAlertPlan.maxPerRun == 8)
        #expect(plan.map { $0.quickr!.alertLabel! } == ["A11", "Tie", "A10", "A9", "A8", "A7", "A6", "A5"])
    }

    @Test("an alert the server hasn't evaluated (at_ms nil) is left out")
    func unevaluated() throws {
        let timer = TopicTimer(
            steps: [],
            laps: [
                TopicTimer.LapType(
                    key: "rest", label: "Rest",
                    alerts: [K.alert("draft", "Draft", "t", nil), K.alert("go", "Go", "30s", 30_000)])
            ])
        let plan = K.plan(try K.run([], timer: timer), now: 1, timer: timer)
        #expect(plan.map { $0.quickr!.alertLabel! } == ["Go"])
    }

    @Test("a step's alerts (OQ-4) use the step's key and label")
    func stepAlerts() throws {
        let timer = TopicTimer(
            steps: [
                TopicTimer.Step(key: "shower", label: "Shower", alerts: [K.alert("half", "Half way", "30s", 30_000)])
            ])
        let plan = K.plan(try K.run([], timer: timer), now: 1, timer: timer)
        #expect(plan.map(\.id) == ["quickr.alert.\(K.runId).0.half"])
        #expect(plan.first?.body == "Half way · Shower")
    }

    @Test("run instants are on the server clock, fireAt on this device's")
    func serverOffset() throws {
        let run = try K.resting()
        // The server is 5 s ahead: the device fires 5 s earlier by its own clock.
        let plan = K.plan(run, now: 12, offsetMs: 5_000)
        #expect(fireMs(plan) == [K.at(40) - 5_000, K.at(70) - 5_000])
        #expect(plan.first?.quickr?.fireAtMs == K.at(40) - 5_000)
        #expect(plan.first?.quickr?.serverFireAtMs == K.at(40))
        // An alert past on the server clock is past here too.
        #expect(fireMs(K.plan(run, now: 45, offsetMs: 5_000)) == [K.at(70) - 5_000])
    }

    @Test("identifiers use the lowercase run id")
    func lowercaseRunId() throws {
        let upper = K.runId.uppercased()
        let plan = K.plan(try K.run([K.lap("l1", 10, seg: 0)], id: upper), now: 12)
        #expect(plan.first?.id == "quickr.alert.\(K.runId).1.half")
        #expect(plan.first?.quickr?.runId == K.runId)
        #expect(RunAlerts.identifierPrefix(runId: upper) == "quickr.alert.\(K.runId).")
    }
}
