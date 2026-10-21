#if DEBUG
import Foundation
import QuickrCore
import Synchronization
import os

/// Checkpoint D's category probe (docs/ios/demo/DEVICE-DAY.md D8 and D9; notifications.md §5.4
/// and D1). DEBUG builds only: Release compiles none of it (`make ios-release-test-build` builds
/// Release with the tests).
///
/// It runs only on request. The app, launched with `-QuickrDProbe d8|d9`, writes a request into
/// the App Group (`Files.write`); the NSE takes it (`Files.take`) on the next `test` push ("Test
/// this device"). A request expires after 3 minutes and belongs to one run (`current-run`), so a
/// later ordinary test push can't start a stale probe, and a runner of an older run stops.
///
/// - **D8** (§5.4): `rounds` times, both processes meet at an agreed instant and register at once,
///   the NSE {A, B} and the app {A, C}, through §5.2's `register` (so the registry's lock still
///   orders them). Each round starts from an empty probe table, so every set the system gets is
///   that round's alone. The app then reads `notificationCategories()` and checks A, B and C are
///   there, at once or after one `reconcile()`. Each round records whether the two attempts
///   overlapped in time.
/// - **D9** (D1): each process registers 100, 1,000 and 5,000 synthetic categories and records
///   the `setNotificationCategories` call alone (`set_ms`), the whole `register` (`register_ms`:
///   the registry insert too) and the time until `notificationCategories()` reflects it
///   (`readback_ms`). The app runs its side first and writes the request only when it's done.
///
/// The probe registers through registries of its own (`dprobe/registry-*`), never the real one.
/// D9 registers uncapped (`cap: nil`): it measures the system's own limit, which §5.2's cap stays
/// under. While it runs, the system's set is the probe's; each side re-registers the real
/// table's selection when it finishes (`restore`, outside any cancellation), and the
/// app's next activation reconciles it anyway (§5.3) if a process dies first. Every event is one
/// JSON line appended to `dprobe/results.jsonl`; `ios/scripts/dprobe-summary.py` judges a run.
public enum DeviceProbe {
    public enum Kind: String, Codable, Sendable { case d8, d9 }
    public enum Process: String, Codable, Sendable { case app, nse }

    /// How long a request waits for its test push.
    public static let requestLifetime: TimeInterval = 180

    public struct Request: Codable, Sendable, Hashable {
        public var kind: Kind
        /// Tags every record and file of this run.
        public var run: String
        public var rounds: Int
        public var sizes: [Int]
        /// Unix seconds after which the NSE ignores it.
        public var expires: Double

        public init(
            kind: Kind, run: String = String(UUID().uuidString.prefix(8)), rounds: Int = 100,
            sizes: [Int] = [100, 150, 1000, 5000], expires: Date = Date().addingTimeInterval(requestLifetime)
        ) {
            self.kind = kind
            self.run = run
            self.rounds = rounds
            self.sizes = sizes
            self.expires = expires.timeIntervalSince1970
        }
    }

    /// One line of `results.jsonl`.
    public struct Record: Codable, Sendable, Hashable {
        public var run: String
        public var process: Process
        public var probe: Kind
        /// `start`, `ready`, `round`, `size`, `timeout`, `stopped`, `error` or `done`.
        public var event: String
        public var round: Int?
        /// `start`: the number of rounds (D8) or the sizes (D9) the run asks for.
        public var rounds: Int?
        public var sizes: [Int]?
        public var size: Int?
        /// The center's `setNotificationCategories` alone: building the `UNNotificationCategory` set
        /// and the system call, without the registry's work.
        public var setMs: Double?
        /// The whole `register`: the registry transaction, the selection and the call.
        public var registerMs: Double?
        public var readbackMs: Double?
        public var ok: Bool?
        /// D8: the ids missing at the first read, before any reconcile.
        public var missing: [String]?
        /// D8: whether a reconcile ran (because something was missing).
        public var reconciled: Bool?
        /// D8: whether the app's and the NSE's attempts overlapped in time.
        public var overlap: Bool?
        /// The step finished after the NSE's deadline.
        public var overrun: Bool?
        /// D9: how many of the size's categories the last readback held (all of them when `ok`).
        public var seen: Int?
        public var note: String?
        public var at: Double

        public init(
            run: String, process: Process, probe: Kind, event: String, round: Int? = nil, rounds: Int? = nil,
            sizes: [Int]? = nil, size: Int? = nil, setMs: Double? = nil, registerMs: Double? = nil,
            readbackMs: Double? = nil,
            ok: Bool? = nil, missing: [String]? = nil, reconciled: Bool? = nil, overlap: Bool? = nil,
            overrun: Bool? = nil, seen: Int? = nil, note: String? = nil, at: Date = Date()
        ) {
            self.run = run
            self.process = process
            self.probe = probe
            self.event = event
            self.round = round
            self.rounds = rounds
            self.sizes = sizes
            self.size = size
            self.setMs = setMs
            self.registerMs = registerMs
            self.readbackMs = readbackMs
            self.ok = ok
            self.missing = missing
            self.reconciled = reconciled
            self.overlap = overlap
            self.overrun = overrun
            self.seen = seen
            self.note = note
            self.at = at.timeIntervalSince1970
        }

        enum CodingKeys: String, CodingKey {
            case run, process, probe, event, round, rounds, sizes, size, ok, missing, reconciled, overlap, overrun,
                seen, note,
                at
            case setMs = "set_ms"
            case registerMs = "register_ms"
            case readbackMs = "readback_ms"
        }
    }

    // MARK: - Synthetic categories

    /// The server id of every probe category, so none can be mistaken for a real one.
    public static let serverId = "dprobe"

    /// The probe's categories: a 4-option enum topic each (4 visible actions), like a real one.
    public static func row(topic: String) -> NotificationCategories.Row {
        let options = (1...4).map { QuickLogDescriptor.Choice.Option(value: "o\($0)", label: "Option \($0)") }
        let descriptor = QuickLogDescriptor.choice(.init(key: "k", label: "Probe", options: options, totalOptions: 4))
        return NotificationCategories.Row(
            serverId: serverId, topicId: topic,
            category: NotificationCategory(serverId: serverId, topicId: topic, version: 1, descriptor: descriptor))
    }

    /// D9: `size` distinct categories for one process.
    public static func rows(size: Int, process: Process) -> [NotificationCategories.Row] {
        (0..<size).map { row(topic: "d9-\(process.rawValue)-\(size)-\($0)") }
    }

    /// D8: round `round`'s {A, B} (the NSE) or {A, C} (the app).
    public static func d8Rows(round: Int, process: Process) -> [NotificationCategories.Row] {
        [row(topic: "d8-\(round)-a"), row(topic: "d8-\(round)-\(process == .nse ? "b" : "c")")]
    }

    /// D8: the ids round `round` must leave registered: A, B and C.
    public static func d8Expected(round: Int) -> Set<String> {
        Set((d8Rows(round: round, process: .nse) + d8Rows(round: round, process: .app)).map(\.category.id))
    }

    /// The ids of `expected` that `registered` lacks, sorted.
    public static func missing(_ expected: Set<String>, in registered: [NotificationCategorySpec]) -> [String] {
        expected.subtracting(registered.map(\.id)).sorted()
    }

    /// Re-registers the real registry's table (the probe replaced the system's set). Whether it did.
    public static func restore(location: StoreLocation, center: any NotificationCenterProtocol) async -> Bool {
        guard let registry = try? Registry.open(at: location, notifier: nil) else { return false }
        return (try? await NotificationCategories(registry: registry, center: center).register([])) != nil
    }

    /// Whether two attempts (uptime ns) overlapped in time.
    public static func overlapped(_ a: ClosedRange<UInt64>, _ b: ClosedRange<UInt64>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }

    /// Nanoseconds since boot, the same in every process (rendezvous and attempt times).
    public static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func milliseconds(_ nanoseconds: UInt64) -> Double { (Double(nanoseconds) / 1e3).rounded() / 1e3 }

    static func nanoseconds(_ duration: Duration) -> UInt64 {
        UInt64(duration.components.seconds) * 1_000_000_000 + UInt64(duration.components.attoseconds / 1_000_000_000)
    }

    static let log = Logger(subsystem: "com.bahumia.quickr", category: "dprobe")

    /// A newer run claimed the probe: this run stops without touching the system's set again.
    public struct Superseded: Error, CustomStringConvertible {
        public var description: String { "a newer run started" }
    }

    /// The NSE's deadline passed while a step waited for the lock.
    public struct OutOfTime: Error, CustomStringConvertible {
        public var description: String { "out of time waiting for the probe's lock" }
    }

    // MARK: - Files

    /// The probe's files, under `<App Group>/Library/quickr/dprobe/`.
    public struct Files: Sendable {
        public let root: URL

        public init(location: StoreLocation) {
            root = location.root.appending(path: "dprobe", directoryHint: .isDirectory)
        }

        public var request: URL { root.appending(path: "request.json") }
        var taken: URL { root.appending(path: "request.taken.json") }
        var currentRun: URL { root.appending(path: "current-run") }
        public var results: URL { root.appending(path: "results.jsonl") }
        /// D8: the app's round and its rendezvous instant ("round uptime-ns"; −1 once done).
        func appRound(_ run: String) -> URL { root.appending(path: "d8-\(run)-app") }
        /// D8: the NSE's last finished round and its attempt ("round start-ns end-ns").
        func nseRound(_ run: String) -> URL { root.appending(path: "d8-\(run)-nse") }

        func registry(_ name: String) -> StoreLocation {
            StoreLocation(root: root.appending(path: "registry-\(name)", directoryHint: .isDirectory))
        }

        /// Makes `pending`'s run the current one and leaves it for the NSE's next test push.
        public func write(_ pending: Request) throws {
            try claim(pending.run)
            try? FileManager.default.removeItem(at: taken)
            try JSONEncoder().encode(pending).write(to: request, options: .atomic)
        }

        /// Makes `run` the current one: a runner of any other run stops at its next step.
        public func claim(_ run: String) throws {
            try exclusivelyNow { try Data(run.utf8).write(to: currentRun, options: .atomic) }
        }

        var lock: URL { root.appending(path: "run.lock") }

        /// Runs `body` holding the probe's cross-process lock (`flock` on `run.lock`). Claims,
        /// cancellations, takes and every change a run makes to the system's set take it, so a
        /// newer claim can't land between a run's ownership check and its change. This variant
        /// waits by blocking, for the synchronous callers (a claim, a take, a cancellation), which
        /// never run while an asynchronous holder in the same process does.
        func exclusivelyNow<T>(_ body: () throws -> T) throws -> T {
            let fd = try openLock()
            while flock(fd, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    Darwin.close(fd)
                    throw CocoaError(.fileLocking)
                }
            }
            defer { unlock(fd) }
            return try body()
        }

        /// The same lock for an asynchronous holder: it waits by polling, never blocking a thread
        /// of the cooperative pool (the other side may be in this process, as in tests), and gives
        /// up with `OutOfTime` at `deadline` (uptime ns).
        func exclusively<T>(until deadline: UInt64? = nil, _ body: () async throws -> T) async throws -> T {
            let fd = try openLock()
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    Darwin.close(fd)
                    throw CocoaError(.fileLocking)
                }
                if let deadline, DeviceProbe.uptime() >= deadline {
                    Darwin.close(fd)
                    throw DeviceProbe.OutOfTime()
                }
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    Darwin.close(fd)
                    throw error
                }
            }
            defer { unlock(fd) }
            return try await body()
        }

        private func openLock() throws -> Int32 {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fd = Darwin.open(lock.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            return fd
        }

        private func unlock(_ fd: Int32) {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }

        /// The current run, if any.
        func currentRunId() -> String? { try? String(contentsOf: currentRun, encoding: .utf8) }

        /// Runs `body` under the lock unless another run than `run` is current (the app's own
        /// re-registration when its hold ends, which must not overwrite a newer probe's set).
        public func unlessAnotherRun(_ run: String, _ body: () async -> Void) async {
            do {
                try await exclusively {
                    guard currentRunId().map({ $0 == run }) ?? true else { return }
                    await body()
                }
            } catch {
                // Without the lock, re-registering the real table still beats leaving it missing.
                DeviceProbe.log.error(
                    "dprobe: no lock (\(String(describing: error), privacy: .public)); re-registering anyway")
                await body()
            }
        }

        /// The pending request, taken (renamed) so a second push doesn't run it again; nil when
        /// there is none, it has expired, or a newer run has started since.
        public func take(now: Date = Date()) -> Request? {
            try? exclusivelyNow {
                guard (try? FileManager.default.moveItem(at: request, to: taken)) != nil,
                    let data = try? Data(contentsOf: taken),
                    let pending = try? JSONDecoder().decode(Request.self, from: data),
                    pending.expires > now.timeIntervalSince1970, isCurrent(pending.run)
                else { return nil }
                return pending
            } ?? nil
        }

        /// An ordinary launch: no run is current any more, and any pending request is dropped, so
        /// neither a later test push nor a runner still going acts on an abandoned probe.
        public func cancelPending() {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            let remove = { for url in [request, currentRun] { try? FileManager.default.removeItem(at: url) } }
            do {
                try exclusivelyNow(remove)
            } catch {
                DeviceProbe.log.error(
                    "dprobe: no lock (\(String(describing: error), privacy: .public)); cancelling anyway")
                remove()
            }
        }

        public func isCurrent(_ run: String) -> Bool {
            (try? String(contentsOf: currentRun, encoding: .utf8)) == run
        }

        /// Appends one line with a single `O_APPEND` write, so lines from both processes never
        /// interleave. Whether the whole line was written; a failure is logged.
        @discardableResult
        public func append(_ record: Record) -> Bool {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var line = try? encoder.encode(record) else { return false }
            line.append(0x0A)
            let fd = Darwin.open(results.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else {
                DeviceProbe.log.error("dprobe: can't open the results file (errno \(errno))")
                return false
            }
            defer { Darwin.close(fd) }
            let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == line.count else {
                DeviceProbe.log.error("dprobe: wrote \(written) of \(line.count) bytes of a record (errno \(errno))")
                return false
            }
            return true
        }

        public func records() -> [Record] {
            guard let text = try? String(contentsOf: results, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                try? JSONDecoder().decode(Record.self, from: Data($0.utf8))
            }
        }

        func write(_ numbers: [Int64], to url: URL) {
            try? Data(numbers.map(String.init).joined(separator: " ").utf8).write(to: url, options: .atomic)
        }

        func read(_ url: URL) -> [Int64] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: " ").compactMap { Int64($0) }
        }
    }
}

/// A center that times each `setNotificationCategories` call (D9's `set_ms`).
final class TimingCenter: NotificationCenterProtocol {
    let inner: any NotificationCenterProtocol
    private let last = Mutex<UInt64?>(nil)

    init(_ inner: any NotificationCenterProtocol) { self.inner = inner }

    /// The last call's duration, taken (nil when there was none since).
    func takeLastNanoseconds() -> UInt64? {
        last.withLock { value in
            defer { value = nil }
            return value
        }
    }

    func setNotificationCategories(_ categories: [NotificationCategorySpec]) {
        let start = DeviceProbe.uptime()
        inner.setNotificationCategories(categories)
        let end = DeviceProbe.uptime()
        last.withLock { $0 = end - start }
    }

    func notificationCategories() async -> [NotificationCategorySpec] { await inner.notificationCategories() }
    func deliveredNotifications() async -> [NotificationSnapshot] { await inner.deliveredNotifications() }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        inner.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func pendingNotificationRequests() async -> [NotificationSnapshot] { await inner.pendingNotificationRequests() }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        inner.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func add(_ request: LocalNotificationRequest) async throws { try await inner.add(request) }
    func setBadgeCount(_ count: Int) async throws { try await inner.setBadgeCount(count) }
    func authorizationStatus() async -> NotificationAuthorization { await inner.authorizationStatus() }
    func requestAuthorization() async throws -> Bool { try await inner.requestAuthorization() }
}

/// One process's side of a probe run.
public struct DeviceProbeRunner: Sendable {
    public let files: DeviceProbe.Files
    public let process: DeviceProbe.Process
    public let center: any NotificationCenterProtocol
    /// Re-registers the real table when the run ends; whether it did (`DeviceProbe.restore`).
    public let restore: @Sendable () async -> Bool
    var poll: Duration = .milliseconds(2)
    /// How long a readback may take to show a registration before it counts as failed.
    var readbackLimit: Duration = .seconds(10)
    /// D8: how long the app waits for the NSE to finish a round, and for its first sign of life.
    var peerLimit: Duration = .seconds(5)
    var startLimit: Duration = .seconds(180)
    /// D8: how far ahead the app sets each round's rendezvous.
    var rendezvousLead: Duration = .milliseconds(30)

    public init(
        files: DeviceProbe.Files, process: DeviceProbe.Process, center: any NotificationCenterProtocol,
        restore: @escaping @Sendable () async -> Bool
    ) {
        self.files = files
        self.process = process
        self.center = center
        self.restore = restore
    }

    /// Runs this process's side of `request`, stopping at `deadline` (uptime ns: the NSE's
    /// budget) or when cancelled, then restores the real categories. The restore runs detached,
    /// so a cancellation (the NSE's time running out) can't skip it.
    public func run(_ request: DeviceProbe.Request, until deadline: UInt64? = nil) async {
        do {
            switch (request.kind, process) {
            case (.d9, _): try await d9(request, deadline: deadline)
            case (.d8, .app): try await d8App(request)
            case (.d8, .nse): try await d8NSE(request, deadline: deadline)
            }
        } catch is DeviceProbe.Superseded {
            record(request, "stopped", note: "a newer run started")
        } catch let error as DeviceProbe.OutOfTime {
            record(request, "timeout", note: error.description)
        } catch {
            record(request, "error", note: String(describing: error))
        }
        // Under the lock: a superseded run leaves the system's set to the newer one, which
        // restores when it ends. Detached as a whole, so a cancelled run (the NSE out of time)
        // still takes the lock and restores.
        let restore = restore
        let files = files
        let outcome = await Task.detached { () -> RestoreOutcome in
            do {
                return try await files.exclusively {
                    guard files.isCurrent(request.run) else { return .superseded }
                    return await restore() ? .restored : .failed
                }
            } catch {
                // Without the lock, restoring still beats leaving the real categories missing.
                return await restore() ? .restored : .failed
            }
        }.value
        switch outcome {
        case .restored: record(request, "done", ok: true)
        case .superseded:
            record(request, "done", ok: true, note: "superseded: the newer run restores the real categories")
        case .failed: record(request, "done", ok: false, note: "the real categories weren't restored")
        }
    }

    private enum RestoreOutcome: Sendable { case restored, superseded, failed }

    private func record(
        _ request: DeviceProbe.Request, _ event: String, round: Int? = nil, rounds: Int? = nil, sizes: [Int]? = nil,
        size: Int? = nil,
        setMs: Double? = nil, registerMs: Double? = nil, readbackMs: Double? = nil, ok: Bool? = nil,
        missing: [String]? = nil, reconciled: Bool? = nil, overlap: Bool? = nil, overrun: Bool? = nil,
        seen: Int? = nil, note: String? = nil
    ) {
        files.append(
            DeviceProbe.Record(
                run: request.run, process: process, probe: request.kind, event: event, round: round, rounds: rounds,
                sizes: sizes, size: size, setMs: setMs, registerMs: registerMs, readbackMs: readbackMs, ok: ok,
                missing: missing,
                reconciled: reconciled, overlap: overlap, overrun: overrun, seen: seen, note: note))
    }

    private func past(_ deadline: UInt64?, at instant: UInt64 = DeviceProbe.uptime()) -> Bool {
        deadline.map { instant >= $0 } == true
    }

    private func stopped(_ deadline: UInt64?) -> Bool { Task.isCancelled || past(deadline) }

    /// A registry of the probe's own, emptied first.
    private func freshRegistry(_ name: String) throws -> Registry {
        let location = files.registry(name)
        try? FileManager.default.removeItem(at: location.root)
        return try Registry.open(at: location, notifier: nil)
    }

    private func sleep(until instant: UInt64) async {
        let now = DeviceProbe.uptime()
        if instant > now { try? await Task.sleep(nanoseconds: instant - now) }
    }

    // MARK: D9

    private func d9(_ request: DeviceProbe.Request, deadline: UInt64?) async throws {
        if process == .app { try files.claim(request.run) }
        record(request, "start", sizes: request.sizes)
        // The time the last size took, scaled to the next, decides whether it can still finish.
        var last: (size: Int, nanoseconds: UInt64)?
        for size in request.sizes {
            let estimate = last.map { $0.nanoseconds * UInt64(size) / UInt64(max($0.size, 1)) } ?? 0
            guard !stopped(deadline), !past(deadline, at: DeviceProbe.uptime() + estimate) else {
                record(request, "timeout", size: size, note: "not enough time left for this size")
                return
            }
            let timing = TimingCenter(center)
            // Uncapped: D9 measures the system's own limit (§5.2's cap is the app's).
            let categories = NotificationCategories(
                registry: try freshRegistry("d9-\(request.run)-\(process.rawValue)"), center: timing, cap: nil)
            let rows = DeviceProbe.rows(size: size, process: process)
            let expected = Set(rows.map(\.category.id))
            let (start, registered) = try await registerIfCurrent(request, deadline: deadline) {
                let start = DeviceProbe.uptime()
                try await categories.register(rows)
                return (start, DeviceProbe.uptime())
            }
            let (seenAt, count) = await readback(expected, deadline: deadline)
            let end = DeviceProbe.uptime()
            // A newer run may have changed the set meanwhile: this measurement no longer stands.
            guard files.isCurrent(request.run) else { throw DeviceProbe.Superseded() }
            last = (size, end - start)
            record(
                request, "size", size: size, setMs: timing.takeLastNanoseconds().map(DeviceProbe.milliseconds),
                registerMs: DeviceProbe.milliseconds(registered - start),
                readbackMs: seenAt.map { DeviceProbe.milliseconds($0 - registered) },
                ok: seenAt.map { !past(deadline, at: $0) } ?? false, overrun: past(deadline, at: end) ? true : nil,
                seen: count)
        }
    }

    /// Runs `change` (a registration) under the probe's lock, while this run is still the current
    /// one.
    @discardableResult
    private func registerIfCurrent<T>(
        _ request: DeviceProbe.Request, deadline: UInt64? = nil, _ change: () async throws -> T
    ) async throws -> T {
        try await files.exclusively(until: deadline) {
            guard files.isCurrent(request.run) else { throw DeviceProbe.Superseded() }
            guard !past(deadline) else { throw DeviceProbe.OutOfTime() }
            return try await change()
        }
    }

    /// D8's check after each registration made outside the lock: if this run was cancelled or
    /// superseded meanwhile, its registration may have replaced what the canceller restored, so
    /// it restores the real table when no run is current (a newer run sets its own set at its
    /// next step), then stops.
    private func confirmCurrent(_ request: DeviceProbe.Request) async throws {
        let restore = restore
        let files = files
        let current = try await Task.detached {
            try await files.exclusively { () async -> Bool in
                guard !files.isCurrent(request.run) else { return true }
                if files.currentRunId() == nil { _ = await restore() }
                return false
            }
        }.value
        guard current else { throw DeviceProbe.Superseded() }
    }

    /// D8's check before each registration: still the current run (under the lock), and in time.
    /// The registration itself runs outside the probe's lock, so the two sides enter §5.2's
    /// `register` concurrently, as §5.4 asks; only the registry's own lock orders them.
    /// `confirmCurrent` afterwards undoes a registration that a cancellation or a newer claim
    /// overtook.
    private func ensureCurrent(_ request: DeviceProbe.Request, deadline: UInt64? = nil) async throws {
        try await registerIfCurrent(request, deadline: deadline) {}
    }

    /// When `notificationCategories()` first included all of `expected` (uptime ns; nil if it
    /// didn't within the limit or before the deadline), and how many of them the last read held.
    private func readback(_ expected: Set<String>, deadline: UInt64?) async -> (UInt64?, Int) {
        let limit = DeviceProbe.uptime() + DeviceProbe.nanoseconds(readbackLimit)
        var count = 0
        while DeviceProbe.uptime() < limit, !stopped(deadline) {
            let missing = DeviceProbe.missing(expected, in: await center.notificationCategories())
            count = expected.count - missing.count
            // A reply that arrives after the limit doesn't count as seen in time.
            let now = DeviceProbe.uptime()
            if missing.isEmpty { return now <= limit ? (now, count) : (nil, count) }
            try? await Task.sleep(for: poll)
        }
        return (nil, count)
    }

    // MARK: D8

    private func d8App(_ request: DeviceProbe.Request) async throws {
        record(request, "start", rounds: request.rounds)
        guard await waitForNSE(request) else {
            record(request, "timeout", note: "the NSE never started: send a test push after launching")
            return
        }
        let registry = try Registry.open(at: files.registry("d8-\(request.run)"), notifier: nil)
        let categories = NotificationCategories(registry: registry, center: center)
        defer { files.write([-1], to: files.appRound(request.run)) }
        for round in 1...request.rounds {
            guard files.isCurrent(request.run), !Task.isCancelled else {
                record(request, "stopped", round: round, note: "a newer run started")
                return
            }
            // Each round starts from an empty table: the system only ever gets this round's set.
            try await registry.writer.write { try $0.execute(sql: "DELETE FROM notification_category") }
            let rendezvous = DeviceProbe.uptime() + DeviceProbe.nanoseconds(rendezvousLead)
            files.write([Int64(round), Int64(rendezvous)], to: files.appRound(request.run))
            await sleep(until: rendezvous)
            guard !Task.isCancelled else { return }
            try await ensureCurrent(request)
            let start = DeviceProbe.uptime()
            try await categories.register(DeviceProbe.d8Rows(round: round, process: .app))
            let end = DeviceProbe.uptime()
            try await confirmCurrent(request)
            guard let nse = await nseAttempt(request, round: round) else {
                record(request, "timeout", round: round, note: "the NSE didn't finish this round")
                return
            }
            let expected = DeviceProbe.d8Expected(round: round)
            let missing = DeviceProbe.missing(expected, in: await center.notificationCategories())
            var reconciled = false
            var stillMissing = missing
            if !missing.isEmpty {
                reconciled = try await registerIfCurrent(request) { try await categories.reconcile() }
                stillMissing = DeviceProbe.missing(expected, in: await center.notificationCategories())
            }
            record(
                request, "round", round: round, ok: stillMissing.isEmpty, missing: missing, reconciled: reconciled,
                overlap: DeviceProbe.overlapped(start...end, nse))
        }
    }

    private func waitForNSE(_ request: DeviceProbe.Request) async -> Bool {
        let limit = ContinuousClock.now + startLimit
        while ContinuousClock.now < limit, !Task.isCancelled {
            if files.records().contains(where: { $0.run == request.run && $0.process == .nse && $0.event == "ready" }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The NSE's attempt for `round` (uptime ns), once it has finished it.
    private func nseAttempt(_ request: DeviceProbe.Request, round: Int) async -> ClosedRange<UInt64>? {
        let limit = ContinuousClock.now + peerLimit
        while ContinuousClock.now < limit, !Task.isCancelled {
            let ack = files.read(files.nseRound(request.run))
            if ack.count == 3, ack[0] >= round, ack[1] <= ack[2] { return UInt64(ack[1])...UInt64(ack[2]) }
            try? await Task.sleep(for: poll)
        }
        return nil
    }

    private func d8NSE(_ request: DeviceProbe.Request, deadline: UInt64?) async throws {
        let categories = NotificationCategories(
            registry: try Registry.open(at: files.registry("d8-\(request.run)"), notifier: nil), center: center)
        record(request, "ready")
        var last: Int64 = 0
        while !stopped(deadline) {
            guard files.isCurrent(request.run) else {
                record(request, "stopped", round: Int(last), note: "a newer run started")
                return
            }
            let app = files.read(files.appRound(request.run))
            if app.first == -1 { return }
            if app.count == 2, app[0] > last {
                await sleep(until: UInt64(app[1]))
                guard !stopped(deadline) else { break }
                try await ensureCurrent(request, deadline: deadline)
                let start = DeviceProbe.uptime()
                try await categories.register(DeviceProbe.d8Rows(round: Int(app[0]), process: .nse))
                let end = DeviceProbe.uptime()
                try await confirmCurrent(request)
                files.write([app[0], Int64(start), Int64(end)], to: files.nseRound(request.run))
                last = app[0]
            } else {
                try? await Task.sleep(for: poll)
            }
        }
        record(request, "timeout", round: Int(last), note: "out of time")
    }
}
#endif
