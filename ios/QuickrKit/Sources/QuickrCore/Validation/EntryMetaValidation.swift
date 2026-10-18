import Foundation

/// Validation of an entry's metadata (`captured_at`, `source`, `notes`), mirroring
/// `frontend/src/lib/entryMeta.ts` and the server's `EntryCreate` / `EntryUpdate` with the
/// ceilings from `GET /limits`.
public enum EntryMetaValidation {
    /// Why the server would reject a capture time, or nil when it's fine (`capturedAtIssue`).
    public static func capturedAtIssue(_ capturedAt: Date, limits: Limits, now: Date) -> String? {
        if capturedAt < limits.capturedAtMin {
            // The PWA uses the local year, which reads 1999 west of UTC; the limit is a UTC instant.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            return "Can’t be before \(calendar.component(.year, from: limits.capturedAtMin))"
        }
        let hours = limits.capturedAtMaxFutureHours
        if capturedAt > now.addingTimeInterval(TimeInterval(hours) * 3600) {
            return "Can’t be more than \(hours) hours in the future"
        }
        return nil
    }

    /// The trimmed source, or the problem (`sourceSchema`).
    public static func source(_ raw: String, limits: Limits) -> Result<String, AnswerMessage> {
        let value = JSNumber.trim(raw)
        if value.isEmpty { return .failure("Where did this come from? (e.g. phone)") }
        if AnswerValidator.characterCount(value) > limits.maxSourceLength {
            return .failure(AnswerMessage("At most \(limits.maxSourceLength) characters"))
        }
        return .success(value)
    }

    /// The trimmed notes, or the problem (`notesSchema`).
    public static func notes(_ raw: String, limits: Limits) -> Result<String, AnswerMessage> {
        let value = JSNumber.trim(raw)
        if AnswerValidator.characterCount(value) > limits.maxNotesLength {
            return .failure(AnswerMessage("At most \(limits.maxNotesLength) characters"))
        }
        return .success(value)
    }
}
