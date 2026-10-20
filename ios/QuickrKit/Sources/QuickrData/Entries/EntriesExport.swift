import Foundation
import QuickrCore

/// A topic's entries as CSV (the PWA's "Export CSV" on the entries page), online only:
/// `GET /topics/{slug}/entries.csv` with the list's filters, downloaded to a temporary file for
/// the share sheet.
///
/// - An export belongs to the store bound when it started (its ``Scope``): without that store's
///   identity it doesn't start, a response from another server is refused, and a file that
///   arrives after the app moved to another store (or the export was cancelled) is deleted, never
///   handed over.
/// - Each export has a folder of its own under ``root``; ``File/remove()`` removes that one only,
///   so overlapping exports never delete each other's files.
/// - The body streams to disk (`Transport.download`), with the 120 s export deadline.
public struct EntriesExport: Sendable {
    /// What an export needs from the bound store, captured when it starts.
    public struct Scope: Sendable, Hashable {
        public var binding: AppSession.Binding
        public var identity: ServerIdentity

        public init(binding: AppSession.Binding, identity: ServerIdentity) {
            self.binding = binding
            self.identity = identity
        }
    }

    /// One export's file, in a folder of its own.
    public struct File: Sendable, Hashable {
        public let url: URL

        /// Removes this export (its folder), and nothing else.
        public func remove() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    public enum Outcome: Sendable, Equatable {
        case file(File)
        /// No connection: exporting needs one.
        case offline
        case failed(String)
        /// The app moved to another store, or the export was cancelled, before it finished: its
        /// file is gone and there is nothing to show.
        case discarded
    }

    public static let offlineTitle = "Export needs a connection"
    public static let offlineMessage = "Connect to the internet, then try again."
    /// No identity for the bound store yet (it hasn't synced): nothing can be checked, so nothing
    /// is sent.
    public static let notReadyMessage = "This server hasn’t finished syncing yet. Try again in a moment."

    /// Where exports are written, each in its own folder.
    public let root: URL

    public init(root: URL = EntriesExport.defaultRoot) {
        self.root = root
    }

    /// The app's temporary folder for exports.
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    /// The scope of an export starting now: the binding and its store's identity. Nil (so no
    /// export) when there's no binding, or the store's identity can't be read or isn't known.
    public static func scope(
        binding: AppSession.Binding?, context: @Sendable () async throws -> RequestContext
    ) async -> Scope? {
        guard let binding, let context = try? await context(), context.serverId == binding.serverId,
            context.storeGen == binding.storeGen, let identity = context.identity
        else { return nil }
        return Scope(binding: binding, identity: identity)
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

    /// Downloads the CSV for `scope` (its server, Access headers through `credentials`, its
    /// identity checked) into a new folder. The file comes back only while `isCurrent()` still
    /// holds and the task isn't cancelled; otherwise it is deleted (`.discarded`).
    public func export(
        scope: Scope, transport: any Transport, credentials: any AccessCredentialsProvider, slug: String,
        filters: EntryFilters, now: Date, calendar: Calendar, isCurrent: @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let client = APIClient(
            baseURL: scope.binding.baseURL, transport: transport, identity: StaticServerIdentity(scope.identity),
            credentials: credentials, origin: .app)
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = folder.appending(path: Self.fileName(slug: slug, now: now, calendar: calendar))
        let outcome: APIOutcome<URL>
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            outcome = try await client.downloadEntriesCsv(
                ref: slug, filters: filters, to: destination, options: RequestOptions(expecting: scope.identity)
            ).outcome
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .failed(String(describing: error))
        }
        let file = File(url: destination)
        let current = await isCurrent()
        guard current, !Task.isCancelled else {
            file.remove()
            return .discarded
        }
        switch outcome {
        case .success:
            return .file(file)
        case .retryable(.noResponse), .uncertain(.noResponse):
            file.remove()
            return .offline
        case .notFound:
            file.remove()
            return .failed("This topic isn’t on the server any more.")
        case .identityMismatch:
            file.remove()
            return .failed("This address now answers as another server.")
        default:
            file.remove()
            return .failed(outcome.problem?.detail ?? "The server couldn’t export the entries.")
        }
    }
}
