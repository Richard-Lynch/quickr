import Foundation

extension Limits {
    // `serverDefaults` (what validation uses until `GET /limits` loads) is in Models/ServerInfo.swift,
    // kept in step with the getLimits fixture there.
    var keyMatcher: ServerPattern { ServerPattern(keyPattern, fallback: Self.serverDefaults.keyPattern) }
    var slugMatcher: ServerPattern { ServerPattern(slugPattern, fallback: Self.serverDefaults.slugPattern) }
}
