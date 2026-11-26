import Darwin
import Foundation
import Synchronization

/// Removes a test's temporary directory without unlinking a database file that is still open.
///
/// A file unlinked under an open SQLite connection is an API violation, and SQLite logs it on every
/// later access ("BUG IN CLIENT OF libsqlite3.dylib: … vnode unlinked while in use", "invalidated
/// open fd"). A test's pools usually outlive its cleanup by a little (a `defer` runs before the
/// locals holding them are released, a harness deletes its directory in its own `deinit`, a
/// background task is still finishing), so QuickrDataTests logged 5,000 to 8,500 of these lines a
/// Unit-plan run on CI, about 80% of its output. Under xcodebuild that output goes to a terminal
/// xcodebuild reads, and Swift Testing writes its events to the same terminal synchronously on the
/// cooperative pool: on CI's 3-core runner all three pool threads were seen parked in those writes
/// for whole seconds, and the bundle stalled until the step timed out (#241, #190).
///
/// So a directory is removed at once only when nothing inside it is open; otherwise it waits, and
/// a reaper thread of its own (never a cooperative or a dispatch one) removes it once its last
/// file is closed, or after `grace` whatever is still open: a pool that is never released (a
/// session nobody shuts down) would otherwise keep its descriptors for the rest of the process,
/// which SQLite drops itself once its file is gone, and a repeated run (`-test-iterations`) ran
/// out of them. Cleanup is final: nothing may open a new file in a directory handed here.
public enum TestFiles {
    public static func remove(_ url: URL) {
        // The real path, as F_GETPATH reports it (/private/var/…, not /var/…).
        guard let real = realpath(url.path, nil) else { return }  // gone already
        let path = String(cString: real)
        free(real)
        if let open = openPaths(), !isInUse(path, open: open) {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            reaper.add(path)
        }
    }

    private static let reaper = Reaper()

    /// How long a directory waits for its files to close.
    public static let grace: Duration = .seconds(60)

    /// Whether any of `open` is `directory` or inside it.
    public static func isInUse(_ directory: String, open: [String]) -> Bool {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return open.contains { $0 == directory || $0.hasPrefix(prefix) }
    }

    /// The paths of this process's open file descriptors: `/dev/fd` lists them (the descriptor
    /// table itself can be 90,000 slots), `F_GETPATH` names each (sockets and pipes have none).
    /// Nil when they can't be listed (out of descriptors, say): then nothing counts as closed.
    static func openPaths() -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return nil }
        let fds = names.compactMap { Int32($0) }
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in fds where fcntl(fd, F_GETPATH, &buffer) != -1 {
            paths.append(String(cString: buffer))
        }
        return paths
    }

    private final class Reaper: Sendable {
        private let pending = Mutex<[(path: String, until: ContinuousClock.Instant)]>([])
        private let wake = NSCondition()

        init() {
            let thread = Thread { [self] in run() }
            thread.name = "TestFiles.reaper"
            thread.start()
        }

        func add(_ path: String) {
            let until = ContinuousClock.now.advanced(by: TestFiles.grace)
            pending.withLock { $0.append((path, until)) }
            wake.lock()
            wake.signal()
            wake.unlock()
        }

        private func run() {
            while true {
                wake.lock()
                if pending.withLock({ $0.isEmpty }) { wake.wait() } else { _ = wake.wait(until: Date() + 0.2) }
                wake.unlock()
                // The descriptors are listed after the pending ones are read, so each is checked
                // against a listing taken after it was handed over.
                let candidates = pending.withLock { $0 }
                let open = TestFiles.openPaths()
                let now = ContinuousClock.now
                let due = candidates.filter { candidate in
                    guard now < candidate.until else { return true }
                    guard let open else { return false }
                    return !TestFiles.isInUse(candidate.path, open: open)
                }.map(\.path)
                guard !due.isEmpty else { continue }
                pending.withLock { pending in pending.removeAll { due.contains($0.path) } }
                for path in due { try? FileManager.default.removeItem(atPath: path) }
            }
        }
    }
}
