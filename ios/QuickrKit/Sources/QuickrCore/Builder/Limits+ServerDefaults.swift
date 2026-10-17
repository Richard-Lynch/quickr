import Foundation

extension Limits {
    /// The server's defaults (`backend/app/schemas/limits.py`, the PWA's `FALLBACK_LIMITS`): what
    /// validation uses until `GET /limits` has loaded. The server stays the final word either way.
    public static let serverDefaults = Limits(
        keyPattern: "^[a-z][a-z0-9_]{0,62}$", slugPattern: "^[a-z0-9][a-z0-9-]{0,63}$",
        timePattern: "^([01][0-9]|2[0-3]):[0-5][0-9]$", maxQuestions: 100, maxEnumOptions: 200, maxStrLength: 10_000,
        maxLabelLength: 200, maxHelpTextLength: 1_000, maxUnitLength: 32, maxDecimals: 10, maxTopicNameLength: 200,
        maxDescriptionLength: 5_000, maxChangeNoteLength: 2_000, maxSourceLength: 100, maxNotesLength: 5_000,
        maxMetaEntries: 50, maxMetaKeyLength: 64, maxMetaValueLength: 500,
        capturedAtMin: Date(timeIntervalSince1970: 946_684_800), capturedAtMaxFutureHours: 24, scheduleMaxTimes: 24,
        intervalMinMinutes: 15, intervalMaxMinutes: 129_600)

    var keyMatcher: ServerPattern { ServerPattern(keyPattern, fallback: Self.serverDefaults.keyPattern) }
    var slugMatcher: ServerPattern { ServerPattern(slugPattern, fallback: Self.serverDefaults.slugPattern) }
}
