import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// CSV (the PWA's "Export CSV"): the request the list's filters make, the file's name, and what
/// an export leaves behind.
@Suite(.timeLimit(.minutes(2))) struct EntriesExportTests {
    static let csv = "id,captured_at,mood\n1,2026-10-20T08:00:00Z,good\n"

    /// Berlin, 2026-10-20 00:30 local (22:30 UTC the day before).
    static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    static let now = ISO8601DateFormatter().date(from: "2026-10-19T22:30:00Z")!

    struct World {
        let transport = FakeTransport()
        let directory = FileManager.default.temporaryDirectory.appending(path: "csv-tests-\(UUID().uuidString)")
        var export: EntriesExport { EntriesExport(directory: directory) }

        func client(credentials: AccessCredentials? = nil) -> APIClient {
            APITest.client(transport, credentials: credentials)
        }

        func run(_ filters: EntryListFilters = .init(), slug: String = "mood") async -> EntriesExport.Outcome {
            await export.export(
                client: client(credentials: AccessCredentials(clientId: "id.access", clientSecret: "secret")),
                slug: slug, filters: EntriesExport.filters(filters, now: EntriesExportTests.now, calendar: berlin),
                identity: APITest.fixtureIdentity, now: EntriesExportTests.now, calendar: berlin)
        }

        func csvResponse(_ body: String = EntriesExportTests.csv) -> HTTPResponse {
            APITest.response(200, json: body, headers: ["Content-Type": "text/csv; charset=utf-8"])
        }
    }

    // MARK: - The request

    /// The list's filters, as the PWA's `csvHref` sends them: the range from local midnight
    /// (today and the 6 days before), the version and the source; through the client, so with
    /// the Access headers and the CSV Accept.
    @Test func theRequestCarriesTheListsFilters() async throws {
        let w = World()
        w.transport.enqueue(.success(w.csvResponse()))
        _ = await w.run(EntryListFilters(range: .sevenDays, version: 2, source: "shortcut"))
        let request = try #require(w.transport.requests.first)
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
    }

    @Test func allTimeAndNoFiltersSendNoQuery() async throws {
        let w = World()
        w.transport.enqueue(.success(w.csvResponse()))
        _ = await w.run(EntryListFilters(range: .all))
        let request = try #require(w.transport.requests.first)
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems == nil)
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

    /// Written to the exports folder under that name, replacing any earlier export; cleaning up
    /// removes it.
    @Test func anExportReplacesTheLastAndCleansUp() async throws {
        let w = World()
        w.transport.enqueue(.success(w.csvResponse("old\n")))
        w.transport.enqueue(.success(w.csvResponse()))
        let outcomes = [await w.run(slug: "water"), await w.run()]
        guard case .file(let first) = outcomes[0], case .file(let file) = outcomes[1] else {
            Issue.record("no file: \(outcomes)")
            return
        }
        #expect(file.lastPathComponent == "mood-20261020.csv")
        #expect(file.deletingLastPathComponent().standardizedFileURL == w.directory.standardizedFileURL)
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.csv)
        #expect(!FileManager.default.fileExists(atPath: first.path()), "the earlier export is gone")
        w.export.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: w.directory.path()))
    }

    // MARK: - Failures

    @Test func noConnectionIsOffline() async {
        let w = World()
        w.transport.enqueue(.failure(.unreachable("offline")))
        #expect(await w.run() == .offline)
        #expect(!FileManager.default.fileExists(atPath: w.directory.path()))
    }

    @Test func otherFailuresSaySo() async {
        let w = World()
        w.transport.enqueue(.success(APITest.response(404, json: APITest.problem("not_found", "Topic not found"))))
        #expect(await w.run() == .failed("This topic isn’t on the server any more."))
        let portal = APITest.response(200, json: "<html>portal</html>", headers: ["Content-Type": "text/html"])
        w.transport.enqueue(.success(portal))
        #expect(await w.run() == .failed("The server couldn’t export the entries."), "a captive portal")
        let other = ServerIdentity(serverId: APITest.otherServer, epoch: APITest.otherEpoch)
        let elsewhere = APITest.response(200, json: Self.csv, identity: other, headers: ["Content-Type": "text/csv"])
        w.transport.enqueue(.success(elsewhere))
        #expect(await w.run() == .failed("This address now answers as another server."))
        #expect(!FileManager.default.fileExists(atPath: w.directory.path()), "nothing written")
    }
}
