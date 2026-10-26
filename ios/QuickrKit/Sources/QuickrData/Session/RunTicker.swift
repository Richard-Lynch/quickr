import Foundation
import Observation
import QuickrCore

/// The one clock behind every running timer on screen (timers.md §11.1): the tiles, the run
/// screen and its step list read `serverNow` from here, and nothing else keeps a timer of its
/// own. It ticks on each whole second of the server's clock (so a displayed `m:ss`, truncated,
/// turns over on time), and only while some view showing a running clock holds it
/// (`retain`/`release`); with none, no task runs.
///
/// `serverNow` is the device clock plus the store's server offset (`sync_state.server_offset_ms`,
/// §5.1), the clock run events are stamped on.
@MainActor @Observable
public final class RunTicker {
    /// The device clock at the last tick, epoch milliseconds.
    public private(set) var deviceNow: Int
    /// The bound store's server offset.
    public var offsetMs = 0
    /// Now on the server's clock, epoch milliseconds, as of the last tick.
    public var serverNow: Int { deviceNow + offsetMs }

    /// Views holding the ticker.
    public private(set) var holders = 0
    /// The tick loop is running.
    public var isTicking: Bool { task != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let clock: @Sendable () -> Int
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        clock: @escaping @Sendable () -> Int = { RunInstant.milliseconds(Date()) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.clock = clock
        self.sleep = sleep
        deviceNow = clock()
    }

    /// A view showing a running clock appeared: ticks start with the first holder.
    public func retain() {
        holders += 1
        deviceNow = clock()
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    /// That view went: the ticks stop with the last holder.
    public func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        task?.cancel()
        task = nil
    }

    /// Reads the clock now (the app came back to the foreground).
    public func refresh() { deviceNow = clock() }

    private func loop() async {
        while !Task.isCancelled {
            let now = clock() + offsetMs
            let wait = 1000 - ((now % 1000) + 1000) % 1000
            do { try await sleep(.milliseconds(wait)) } catch { return }
            guard !Task.isCancelled else { return }
            deviceNow = clock()
        }
    }

    /// Follows the bound store's server offset until cancelled (the root's `.task(id: binding)`).
    public func observe(_ session: AppSession) async {
        guard let store = session.store else {
            offsetMs = 0
            return
        }
        do {
            for try await state in store.observeSyncState(refresh: session.refresh.stream()) {
                offsetMs = state?.serverOffsetMs ?? 0
            }
        } catch {
            // the store closed: the next binding observes again
        }
    }
}
