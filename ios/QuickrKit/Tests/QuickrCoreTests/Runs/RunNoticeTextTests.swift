import Foundation
import QuickrCore
import Testing

/// The §11.4 notice texts (timers.md), as the PWA's `noticeFor`.
@Suite struct RunNoticeTextTests {
    private let locale = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    private func text(_ tap: RunEventType, _ reason: VoidReason, stoppedAt: Int? = nil) -> String? {
        RunNoticeText.text(
            topic: "Dishwasher", tap: tap, reason: reason, stoppedAt: stoppedAt, locale: locale, timeZone: utc)
    }

    @Test func afterStopNamesTheTimeAndTheTap() {
        // 2026-10-24 08:15:00 UTC.
        let stopped = 1_792_829_700_000
        // The clock time is the locale's (its digits and separators vary by ICU version).
        let withTime = text(.next, .afterStop, stoppedAt: stopped) ?? ""
        #expect(withTime.hasPrefix("Dishwasher was already stopped at "))
        #expect(withTime.contains("8:15"))
        #expect(withTime.hasSuffix(", so your Next wasn’t added."))
        let lap = text(.lap, .afterStop, stoppedAt: stopped) ?? ""
        #expect(lap.hasSuffix(", so your Lap wasn’t added."))
        let noTime: String? = text(.next, .afterStop)
        #expect(noTime == "Dishwasher was already stopped, so your Next wasn’t added.")
    }

    @Test func runEditedNamesTheTap() {
        let skip: String? = text(.skip, .runEdited)
        #expect(skip == "Dishwasher’s times were edited, so your Skip wasn’t added.")
        let finish: String? = text(.finish, .runEdited)
        #expect(finish == "Dishwasher’s times were edited, so your details wasn’t added.")
    }

    @Test func deletedAndClosed() {
        let deleted: String? = text(.next, .entryDeleted)
        #expect(deleted == "Dishwasher’s run was deleted.")
        let closed: String? = text(.stop, .alreadyClosed)
        #expect(closed == "Dishwasher was already stopped.")
    }

    @Test func doubleTapsAreSilent() {
        for reason in [VoidReason.stale, .merged, .alreadyPaused, .notPaused] {
            let silent: String? = text(.next, reason)
            #expect(silent == nil, "\(reason)")
        }
    }
}
