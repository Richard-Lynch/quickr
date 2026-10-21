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

        // Each chart, scrolled into view in screen order (scrollTo only swipes up): the stacked
        // bars, then the histogram above the line.
        for prefix in ["Type: answers per", "Histogram of Duration", "Duration: average per"] {
            let chart = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            scrollTo(chart, in: app)
            XCTAssertTrue(chart.isHittable, "\(prefix) is on screen")
            try assertAccessible(app, allowing: StatsAccessibility.known)
        }

        // The tabs switch from the menu.
        selectTopicTab("Entries", in: app)
        XCTAssertEqual(selectedTopicTab(in: app), "Entries")
        selectTopicTab("Overview", in: app)
        XCTAssertTrue(element(app, "overview.summary").waitForExistence(timeout: 10))
    }

    // MARK: - Helpers

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
