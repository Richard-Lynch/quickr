import QuickrUI
import Testing

@Suite(.timeLimit(.minutes(2))) struct ToastTests {
    @Test func durations() {
        #expect(Toast("Logged", action: .init("Undo") {}).duration == .seconds(6))
        #expect(Toast("Copied").duration == .milliseconds(3500))
        #expect(Toast("Custom", duration: .seconds(2)).duration == .seconds(2))
        #expect(Toast("Sticky", duration: .zero).duration == nil)
    }

    @Test func stackKeepsTheNewestThree() {
        var stack = ToastStack()
        let ids = (1...4).map { stack.push(Toast("t\($0)")) }
        #expect(stack.items.map(\.id) == Array(ids.suffix(3)))
        #expect(stack.items.map(\.toast.title) == ["t2", "t3", "t4"])
        stack.dismiss(ids[2])
        #expect(stack.items.map(\.toast.title) == ["t2", "t4"])
    }

    @MainActor @Test func centerDismissesEachToastAfterItsDuration() async {
        let sleeper = Sleeper()
        let center = ToastCenter(sleep: { try await sleeper.sleep($0) })
        center.show(Toast("Logged", action: .init("Undo") {}))
        center.show(Toast("Copied"))
        center.show(Toast("Sticky", duration: .zero))
        #expect(center.items.count == 3)

        await sleeper.waitFor(requested: 2, asleep: 2)
        #expect(await sleeper.requested == [.seconds(6), .milliseconds(3500)])
        await sleeper.wakeAll()
        await waitUntil { center.items.count == 1 }
        #expect(center.items.map(\.toast.title) == ["Sticky"])
    }

    @MainActor @Test func actionRunsOnceAndDismisses() async {
        var undone = 0
        let center = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let id = center.show(Toast("Logged", action: .init("Undo") { undone += 1 }))
        center.performAction(id)
        center.performAction(id)
        #expect(undone == 1)
        #expect(center.items.isEmpty)
    }

    @MainActor @Test func pushedOutToastsLoseTheirTimers() async {
        let sleeper = Sleeper()
        let center = ToastCenter(sleep: { try await sleeper.sleep($0) })
        for n in 1...4 { center.show(Toast("t\(n)")) }
        #expect(center.items.map(\.toast.title) == ["t2", "t3", "t4"])
        // The first toast's timer was cancelled when it was pushed out.
        await sleeper.waitFor(requested: 4, asleep: 3)
        await sleeper.wakeAll()
        await waitUntil { center.items.isEmpty }
        #expect(center.items.isEmpty)
    }

    @Test func underVoiceOverActionAndErrorToastsStay() {
        #expect(Toast("Logged", action: .init("Undo") {}).durationUnderVoiceOver == nil)
        #expect(Toast("Couldn’t log", tone: .danger).durationUnderVoiceOver == nil)
        #expect(Toast("Copied").durationUnderVoiceOver == .milliseconds(3500))
        #expect(Toast("Custom", duration: .seconds(2)).durationUnderVoiceOver == .seconds(2))
    }

    @Test func announcementSaysTheMessageAndHowToUndo() {
        #expect(Toast("Copied").announcement == "Copied.")
        #expect(
            Toast("Logged Mild", message: "Headache", action: .init("Undo") {}).announcement
                == "Logged Mild. Headache. Undo available: double-tap with two fingers.")
    }

    @MainActor @Test func withVoiceOverOnlyPlainToastsAreTimed() async {
        let sleeper = Sleeper()
        let center = ToastCenter(sleep: { try await sleeper.sleep($0) }, voiceOverRunning: { true })
        center.show(Toast("Logged", action: .init("Undo") {}))
        center.show(Toast("Couldn’t log", tone: .danger))
        center.show(Toast("Copied"))
        await sleeper.waitFor(requested: 1, asleep: 1)
        #expect(await sleeper.requested == [.milliseconds(3500)])
        await sleeper.wakeAll()
        await waitUntil { center.items.count == 2 }
        #expect(center.items.map(\.toast.title) == ["Logged", "Couldn’t log"])
    }

    @MainActor @Test func turningVoiceOverOnHoldsAndTurningItOffRestartsTheTimers() async {
        let sleeper = Sleeper()
        var voiceOver = false
        let center = ToastCenter(sleep: { try await sleeper.sleep($0) }, voiceOverRunning: { voiceOver })
        center.show(Toast("Logged", action: .init("Undo") {}))
        await sleeper.waitFor(requested: 1, asleep: 1)

        voiceOver = true
        center.voiceOverStatusChanged()  // the 6 s timer is cancelled and not replaced
        await sleeper.waitFor(requested: 1, asleep: 0)
        #expect(center.items.count == 1)

        voiceOver = false
        center.voiceOverStatusChanged()  // a fresh 6 s
        await sleeper.waitFor(requested: 2, asleep: 1)
        #expect(await sleeper.requested == [.seconds(6), .seconds(6)])
        await sleeper.wakeAll()
        await waitUntil { center.items.isEmpty }
    }

    @MainActor @Test func theMagicTapRunsTheNewestAction() {
        var undone: [String] = []
        let center = ToastCenter(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        #expect(!center.performNewestAction(), "nothing to run")
        center.show(Toast("Logged A", action: .init("Undo") { undone.append("A") }))
        center.show(Toast("Logged B", action: .init("Undo") { undone.append("B") }))
        center.show(Toast("Copied"))
        #expect(center.performNewestAction())
        #expect(undone == ["B"])
        #expect(center.items.map(\.toast.title) == ["Logged A", "Copied"])
        #expect(center.performNewestAction())
        #expect(!center.performNewestAction())
        #expect(undone == ["B", "A"])
    }
}
