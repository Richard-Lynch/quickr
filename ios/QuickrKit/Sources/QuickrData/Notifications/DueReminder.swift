#if DEBUG
import Foundation
import QuickrCore

/// DEBUG only, for the milestone screenshots (`-QuickrDemoNotify`): a due reminder built on the
/// device as the scheduler and `apns.render` build the push (notifications.md §2), delivered as a
/// local notification so the simulator shows what a real reminder looks like and its actions log
/// through the real handler. Checked against shared/fixtures/apns-payload-vectors.json.
///
/// It stands in for a push, so `quickr.origin` stays remote (a §11 local fallback would say
/// local), and it plays the default sound as the push does. The push's other delivery settings
/// (`mutable-content`, `relevance-score`) have no local equivalent and are left out.
public enum DueReminder {
    /// `apns.MAX_TITLE_LENGTH`: the title is cut to this many Unicode scalars, "…" included.
    public static let maxTitleLength = 120

    /// The reminder `apns.render` would send for this topic and slot. `category` is the topic's
    /// (nil when it isn't quick-loggable: no actions, a tap opens the record screen).
    public static func request(
        serverId: String, topicId: String, topicSlug: String, title: String, body: String, version: Int,
        dueSince: Date, category: NotificationCategory?, fireDate: Date? = nil
    ) -> LocalNotificationRequest {
        let slot = canonical(dueSince)
        return LocalNotificationRequest(
            id: "due-\(topicId)-\(slot)", title: cut(title, to: maxTitleLength),
            body: body + (category?.bodySuffix ?? ""), categoryIdentifier: category?.id,
            threadIdentifier: "topic-\(topicId)",
            quickr: QuickrNotificationInfo(
                kind: "due", serverId: serverId, topicId: topicId, topicSlug: topicSlug, version: version,
                dueSince: slot, url: "/t/\(topicSlug)/record", quickLog: category?.descriptor),
            fireDate: fireDate, sound: true)
    }

    /// The reminder for `topic` at `now`, as the scheduler's tick would build it: the slot and the
    /// body from the due port (`Due.status`, `Due.message`). A topic that isn't due (or has no
    /// schedule) gets a fresh slot at `now`, so any topic can be shown.
    public static func request(
        serverId: String, topic: Topic, category: NotificationCategory?, now: Date, fireDate: Date? = nil
    ) -> LocalNotificationRequest {
        var dueSince = now
        if let schedule = topic.schedule,
            let since = Due.status(
                of: schedule, now: now, lastEntryAt: topic.lastCapturedAt,
                scheduleSince: topic.scheduleUpdatedAt ?? topic.createdAt, archived: topic.status == .archived
            ).dueSince
        {
            dueSince = since
        }
        let body = Due.message(timezone: topic.schedule?.timezone ?? "UTC", dueSince: dueSince, now: now)
        return request(
            serverId: serverId, topicId: topic.id.wireString, topicSlug: topic.slug, title: topic.name, body: body,
            version: topic.currentVersion, dueSince: dueSince, category: category, fireDate: fireDate)
    }

    /// `canonical_instant`: UTC, truncated to whole seconds, with a `Z`.
    static func canonical(_ date: Date) -> String {
        let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        return Date.ISO8601FormatStyle().format(whole)  // UTC, no fractions: 2026-10-21T08:00:00Z
    }

    /// `truncate`: at most `limit` Unicode scalars, the last one "…" when cut.
    static func cut(_ text: String, to limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        var cut = String.UnicodeScalarView(scalars.prefix(limit - 1))
        cut.append("…")
        return String(cut)
    }
}
#endif
