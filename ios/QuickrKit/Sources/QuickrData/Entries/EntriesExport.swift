import Foundation
import QuickrCore

/// A topic's entries as CSV (the PWA's "Export CSV" on the entries page), online only:
/// `GET /topics/{slug}/entries.csv` with the list's filters, written to a temporary file for the
/// share sheet. Exports live in one folder, emptied before each export and once shared.
public struct EntriesExport: Sendable {
    public enum Outcome: Sendable, Equatable {
        case file(URL)
        /// No connection: exporting needs one.
        case offline
        case failed(String)
    }

    public static let offlineTitle = "Export needs a connection"
    public static let offlineMessage = "Connect to the internet, then try again."

    /// Where exports are written.
    public let directory: URL

    public init(directory: URL = EntriesExport.defaultDirectory) {
        self.directory = directory
    }

    /// The app's temporary folder for exports.
    public static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    /// The request's filters: the list's (the PWA's `filterQuery`), its range anchored at `now`.
    public static func filters(_ list: EntryListFilters, now: Date, calendar: Calendar) -> EntryFilters {
        EntryFilters(
            capturedFrom: list.range.start(now: now, calendar: calendar), version: list.version, source: list.source)
    }

    /// The server's name for it (its `Content-Disposition`, which the PWA's download keeps):
    /// `{slug}-{yyyyMMdd}.csv`, dated in `calendar`'s time zone.
    public static func fileName(slug: String, now: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        let stamp = String(format: "%04d%02d%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        // A slug is URL-safe already; keep a file name to one path component regardless.
        return "\(slug.replacingOccurrences(of: "/", with: "-"))-\(stamp).csv"
    }

    /// Fetches the CSV with `client` (its Access headers and identity check) and writes it to
    /// `directory`, replacing any earlier export. `identity` is the bound store's: a response
    /// from another server is refused.
    public func export(
        client: APIClient, slug: String, filters: EntryFilters, identity: ServerIdentity?, now: Date,
        calendar: Calendar
    ) async -> Outcome {
        let outcome: APIOutcome<Data>
        do {
            outcome = try await client.exportEntriesCsv(
                ref: slug, filters: filters, options: RequestOptions(expecting: identity)
            ).outcome
        } catch {
            return .failed(String(describing: error))
        }
        switch outcome {
        case .success(let csv):
            do {
                cleanUp()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appending(path: Self.fileName(slug: slug, now: now, calendar: calendar))
                try csv.write(to: file, options: .atomic)
                return .file(file)
            } catch {
                return .failed("Couldn’t save the export: \(error.localizedDescription)")
            }
        case .retryable(.noResponse), .uncertain(.noResponse):
            return .offline
        case .notFound:
            return .failed("This topic isn’t on the server any more.")
        case .identityMismatch:
            return .failed("This address now answers as another server.")
        default:
            return .failed(outcome.problem?.detail ?? "The server couldn’t export the entries.")
        }
    }

    /// Removes every export (after sharing, and before the next one).
    public func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
