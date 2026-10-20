import Foundation

extension Limits {
    // `Limits.serverDefaults` (the server's defaults, the PWA's `FALLBACK_LIMITS`) lives in
    // Models/ServerInfo.swift; a broken server pattern falls back to its pattern.
    var keyMatcher: ServerPattern { ServerPattern(keyPattern, fallback: Self.serverDefaults.keyPattern) }
    var slugMatcher: ServerPattern { ServerPattern(slugPattern, fallback: Self.serverDefaults.slugPattern) }
}
