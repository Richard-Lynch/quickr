#if DEBUG
import Foundation
import QuickrData
import os

/// `-QuickrDProbe d8|d9` (DEBUG only): checkpoint D's category probe from the app's side
/// (`DeviceProbe`; docs/ios/demo/DEVICE-DAY.md D8, D9). A normal launch never runs it.
///
/// - `d9`: times the app's registrations, then writes the request the NSE takes on the next test
///   push, so the two sides never overlap.
/// - `d8`: writes the request at once, then waits (up to 3 minutes) for the NSE, which a test push
///   starts, and drives the rounds. Keep the app in front while it runs.
///
/// Results go to the App Group's `Library/quickr/dprobe/results.jsonl`.
enum DeviceProbeLaunch {
    static let argument = "-QuickrDProbe"
    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "dprobe")

    static func startIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count,
            let kind = DeviceProbe.Kind(rawValue: arguments[index + 1])
        else { return }
        guard let location = try? StoreLocation.appGroup("group.com.bahumia.quickr") else {
            log.error("dprobe: no App Group container")
            return
        }
        let files = DeviceProbe.Files(location: location)
        let request = DeviceProbe.Request(kind: kind)
        let center = SystemNotificationCenter()
        let runner = DeviceProbeRunner(files: files, process: .app, center: center) {
            await DeviceProbe.restore(location: location, center: center)
        }
        log.notice("dprobe \(kind.rawValue, privacy: .public) run \(request.run, privacy: .public) starting")
        Task.detached {
            do {
                if kind == .d8 { try files.write(request) }
                await runner.run(request)
                if kind == .d9 { try files.write(request) }
                log.notice("dprobe \(kind.rawValue, privacy: .public): the app's side is done")
            } catch {
                log.error("dprobe: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
#endif
