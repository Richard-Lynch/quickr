import CryptoKit
import Foundation

/// The entry id a reminder action logs (notifications.md §7.4): derived from the reminder, so one
/// slot logs at most one entry across the app and the PWA, however often its actions are used.
/// The reference is `action_entry_id` in `backend/app/services/notification.py`; the vectors are
/// `shared/fixtures/action-entry-id-vectors.json`.
public enum ActionEntryId {
    /// A UUIDv8 from the first 16 bytes of SHA-256 of
    /// `"quickr-action-entry-v1|" + lower(server_id) + "|" + lower(topic_id) + "|" + due_since`.
    /// `dueSince` is used exactly as the payload carries it, never re-normalised.
    public static func make(serverId: String, topicId: String, dueSince: String) -> UUID {
        let name = "quickr-action-entry-v1|\(asciiLowercased(serverId))|\(asciiLowercased(topicId))|\(dueSince)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// ASCII-only lowercasing, as the spec says (`String.lowercased()` would map other scripts too).
    private static func asciiLowercased(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
    }
}
