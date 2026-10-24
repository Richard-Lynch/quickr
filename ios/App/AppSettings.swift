import Foundation
import Observation

/// The App Group shared by the app and both extensions (PLAN §2, Targets).
enum AppGroup {
    static let identifier = "group.com.bahumia.quickr"

    /// The shared defaults suite. Falls back to the standard defaults when the App Group isn't
    /// available (an unsigned build), so the app still launches.
    static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }

    /// `<AppGroup>/Library/quickr`, or Application Support when the App Group isn't available.
    static var storeDirectory: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return container.appendingPathComponent("Library/quickr", isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("quickr", isDirectory: true)
    }
}

/// User settings in the shared defaults suite, so the extensions read the same values. SETTINGS
/// adds the rest (Cloudflare credentials live in the Keychain, not here).
@MainActor @Observable
final class AppSettings {
    static let serverURLKey = "serverURL"
    static let logAnotherKey = "logAnother"
    static let liveActivitiesKey = "liveActivities"

    @ObservationIgnored private let defaults: UserDefaults

    /// The quickR server's base URL; nil until the user sets one.
    var serverURL: URL? {
        didSet { defaults.set(serverURL?.absoluteString, forKey: Self.serverURLKey) }
    }

    /// The record screen's "Log another": stay after saving, with a fresh form (remembered, like
    /// the PWA's).
    var logAnother: Bool {
        didSet { defaults.set(logAnother, forKey: Self.logAnotherKey) }
    }

    /// Settings ▸ Notifications ▸ Live Activities (timers.md §10.3): on by default.
    var liveActivities: Bool {
        didSet { defaults.set(liveActivities, forKey: Self.liveActivitiesKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: Self.serverURLKey).flatMap(URL.init(string:))
        logAnother = defaults.bool(forKey: Self.logAnotherKey)
        liveActivities = defaults.object(forKey: Self.liveActivitiesKey) as? Bool ?? true
    }
}
