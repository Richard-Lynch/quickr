import Foundation

/// A sleep the test releases by hand; a cancelled sleep throws like `Task.sleep`.
actor Sleeper {
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

@MainActor func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
}
