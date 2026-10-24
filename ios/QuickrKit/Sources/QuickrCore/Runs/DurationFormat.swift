import Foundation

/// `fmtDuration`, the duration format of every client (timers.md §11.1): `m:ss` below one hour,
/// `h:mm:ss` from one hour (hours unbounded). Truncated to whole seconds, so a running timer and
/// the saved value agree; negative input reads `0:00`. Pinned by
/// `shared/fixtures/duration-format-vectors.json` (`run_fold.fmt_duration`).
public enum DurationFormat {
    public static func format(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let (hours, rest) = seconds.quotientAndRemainder(dividingBy: 3600)
        let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(secs))" : "\(minutes):\(two(secs))"
    }
}
