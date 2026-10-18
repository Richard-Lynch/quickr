import Foundation
import QuickrData

// Clocks shared by every process of a multi-process test (sync-protocol.md §13 G5). Lease time
// is system-wide in production (`mach_continuous_time` and the boot session id); here it is one
// small file that every process reads on each `now()` and only the test process writes, so the
// test moves time past a TTL, or "reboots", without waiting. The wall clock is a second file:
// moving it shows that leases never read it.

/// Lease time from a file holding `"<boot id> <ct>"`.
public final class FileLeaseClock: LeaseClock {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Creates (or resets) the file at `ct` nanoseconds into boot `bootId`.
    @discardableResult
    public static func create(
        at url: URL, bootId: String = "boot-1", ct: Int64 = 1_000_000_000
    ) throws -> FileLeaseClock {
        let clock = FileLeaseClock(url: url)
        try clock.set(LeaseInstant(bootId: bootId, ct: ct))
        return clock
    }

    public func now() -> LeaseInstant {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("FileLeaseClock: unreadable \(url.path)")
        }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let ct = Int64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preconditionFailure("FileLeaseClock: malformed \(url.path): \(text)")
        }
        return LeaseInstant(bootId: String(parts[0]), ct: ct)
    }

    public func set(_ instant: LeaseInstant) throws {
        try SharedFile.write("\(instant.bootId) \(instant.ct)", to: url)
    }

    public func advance(by duration: Duration) throws { try set(now().adding(duration)) }

    /// A new boot session: every deadline of the old one has passed.
    public func reboot(bootId: String = UUID().uuidString, ct: Int64 = 1_000_000_000) throws {
        try set(LeaseInstant(bootId: bootId, ct: ct))
    }
}

/// Wall-clock time from a file holding Unix seconds.
public final class FileWallClock: WallClock {
    public let url: URL

    public init(url: URL) { self.url = url }

    @discardableResult
    public static func create(at url: URL, date: Date = Date(timeIntervalSince1970: 1_772_625_600)) throws
        -> FileWallClock
    {
        let clock = FileWallClock(url: url)
        try clock.set(date)
        return clock
    }

    public func now() -> Date {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { preconditionFailure("FileWallClock: unreadable \(url.path)") }
        return Date(timeIntervalSince1970: seconds)
    }

    public func set(_ date: Date) throws { try SharedFile.write(String(date.timeIntervalSince1970), to: url) }

    public func advance(by seconds: TimeInterval) throws { try set(now().addingTimeInterval(seconds)) }
}

enum SharedFile {
    /// Replaces the file atomically, so a reader never sees a partial write.
    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
