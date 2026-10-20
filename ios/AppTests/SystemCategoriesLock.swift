/// The system's notification category set is one per process, and `setNotificationCategories`
/// replaces all of it. Swift Testing runs suites in parallel (`.serialized` orders a suite's own
/// tests only), so a test that registers with or reads the real center holds this lock for its
/// whole body. Every other app test builds its environment with `categoryCenter: nil`.
actor SystemCategoriesLock {
    static let shared = SystemCategoriesLock()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
