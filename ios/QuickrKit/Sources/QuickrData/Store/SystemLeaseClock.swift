import Darwin
import Foundation

/// Lease time on the device (sync-protocol.md §5.3): nanoseconds of `mach_continuous_time()`,
/// which is system-wide, counts through sleep and ignores wall-clock changes, paired with the
/// boot session id from `sysctl kern.bootsessionuuid` (falling back to `kern.boottime`).
public struct SystemLeaseClock: LeaseClock {
    public let bootId: String
    private let numer: UInt64
    private let denom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = UInt64(max(info.denom, 1))
        bootId = Self.readBootId()
    }

    public func now() -> LeaseInstant {
        let ticks = mach_continuous_time()
        let (high, low) = ticks.multipliedFullWidth(by: numer)
        let nanos = denom.dividingFullWidth((high, low)).quotient
        return LeaseInstant(bootId: bootId, ct: Int64(clamping: nanos))
    }

    static func readBootId() -> String {
        if let uuid = sysctlString("kern.bootsessionuuid"), !uuid.isEmpty { return uuid }
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 {
            return "boottime:\(boottime.tv_sec).\(boottime.tv_usec)"
        }
        return "boottime:unknown"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
