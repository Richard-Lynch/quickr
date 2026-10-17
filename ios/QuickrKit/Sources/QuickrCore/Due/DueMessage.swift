import Foundation

extension Due {
    /// How long after `dueSince` the message stays "Time to log". Exactly this long is "Overdue".
    public static let freshFor: TimeInterval = 30 * 60

    /// The reminder body (the server's `due_message`): "Time to log" for the first 30 minutes, then
    /// "Overdue since …" in the schedule's timezone: `HH:mm` on the same local date, `EEE HH:mm`
    /// within 7 local calendar days, else `dd MMM`. Names are C-locale English, whatever the
    /// device language, so the text matches the server's push body.
    public static func message(for schedule: Schedule, dueSince: Date, now: Date) -> String {
        message(timezone: schedule.timezone, dueSince: dueSince, now: now)
    }

    /// `message(for:dueSince:now:)` for a bare IANA timezone identifier (unknown zones read as UTC).
    public static func message(timezone: String, dueSince: Date, now: Date) -> String {
        if now.timeIntervalSince(dueSince) < freshFor { return "Time to log" }
        let clock = ZoneClock(identifier: timezone) ?? ZoneClock.utc
        let since = clock.civil(at: Int(dueSince.timeIntervalSince1970.rounded(.down)))
        let today = clock.epochDay(at: Int(now.timeIntervalSince1970.rounded(.down)))
        let time = twoDigits(since.hour) + ":" + twoDigits(since.minute)
        if since.epochDay == today { return "Overdue since " + time }
        if today - since.epochDay < 7 {
            return "Overdue since " + weekdayNames[since.isoWeekday - 1] + " " + time
        }
        let date = since.date
        return "Overdue since " + twoDigits(date.day) + " " + monthNames[date.month - 1]
    }

    private static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func twoDigits(_ value: Int) -> String { (value < 10 ? "0" : "") + String(value) }
}
