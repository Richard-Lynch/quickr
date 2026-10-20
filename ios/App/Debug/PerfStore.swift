#if DEBUG
import Darwin
import Foundation
import Observation
import QuickrCore
import QuickrData

/// `-QuickrPerfStore`: launches over a heavy user's store (`PerfSeed`: 10,000 entries in 20 topics,
/// a busy outbox), offline, and shows how long the process took to put Home's first tile on screen
/// (`perf.firstRender`, in milliseconds). Debug builds only; `PerfLaunchUITests` reads it.
///
/// The store stays in the app's caches between launches: the first launch seeds it (seconds, and
/// not a cold start worth measuring), and every later one opens it the way a real launch opens
/// the App Group's, so the session opens in `init` rather than after a seeding step.
enum PerfStore {
    static let argument = "-QuickrPerfStore"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static let root = URL.cachesDirectory.appending(path: "quickr-perf")
    /// Written after a seed completes; without it the directory is wiped and seeded again.
    static let seededMarker = root.appending(path: "seeded-v1")

    @MainActor static func environment() -> AppEnvironment {
        let location = StoreLocation(root: root)
        let defaults = UserDefaults(suiteName: "quickr-perf")!
        guard FileManager.default.fileExists(atPath: seededMarker.path) else {
            return AppEnvironment(
                settings: AppSettings(defaults: defaults),
                prepare: {
                    try? FileManager.default.removeItem(at: root)
                    do {
                        _ = try await PerfSeed.seed(at: location)
                        FileManager.default.createFile(atPath: seededMarker.path, contents: nil)
                    } catch {
                        print("PERF seed failed: \(error)")
                    }
                },
                makeSession: { try AppSession(configuration: .init(location: location, transport: OfflineTransport())) }
            )
        }
        // `AppEnvironment.bootstrap`'s path, over this store and with a server that can't be reached.
        let environment = AppEnvironment.live(
            location: location, defaults: defaults, keychain: InMemoryKeychain(), transport: OfflineTransport())
        environment.settings.serverURL = URL(string: PerfSeed.Spec.standard.baseURL)
        environment.registerIntentTopics()
        return environment
    }
}

/// Process start to Home's first tile on screen, for `-QuickrPerfStore` launches.
@MainActor @Observable final class PerfProbe {
    static let shared = PerfProbe()

    /// Milliseconds from the process's start (the kernel's, so it includes dyld and `main`).
    private(set) var firstRender: Int?

    func tileAppeared() {
        guard firstRender == nil, PerfStore.isRequested, let start = Self.processStart() else { return }
        firstRender = Int((Date().timeIntervalSince(start) * 1_000).rounded())
        print("PERF first render: \(firstRender!) ms")
    }

    private static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
#endif
