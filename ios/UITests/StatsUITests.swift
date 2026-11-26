import XCTest

/// A topic's Overview against the fake server (`-QuickrUITest`), whose stats and series come from
/// `FakeStats`: Workout has a chip question (Type) and a number (Duration) over six weeks.
final class StatsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The summary and a card per question, with charts; the bucket and range change what loads.
    @MainActor
    func testOverviewShowsTheStatsAndCharts() {
        let app = launch(open: "quickr://t/workout")
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Entries"].exists)
        let type = element(app, "overview.card.type")
        XCTAssertTrue(type.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Most often'")).firstMatch.exists)
        snap(app, "stats-1-overview")

        // The bucket: Week.
        app.segmentedControls["overview.bucket"].buttons["Week"].tap()
        XCTAssertTrue(app.staticTexts["Answers per week"].waitForExistence(timeout: 10))

        // The range: 7 days, then all; the duration card follows.
        app.segmentedControls["overview.range"].buttons["All"].tap()
        let duration = element(app, "overview.card.duration")
        scrollTo(duration, in: app)
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Average per week"].waitForExistence(timeout: 10))
        snap(app, "stats-2-duration")
    }

    /// Offline, a refresh keeps the last answer and says when it was fetched.
    @MainActor
    func testOfflineShowsLastUpdated() {
        let app = launch(open: "quickr://t/workout", extra: ["-QuickrSyncControls"])
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "overview.stale").exists)
        app.buttons["debug.offline"].tap()
        pullToRefresh(app)
        let stale = element(app, "overview.stale")
        XCTAssertTrue(stale.waitForExistence(timeout: 15))
        XCTAssertTrue(stale.label.hasPrefix("Last updated"), stale.label)
        XCTAssertTrue(element(app, "overview.summary").exists, "the cached stats stay")
        // The charts stay too: a refresh SwiftUI ends early doesn't turn them into errors.
        XCTAssertFalse(app.staticTexts["Stats aren't available yet."].exists)
        XCTAssertFalse(app.staticTexts["Stats need a connection."].exists)
        snap(app, "stats-3-offline")

        // Back online: the next refresh is fresh again.
        app.buttons["debug.online"].tap()
        pullToRefresh(app)
        XCTAssertTrue(stale.waitForNonExistence(timeout: 15))
    }

    /// The Entries tab shares the Overview's filters.
    @MainActor
    func testTheRangeIsSharedWithEntries() {
        let app = launch(open: "quickr://t/workout")
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 20))
        app.segmentedControls["overview.range"].buttons["7 days"].tap()
        selectTopicTab("Entries", in: app)
        let range = app.segmentedControls["entries.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        XCTAssertTrue(range.buttons["7 days"].isSelected)
        selectTopicTab("Overview", in: app)
        XCTAssertTrue(app.segmentedControls["overview.range"].buttons["7 days"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["overview.range"].buttons["7 days"].isSelected)
    }

    /// At the largest accessibility size: the tabs and the pickers are menus that grow with the
    /// text (a11y B1), the tabs still switch, and the Overview, its cards and charts pass the
    /// accessibility audit.
    @MainActor
    func testAccessibilityXXXL() throws {
        let app = launch(open: "quickr://t/workout", extra: AccessibilityLaunch.arguments())
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 20))
        // Menus instead of segments, which would truncate.
        XCTAssertTrue(app.buttons["overview.range"].exists)
        XCTAssertTrue(app.buttons["overview.bucket"].exists)
        let tabs = app.buttons["topic.tabs"]
        XCTAssertTrue(tabs.exists, "the tabs are a menu")
        XCTAssertGreaterThanOrEqual(tabs.frame.height, 44)
        XCTAssertEqual(selectedTopicTab(in: app), "Overview")
        snap(app, "stats-4-ax")
        try assertAccessible(app, allowing: StatsAccessibility.known)

        // Each chart, scrolled into view in screen order (scrollTo only swipes up): Type's
        // stacked bars, then Duration's histogram above its line.
        for id in ["chart.stacked", "chart.histogram", "chart.line"] {
            let chart = element(app, id)
            scrollTo(chart, in: app)
            XCTAssertTrue(chart.isHittable, "\(id) is on screen")
            try assertAccessible(app, allowing: StatsAccessibility.known)
        }

        // The tabs switch from the menu.
        selectTopicTab("Entries", in: app)
        XCTAssertEqual(selectedTopicTab(in: app), "Entries")
        selectTopicTab("Overview", in: app)
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 10))
    }

    /// The tiktok timer's lap types (content-display.md §4.1, `-QuickrSeedTypedTopic`'s Intervals,
    /// `FakeLapTypes`): a card per type in the timer's order, with its laps, median, best and mean
    /// over the five runs, and the stacked chart under them; the untyped laps tiles give way.
    @MainActor
    func testLapTypeCards() {
        let app = launch(open: "quickr://t/intervals", extra: ["-QuickrSeedTypedTopic"])
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 20))
        let run = element(app, "overview.timing.laptype.run")
        let rest = element(app, "overview.timing.laptype.rest")
        scrollTo(rest, in: app)
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        XCTAssertTrue(rest.exists)
        for part in ["Run", "12 laps", "1:40", "median", "best 1:10 · mean 1:40"] {
            XCTAssertTrue(run.label.contains(part), "\(part) in \(run.label)")
        }
        for part in ["Rest", "8 laps", "0:40", "median", "best 0:30 · mean 0:40"] {
            XCTAssertTrue(rest.label.contains(part), "\(part) in \(rest.label)")
        }
        XCTAssertLessThanOrEqual(run.frame.minX, rest.frame.minX, "the timer's order")
        XCTAssertLessThanOrEqual(run.frame.minY, rest.frame.minY, "the timer's order")
        let chart = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Time per lap type, per '"))
        XCTAssertTrue(chart.firstMatch.exists, "the stacked chart's caption")
        XCTAssertFalse(element(app, "overview.timing.laps").exists, "no untyped laps tile")
        XCTAssertFalse(element(app, "overview.timing.lapMedian").exists, "no untyped lap median tile")
        snap(app, "stats-5-laptypes")
    }

    /// The activity strip's columns (content-display.md §4.2) over Intervals' five runs
    /// (`FakeLapTypes.runs`): twelve Monday-started weeks, oldest left, each read as "Week of 3 Nov:
    /// 5 entries" for its Monday and its count.
    @MainActor
    func testActivityStripLabels() {
        let app = launch(open: "quickr://t/intervals", extra: ["-QuickrSeedTypedTopic"])
        let caption = element(app, "overview.activity.caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 20))
        XCTAssertEqual(caption.label, "5 entries in the last 12 weeks")
        let expected = Self.weekLabels(runs: [(1, 7), (3, 18), (8, 7), (15, 7), (22, 19)])
        XCTAssertEqual(expected.count, 12)
        for (column, label) in expected.enumerated() {
            XCTAssertEqual(element(app, "overview.activity.week.\(column)").label, label, "column \(column)")
        }
        XCTAssertFalse(element(app, "overview.activity.week.12").exists, "twelve columns")
    }

    // MARK: - Helpers

    /// The strip's twelve column labels for entries logged `daysAgo` days before today's local
    /// midnight plus `hour` (as the fake server places them): the first column is the Monday 11
    /// weeks before this week's, and a Monday is named in no zone ("3 Nov"), as `ActivityStrip`.
    static func weekLabels(runs: [(daysAgo: Int, hour: Int)], now: Date = Date()) -> [String] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)  // 1 is Sunday
        guard let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today),
            let first = calendar.date(byAdding: .day, value: -77, to: monday)
        else { return [] }
        var counts = Array(repeating: 0, count: 12)
        for run in runs {
            guard let day = calendar.date(byAdding: .day, value: -run.daysAgo, to: today),
                let at = calendar.date(byAdding: .hour, value: run.hour, to: day),
                let days = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: at)).day
            else { return [] }
            counts[days / 7] += 1
        }
        let utc = TimeZone(identifier: "UTC")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = utc
        let format = DateFormatter()
        format.locale = .autoupdatingCurrent
        format.timeZone = utc
        format.setLocalizedDateFormatFromTemplate("MMMd")
        return counts.enumerated().compactMap { column, count in
            guard let start = calendar.date(byAdding: .day, value: 7 * column, to: first),
                let name = gregorian.date(from: calendar.dateComponents([.year, .month, .day], from: start))
            else { return nil }
            return "Week of \(format.string(from: name)): \(count) \(count == 1 ? "entry" : "entries")"
        }
    }

    /// A slow drag down from the summary (a quick swipe doesn't trigger the refresh; the pickers
    /// above and the charts below take drags themselves).
    @MainActor
    private func pullToRefresh(_ app: XCUIApplication) {
        let summary = element(app, "overview.summary")
        let start = summary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 400)))
    }

    /// By identifier, whatever its type (a combined element reads as text).
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func launch(open url: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", url] + extra
        app.launch()
        return app
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }
}
