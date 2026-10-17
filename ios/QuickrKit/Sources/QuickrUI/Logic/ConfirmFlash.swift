import Observation

/// The quick-log chip's confirmation: after a successful log the chip stays lit for
/// ``duration``. Every ``confirm(_:)`` starts a fresh interval, so logging the same option
/// again restarts it and a newer confirmation is never cleared by an older timer.
@MainActor @Observable
public final class ConfirmFlash {
    /// How long a tapped quick-log chip stays green (the Undo toast has the details).
    public static let duration: Duration = .milliseconds(1600)

    /// The option value currently lit, if any.
    public private(set) var value: String?
    /// Bumped on every confirmation; also a trigger for the "logged" haptic.
    public private(set) var generation = 0

    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// `sleep` is injectable so tests can run the timer without waiting.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func confirm(_ value: String) {
        generation += 1
        self.value = value
        timer?.cancel()
        let mine = generation
        let sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(Self.duration) } catch { return }
            guard let self, self.generation == mine else { return }
            self.value = nil
        }
    }
}
