import QuickrUI
import Testing

@Suite struct ToastTests {
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
}

/// A sleep the test releases by hand; a cancelled sleep throws like `Task.sleep`.
private actor Sleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = requested.count
        requested.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Waits until `requested` sleeps have started and `asleep` of them are still pending.
    func waitFor(requested n: Int, asleep: Int) async {
        while requested.count < n || waiting.count != asleep { await Task.yield() }
    }

    func wakeAll() {
        let all = waiting.values
        waiting = [:]
        for c in all { c.resume() }
    }

    private func cancel(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
}
