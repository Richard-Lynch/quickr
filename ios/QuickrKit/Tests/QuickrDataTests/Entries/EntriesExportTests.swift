import Foundation
import QuickrCore
import QuickrTestSupport
import Synchronization
import Testing

@testable import QuickrData

/// CSV (the PWA's "Export CSV"): the request the list's filters make, the file's name, what an
/// export leaves behind, and that it belongs to the store it started in.
@MainActor @Suite(.timeLimit(.minutes(5))) struct EntriesExportTests {
    static let csv = "id,captured_at,mood\n1,2026-10-20T08:00:00Z,good\n"

    /// Berlin, 2026-10-20 00:30 local (22:30 UTC the day before).
    static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    static let now = ISO8601DateFormatter().date(from: "2026-10-19T22:30:00Z")!
    static let binding = AppSession.Binding(
        serverId: APITest.fixtureIdentity.serverId, storeGen: 1, baseURL: APITest.baseURL)
    static let scope = EntriesExport.Scope(binding: binding, identity: APITest.fixtureIdentity)

    /// A value the test and a closure share.
    final class Box<T: Sendable>: Sendable {
        private let value: Mutex<T>
        init(_ value: T) { self.value = Mutex(value) }
        func get() -> T { value.withLock { $0 } }
        func set(_ new: T) { value.withLock { $0 = new } }
    }

    /// Holds the next request until released: an export still downloading.
    final class Gated: Transport {
        let inner: any Transport
        private let state = Mutex<(hold: Bool, parked: CheckedContinuation<Void, Never>?)>((false, nil))

        init(_ inner: any Transport) { self.inner = inner }

        func hold() { state.withLock { $0.hold = true } }
        var isHolding: Bool { state.withLock { $0.parked != nil } }
        func release() {
            let parked = state.withLock { state in
                defer { state.parked = nil }
                return state.parked
            }
            parked?.resume()
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            if state.withLock({ $0.hold }) {
                await withCheckedContinuation { continuation in
                    state.withLock {
                        $0.hold = false
                        $0.parked = continuation
                    }
                }
            }
            try Task.checkCancellation()
            return try await inner.send(request)
        }
    }

    /// A download that takes `duration` (simulated: it fails like a deadline would when the
    /// request allows less) and writes `size` bytes to the file in chunks; `send` is never right.
    final class SlowDisk: Transport {
        let duration: Duration
        let size: Int
        let sends = Mutex(0)
        let requests = Mutex<[HTTPRequest]>([])

        init(duration: Duration, size: Int) {
            self.duration = duration
            self.size = size
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            sends.withLock { $0 += 1 }
            throw TransportError.failed("buffered in memory", requestStarted: true)
        }

        func download(_ request: HTTPRequest, to destination: URL) async throws -> HTTPResponse {
            requests.withLock { $0.append(request) }
            guard request.timeout >= duration else { throw TransportError.timedOut(requestStarted: true) }
            FileManager.default.createFile(atPath: destination.path(), contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
            for _ in 0..<(size / chunk.count) { try handle.write(contentsOf: chunk) }
            try handle.close()
            return APITest.response(200, headers: ["Content-Type": "text/csv"])
        }
    }

    @MainActor struct World {
        let fake = FakeTransport()
        let gated: Gated
        let root = FileManager.default.temporaryDirectory.appending(path: "csv-tests-\(UUID().uuidString)")
        let current = Box(true)
        let ledger = EntriesExport.Ledger()
        var export: EntriesExport { EntriesExport(root: root, ledger: ledger) }

        init() { gated = Gated(fake) }

        func run(
            _ filters: EntryListFilters = .init(), slug: String = "mood", transport: (any Transport)? = nil
        ) async -> EntriesExport.Outcome {
            let current = current
            return await export.export(
                scope: EntriesExportTests.scope, transport: transport ?? gated,
                credentials: StaticAccessCredentials(AccessCredentials(clientId: "id.access", clientSecret: "secret")),
                slug: slug, filters: EntriesExport.filters(filters, now: EntriesExportTests.now, calendar: berlin),
                now: EntriesExportTests.now, calendar: berlin, isCurrent: { current.get() })
        }

        func csvResponse(_ body: String = EntriesExportTests.csv) -> HTTPResponse {
            APITest.response(200, json: body, headers: ["Content-Type": "text/csv; charset=utf-8"])
        }

        /// A folder an earlier process left, `age` seconds old.
        func leftover(_ name: String, age: TimeInterval) throws -> URL {
            let folder = root.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "mood-20261020.csv"))
            try FileManager.default.setAttributes(
                [.modificationDate: EntriesExportTests.now.addingTimeInterval(-age)], ofItemAtPath: folder.path())
            return folder
        }

        /// Every export folder left under the root.
        var folders: [URL] {
            (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        }
    }

    // MARK: - The request

    /// The list's filters, as the PWA's `csvHref` sends them: the range from local midnight
    /// (today and the 6 days before), the version and the source; through the client, so with
    /// the Access headers, the CSV Accept, and the export deadline.
    @Test func theRequestCarriesTheListsFilters() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        _ = await w.run(EntryListFilters(range: .sevenDays, version: 2, source: "shortcut"))
        let request = try #require(w.fake.requests.first)
        #expect(request.method == .get)
        #expect(request.url.path() == "/api/v1/topics/mood/entries.csv")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let from = try #require(ISO8601DateFormatter().date(from: "2026-10-13T22:00:00Z"))  // Oct 14, 00:00 CEST
        #expect(
            query == [
                URLQueryItem(name: "captured_from", value: WireDate.format(from)),
                URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "source", value: "shortcut"),
            ])
        #expect(request.headers["Accept"] == "text/csv")
        #expect(request.headers[QuickrHeader.cfAccessClientId] == "id.access")
        #expect(request.headers[QuickrHeader.cfAccessClientSecret] == "secret")
        #expect(request.timeout == APIClient.exportTimeout)
    }

    @Test func allTimeAndNoFiltersSendNoQuery() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        _ = await w.run(EntryListFilters(range: .all))
        let request = try #require(w.fake.requests.first)
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems == nil)
    }

    // MARK: - Scope

    /// No identity for the bound store, no export: the context can't be read, has no epoch yet,
    /// or belongs to another store than the binding.
    @Test func anExportNeedsTheBoundStoresIdentity() async {
        struct Unreadable: Error {}
        let b = Self.binding
        @Sendable func context(storeGen: Int = 1, epoch: String? = "e") -> RequestContext {
            RequestContext(serverId: b.serverId, storeGen: storeGen, layerGen: 1, epoch: epoch)
        }
        #expect(await EntriesExport.scope(binding: b, context: { throw Unreadable() }) == nil)
        #expect(await EntriesExport.scope(binding: nil, context: { context() }) == nil)
        #expect(await EntriesExport.scope(binding: b, context: { context(epoch: nil) }) == nil)
        #expect(await EntriesExport.scope(binding: b, context: { context(storeGen: 2) }) == nil)
        let scope = await EntriesExport.scope(binding: b, context: { context() })
        #expect(scope == EntriesExport.Scope(binding: b, identity: ServerIdentity(serverId: b.serverId, epoch: "e")))
    }

    /// The app moves to another server while the export downloads: nothing comes back to share,
    /// and its file is gone.
    @Test func anExportThatFinishesAfterASwitchIsDiscarded() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        w.gated.hold()
        let exporting = Task { await w.run() }
        while !w.gated.isHolding { await Task.yield() }
        w.current.set(false)  // rebound
        w.gated.release()
        #expect(await exporting.value == .discarded)
        #expect(w.folders.isEmpty)
    }

    /// Leaving the screen cancels it: discarded, nothing left.
    @Test func aCancelledExportLeavesNothing() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        w.gated.hold()
        let exporting = Task { await w.run() }
        while !w.gated.isHolding { await Task.yield() }
        exporting.cancel()
        w.gated.release()
        #expect(await exporting.value == .discarded)
        #expect(w.folders.isEmpty)
    }

    /// The export came back with its file, then the app switched server (or the export was
    /// cancelled) before the share sheet: nothing is presented and the file is gone.
    @Test func aSwitchAfterTheFileArrivesStillPresentsNothing() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        w.fake.enqueue(.success(w.csvResponse()))
        guard case .file(let file) = await w.run(), case .file(let other) = await w.run() else {
            Issue.record("no files")
            return
        }
        let presented = Box<[URL]>([])
        w.current.set(false)  // rebound in between
        let current = w.current
        let shown = EntriesExport.handOver(
            file, isCurrent: { current.get() }, present: { url in presented.set([url]) })
        #expect(!shown)
        #expect(presented.get().isEmpty && !FileManager.default.fileExists(atPath: file.url.path()))

        w.current.set(true)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return EntriesExport.handOver(other, isCurrent: { current.get() }, present: { url in presented.set([url]) })
        }
        #expect(await cancelled.value == false)
        #expect(presented.get().isEmpty && w.folders.isEmpty)
    }

    @Test func aCurrentFileIsPresented() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        guard case .file(let file) = await w.run() else {
            Issue.record("no file")
            return
        }
        let presented = Box<[URL]>([])
        let shown = EntriesExport.handOver(file, isCurrent: { true }, present: { url in presented.set([url]) })
        #expect(shown)
        #expect(presented.get() == [file.url] && FileManager.default.fileExists(atPath: file.url.path()))
        file.remove()
    }

    // MARK: - The file

    /// The server's `Content-Disposition` name: the slug and the local date.
    @Test func theFileIsNamedLikeTheServersDownload() {
        #expect(EntriesExport.fileName(slug: "mood", now: Self.now, calendar: Self.berlin) == "mood-20261020.csv")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(EntriesExport.fileName(slug: "mood", now: Self.now, calendar: utc) == "mood-20261019.csv")
        #expect(EntriesExport.fileName(slug: "a/b", now: Self.now, calendar: utc) == "a-b-20261019.csv")
    }

    /// Two exports at once: each has its own file, which stays until that export removes it.
    @Test func overlappingExportsKeepTheirOwnFiles() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse("first\n")))
        w.fake.enqueue(.success(w.csvResponse("second\n")))
        w.gated.hold()
        let firstRun = Task { await w.run(slug: "mood") }
        while !w.gated.isHolding { await Task.yield() }
        let second = await w.run(slug: "mood")
        w.gated.release()
        let first = await firstRun.value
        guard case .file(let a) = first, case .file(let b) = second else {
            Issue.record("no files: \(first), \(second)")
            return
        }
        #expect(a.url != b.url && a.url.lastPathComponent == "mood-20261020.csv")
        let folder = a.url.deletingLastPathComponent().deletingLastPathComponent()
        #expect(folder.standardizedFileURL == w.root.standardizedFileURL)
        let contents = [try String(contentsOf: a.url, encoding: .utf8), try String(contentsOf: b.url, encoding: .utf8)]
        #expect(Set(contents) == ["first\n", "second\n"])
        b.remove()
        #expect(FileManager.default.fileExists(atPath: a.url.path()), "removing one leaves the other")
        #expect(!FileManager.default.fileExists(atPath: b.url.path()))
        a.remove()
        #expect(w.folders.isEmpty)
    }

    /// The body goes straight to disk (never through `send`, so never into memory), and a
    /// download that takes 30 s fits the export deadline.
    @Test func aLargeSlowExportStreamsToDisk() async throws {
        let w = World()
        let disk = SlowDisk(duration: .seconds(30), size: 4 * 1024 * 1024)
        guard case .file(let file) = await w.run(transport: disk) else {
            Issue.record("no file")
            return
        }
        #expect(disk.sends.withLock { $0 } == 0)
        let size = try FileManager.default.attributesOfItem(atPath: file.url.path())[.size] as? Int
        #expect(size == 4 * 1024 * 1024)
        #expect(disk.requests.withLock { $0.first?.timeout } == .seconds(120))
        file.remove()
    }

    /// Leftovers of an earlier process: folders older than a day go, newer ones stay.
    @Test func theSweepRemovesDayOldExportsOfEarlierProcesses() throws {
        let w = World()
        let old = try w.leftover("old", age: 25 * 3600)
        _ = try w.leftover("recent", age: 23 * 3600)
        w.export.sweep(now: Self.now)
        #expect(w.folders.map(\.lastPathComponent) == ["recent"])
        #expect(!FileManager.default.fileExists(atPath: old.path()))
        try? FileManager.default.removeItem(at: w.root)
    }

    /// `start()` runs again for a background refresh: only the first sweep in a process removes
    /// anything.
    @Test func onlyTheFirstSweepInAProcessRuns() throws {
        let w = World()
        w.export.sweep(now: Self.now)
        _ = try w.leftover("old", age: 25 * 3600)
        w.export.sweep(now: Self.now)
        #expect(w.folders.map(\.lastPathComponent) == ["old"])
        try? FileManager.default.removeItem(at: w.root)
    }

    /// An export of this process is never swept, even dated a day back (a share sheet open that
    /// long, or a clock change).
    @Test func thisProcesssExportsAreNeverSwept() async throws {
        let w = World()
        w.fake.enqueue(.success(w.csvResponse()))
        guard case .file(let file) = await w.run() else {
            Issue.record("no file")
            return
        }
        let folder = file.url.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.modificationDate: Self.now.addingTimeInterval(-48 * 3600)], ofItemAtPath: folder.path())
        w.export.sweep(now: Self.now)
        #expect(FileManager.default.fileExists(atPath: file.url.path()))
        file.remove()
    }

    // MARK: - Failures

    @Test func noConnectionIsOffline() async {
        let w = World()
        w.fake.enqueue(.failure(.unreachable("offline")))
        #expect(await w.run() == .offline)
        #expect(w.folders.isEmpty)
    }

    @Test func otherFailuresSaySoAndLeaveNothing() async {
        let w = World()
        w.fake.enqueue(.success(APITest.response(404, json: APITest.problem("not_found", "Topic not found"))))
        #expect(await w.run() == .failed("This topic isn’t on the server any more."))
        let portal = APITest.response(200, json: "<html>portal</html>", headers: ["Content-Type": "text/html"])
        w.fake.enqueue(.success(portal))
        #expect(await w.run() == .failed("The server couldn’t export the entries."), "a captive portal")
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.otherEpoch)
        let elsewhere = APITest.response(200, json: Self.csv, identity: other, headers: ["Content-Type": "text/csv"])
        w.fake.enqueue(.success(elsewhere))
        #expect(await w.run() == .failed("This address now answers as another server."))
        #expect(w.folders.isEmpty, "nothing written")
    }
}
