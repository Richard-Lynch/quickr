#if DEBUG
import Foundation
import QuickrCore

/// Checkpoint D's category probe (docs/ios/demo/DEVICE-DAY.md D8 and D9; notifications.md §5.4
/// and D1). DEBUG builds only: Release compiles none of it.
///
/// It runs only on request. The app, launched with `-QuickrDProbe d8|d9`, writes a request into
/// the App Group (`Files.write`), and the NSE takes it (`Files.take`) on the next `test` push
/// ("Test this device"). Both processes then run their side:
///
/// - **D8** (§5.4): `rounds` times, the NSE registers {A, B} while the app registers {A, C}; the
///   app then reads `notificationCategories()` and checks A, B and C are there, at once or after
///   one `reconcile()`.
/// - **D9** (D1): each process registers 100, 1,000 and 5,000 synthetic categories and times
///   `register` (the registry insert plus `setNotificationCategories`) and the time until
///   `notificationCategories()` reflects it. The app runs its side first and writes the request
///   only when it's done, so the two never overlap.
///
/// The probe registers through registries of its own (`dprobe/registry-*`), never the real one,
/// whose table is append-only. While it runs, the system's set is the probe's; each side calls
/// `restore` when it finishes, which re-registers the real table. Every event is one JSON line
/// appended to `dprobe/results.jsonl` (`O_APPEND`: both processes write it);
/// `ios/scripts/dprobe-summary.py` summarises it.
public enum DeviceProbe {
    public enum Kind: String, Codable, Sendable { case d8, d9 }
    public enum Process: String, Codable, Sendable { case app, nse }

    public struct Request: Codable, Sendable, Hashable {
        public var kind: Kind
        /// Tags every record of this run.
        public var run: String
        public var rounds: Int
        public var sizes: [Int]

        public init(
            kind: Kind, run: String = String(UUID().uuidString.prefix(8)), rounds: Int = 100,
            sizes: [Int] = [100, 1000, 5000]
        ) {
            self.kind = kind
            self.run = run
            self.rounds = rounds
            self.sizes = sizes
        }
    }

    /// One line of `results.jsonl`.
    public struct Record: Codable, Sendable, Hashable {
        public var run: String
        public var process: Process
        public var probe: Kind
        /// `ready`, `round`, `size`, `timeout`, `error` or `done`.
        public var event: String
        public var round: Int?
        public var size: Int?
        public var registerMs: Double?
        public var readbackMs: Double?
        public var ok: Bool?
        /// D8: the ids missing at the first read, before any reconcile.
        public var missing: [String]?
        /// D8: whether a reconcile ran (because something was missing).
        public var reconciled: Bool?
        public var note: String?
        public var at: Double

        public init(
            run: String, process: Process, probe: Kind, event: String, round: Int? = nil, size: Int? = nil,
            registerMs: Double? = nil, readbackMs: Double? = nil, ok: Bool? = nil, missing: [String]? = nil,
            reconciled: Bool? = nil, note: String? = nil, at: Date = Date()
        ) {
            self.run = run
            self.process = process
            self.probe = probe
            self.event = event
            self.round = round
            self.size = size
            self.registerMs = registerMs
            self.readbackMs = readbackMs
            self.ok = ok
            self.missing = missing
            self.reconciled = reconciled
            self.note = note
            self.at = at.timeIntervalSince1970
        }

        enum CodingKeys: String, CodingKey {
            case run, process, probe, event, round, size, ok, missing, reconciled, note, at
            case registerMs = "register_ms"
            case readbackMs = "readback_ms"
        }
    }

    // MARK: - Synthetic categories

    /// The probe's categories: a 4-option enum topic each (4 visible actions), like a real one.
    public static func row(topic: String) -> NotificationCategories.Row {
        let options = (1...4).map { QuickLogDescriptor.Choice.Option(value: "o\($0)", label: "Option \($0)") }
        let descriptor = QuickLogDescriptor.choice(.init(key: "k", label: "Probe", options: options, totalOptions: 4))
        return NotificationCategories.Row(
            serverId: serverId, topicId: topic,
            category: NotificationCategory(serverId: serverId, topicId: topic, version: 1, descriptor: descriptor))
    }

    /// The server id of every probe category, so none can be mistaken for a real one.
    public static let serverId = "dprobe"

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

    /// Re-registers the real registry's table (the probe replaced the system's set).
    public static func restore(location: StoreLocation, center: any NotificationCenterProtocol) async {
        guard let registry = try? Registry.open(at: location, notifier: nil) else { return }
        _ = try? await NotificationCategories(registry: registry, center: center).register([])
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15).rounded(toPlaces: 3)
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
        public var results: URL { root.appending(path: "results.jsonl") }
        /// D8: the app's current round (−1 once it has finished), and the NSE's last finished one.
        var appRound: URL { root.appending(path: "d8-app-round") }
        var nseRound: URL { root.appending(path: "d8-nse-round") }

        func registry(_ name: String) -> StoreLocation {
            StoreLocation(root: root.appending(path: "registry-\(name)", directoryHint: .isDirectory))
        }

        /// Writes `request` for the NSE, after clearing D8's round files and registry.
        public func write(_ pending: Request) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for url in [appRound, nseRound, taken] { try? FileManager.default.removeItem(at: url) }
            if pending.kind == .d8 { try? FileManager.default.removeItem(at: registry("d8").root) }
            try JSONEncoder().encode(pending).write(to: request, options: .atomic)
        }

        /// The pending request, taken (renamed) so a second push doesn't run it again; nil when
        /// there is none.
        public func take() -> Request? {
            guard (try? FileManager.default.moveItem(at: request, to: taken)) != nil,
                let data = try? Data(contentsOf: taken)
            else { return nil }
            return try? JSONDecoder().decode(Request.self, from: data)
        }

        /// Appends one line (`O_APPEND`: whole lines from both processes never interleave).
        public func append(_ record: Record) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            let fd = Darwin.open(results.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        public func records() -> [Record] {
            guard let text = try? String(contentsOf: results, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                try? JSONDecoder().decode(Record.self, from: Data($0.utf8))
            }
        }

        func writeRound(_ url: URL, _ round: Int) {
            try? Data(String(round).utf8).write(to: url, options: .atomic)
        }

        func readRound(_ url: URL) -> Int? {
            (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0) }
        }
    }
}

/// One process's side of a probe run.
public struct DeviceProbeRunner: Sendable {
    public let files: DeviceProbe.Files
    public let process: DeviceProbe.Process
    public let center: any NotificationCenterProtocol
    /// Re-registers the real table when the run ends (`DeviceProbe.restore`).
    public let restore: @Sendable () async -> Void
    var poll: Duration = .milliseconds(2)
    /// How long a readback may take to show a registration before it counts as failed.
    var readbackLimit: Duration = .seconds(10)
    /// D8: how long the app waits for the NSE to finish a round, and for its first sign of life.
    var peerLimit: Duration = .seconds(5)
    var startLimit: Duration = .seconds(180)

    public init(
        files: DeviceProbe.Files, process: DeviceProbe.Process, center: any NotificationCenterProtocol,
        restore: @escaping @Sendable () async -> Void
    ) {
        self.files = files
        self.process = process
        self.center = center
        self.restore = restore
    }

    /// Runs this process's side of `request`, stopping at `deadline` (the NSE's budget) or when
    /// cancelled, then restores the real categories.
    public func run(_ request: DeviceProbe.Request, until deadline: ContinuousClock.Instant? = nil) async {
        do {
            switch (request.kind, process) {
            case (.d9, _): try await d9(request, deadline: deadline)
            case (.d8, .app): try await d8App(request)
            case (.d8, .nse): try await d8NSE(request, deadline: deadline)
            }
        } catch {
            record(request, "error", note: String(describing: error))
        }
        await restore()
        record(request, "done")
    }

    private func record(
        _ request: DeviceProbe.Request, _ event: String, round: Int? = nil, size: Int? = nil,
        registerMs: Double? = nil, readbackMs: Double? = nil, ok: Bool? = nil, missing: [String]? = nil,
        reconciled: Bool? = nil, note: String? = nil
    ) {
        files.append(
            DeviceProbe.Record(
                run: request.run, process: process, probe: request.kind, event: event, round: round, size: size,
                registerMs: registerMs, readbackMs: readbackMs, ok: ok, missing: missing, reconciled: reconciled,
                note: note))
    }

    private func expired(_ deadline: ContinuousClock.Instant?) -> Bool {
        Task.isCancelled || deadline.map { ContinuousClock.now >= $0 } == true
    }

    /// A registry of the probe's own, emptied first.
    private func freshRegistry(_ name: String) throws -> Registry {
        let location = files.registry(name)
        try? FileManager.default.removeItem(at: location.root)
        return try Registry.open(at: location, notifier: nil)
    }

    // MARK: D9

    private func d9(_ request: DeviceProbe.Request, deadline: ContinuousClock.Instant?) async throws {
        for size in request.sizes {
            guard !expired(deadline) else {
                record(request, "timeout", size: size, note: "out of time before this size")
                return
            }
            let categories = NotificationCategories(
                registry: try freshRegistry("d9-\(process.rawValue)"), center: center)
            let rows = DeviceProbe.rows(size: size, process: process)
            let expected = Set(rows.map(\.category.id))
            let start = ContinuousClock.now
            try await categories.register(rows)
            let registered = ContinuousClock.now
            let seen = await readback(expected, deadline: deadline)
            record(
                request, "size", size: size, registerMs: DeviceProbe.milliseconds(registered - start),
                readbackMs: seen.map { DeviceProbe.milliseconds($0 - registered) }, ok: seen != nil)
        }
    }

    /// When `notificationCategories()` first included all of `expected`; nil if it didn't within
    /// the limit.
    private func readback(_ expected: Set<String>, deadline: ContinuousClock.Instant?) async
        -> ContinuousClock.Instant?
    {
        let limit = ContinuousClock.now + readbackLimit
        while ContinuousClock.now < limit, !expired(deadline) {
            if DeviceProbe.missing(expected, in: await center.notificationCategories()).isEmpty {
                return ContinuousClock.now
            }
            try? await Task.sleep(for: poll)
        }
        return nil
    }

    // MARK: D8

    private func d8App(_ request: DeviceProbe.Request) async throws {
        guard await waitForNSE(request) else {
            record(request, "timeout", note: "the NSE never started: send a test push after launching")
            return
        }
        let categories = NotificationCategories(
            registry: try Registry.open(at: files.registry("d8"), notifier: nil), center: center)
        for round in 1...request.rounds {
            files.writeRound(files.appRound, round)
            // Alternate who goes first: odd rounds give the NSE a head start.
            if round % 2 == 1 { try? await Task.sleep(for: .milliseconds(1)) }
            try await categories.register(DeviceProbe.d8Rows(round: round, process: .app))
            let nseDone = await wait(for: round)
            let expected = DeviceProbe.d8Expected(round: round)
            let missing = DeviceProbe.missing(expected, in: await center.notificationCategories())
            var reconciled = false
            var stillMissing = missing
            if !missing.isEmpty {
                reconciled = try await categories.reconcile()
                stillMissing = DeviceProbe.missing(expected, in: await center.notificationCategories())
            }
            record(
                request, "round", round: round, ok: nseDone && stillMissing.isEmpty, missing: missing,
                reconciled: reconciled, note: nseDone ? nil : "the NSE didn't finish this round")
            guard nseDone else { break }
        }
        files.writeRound(files.appRound, -1)
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

    private func wait(for round: Int) async -> Bool {
        let limit = ContinuousClock.now + peerLimit
        while ContinuousClock.now < limit, !Task.isCancelled {
            if (files.readRound(files.nseRound) ?? 0) >= round { return true }
            try? await Task.sleep(for: poll)
        }
        return false
    }

    private func d8NSE(_ request: DeviceProbe.Request, deadline: ContinuousClock.Instant?) async throws {
        let categories = NotificationCategories(
            registry: try Registry.open(at: files.registry("d8"), notifier: nil), center: center)
        record(request, "ready")
        var last = 0
        while !expired(deadline) {
            let round = files.readRound(files.appRound) ?? 0
            if round < 0 { break }
            if round > last {
                try await categories.register(DeviceProbe.d8Rows(round: round, process: .nse))
                files.writeRound(files.nseRound, round)
                last = round
            } else {
                try? await Task.sleep(for: poll)
            }
        }
        if expired(deadline) { record(request, "timeout", round: last, note: "out of time") }
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
#endif
