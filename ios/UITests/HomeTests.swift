import XCTest

/// The home screen over the debug demo store (`-QuickrDemoStore`: Medication overdue, Water due,
/// Stretch soon, Water the plants later; Headache, Mood, Sleep and Workout unscheduled; Old habit
/// archived).
final class HomeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.section.due"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func tile(_ app: XCUIApplication, _ slug: String) -> XCUIElement {
        app.descendants(matching: .any)["tile.\(slug)"]
    }

    /// Scrolls the list up by about `points` (a slow drag, so it doesn't fling).
    @MainActor
    private func scroll(_ app: XCUIApplication, by points: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -points)))
    }

    /// Due first: the longest overdue, then due, then coming up by next slot, then unscheduled by
    /// recent activity (then, never logged, by last edit). The archived topic is filtered out.
    @MainActor
    func testTheListIsDueFirst() {
        let app = launch()
        let order = ["meds", "water", "stretch", "plants", "headache", "mood", "sleep", "workout"]
        XCTAssertTrue(tile(app, order[0]).waitForExistence(timeout: 5))
        // Rows are lazy: one scrolled far enough off screen is released. So compare each pair
        // while both exist, scrolling a little at a time until the next one appears.
        for (above, below) in zip(order, order.dropFirst()) {
            let a = tile(app, above)
            let b = tile(app, below)
            for _ in 0..<12 where !b.exists { scroll(app, by: 180) }
            XCTAssertTrue(b.exists, "\(below) appears")
            XCTAssertTrue(a.exists, "\(above) is still on screen next to \(below)")
            XCTAssertLessThan(a.frame.minY, b.frame.minY, "\(above) comes before \(below)")
        }
        XCTAssertFalse(tile(app, "old-habit").exists)
        XCTAssertEqual(app.descendants(matching: .any)["home.section.due"].label, "Due now, 2")
        XCTAssertTrue(app.descendants(matching: .any)["home.section.upcoming"].exists)
    }

    /// A tile opens its topic and its Log block opens record, through the router; back returns.
    @MainActor
    func testATileOpensItsTopicAndLogOpensRecord() {
        let app = launch()
        let meds = tile(app, "meds")
        XCTAssertTrue(meds.waitForExistence(timeout: 5))
        meds.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()  // the title, not a control
        // The topic opens on its Overview tab (STATS).
        let tabs = app.segmentedControls["topic.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Overview"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["overview.list"].firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let log = app.buttons["Log Medication"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        log.tap()
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 5), "Log opens the record screen")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSearchMatchesQuestionsAndClears() {
        let app = launch()
        let search = app.textFields["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("naps")  // only Sleep's question help text says it
        XCTAssertTrue(tile(app, "sleep").waitForExistence(timeout: 5))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: tile(app, "meds"))
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any)["home.section.due"].exists, "a search shows one list")
        XCTAssertEqual(app.staticTexts["home.count"].label, "1 topic")

        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "zzz")
        XCTAssertTrue(app.descendants(matching: .any)["home.noMatches"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheArchivedFilterShowsArchivedTopics() {
        let app = launch()
        app.buttons["home.filter"].tap()
        let status = app.segmentedControls["home.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.buttons["Archived"].tap()
        XCTAssertTrue(tile(app, "old-habit").waitForExistence(timeout: 5))
        XCTAssertFalse(tile(app, "meds").exists)
        XCTAssertEqual(app.staticTexts["home.count"].label, "1 archived topic")
    }

    /// With Reduce Motion (QuickrUI's DEBUG `-QuickrReduceMotion`, as the system setting can't be
    /// set from a test), every reduced path still works: the filter panel opens and closes without
    /// its slide, a quick-log chip logs, its toast's Undo undoes, and the search clears.
    @MainActor
    func testReduceMotionKeepsEverythingWorking() {
        let app = launch(AccessibilityLaunch.arguments(contentSize: nil, reduceMotion: true))
        XCTAssertTrue(tile(app, "meds").waitForExistence(timeout: 5))
        app.buttons["home.filter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.status"].waitForExistence(timeout: 5))
        app.buttons["home.filter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.status"].waitForNonExistence(timeout: 5))

        let headache = tile(app, "headache")
        let chip = headache.buttons["chip.severe"]
        for _ in 0..<6 where !chip.isHittable { scroll(app, by: 200) }
        chip.tap()
        let undo = app.buttons["toast.action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 10))

        let search = app.textFields["home.search"]
        for _ in 0..<10 where !search.isHittable { scroll(app, by: -200) }
        search.tap()
        search.typeText("med")
        let clear = app.buttons["home.clearSearch"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44, "a 44 pt target (audit H1)")
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5), "the search is empty again")
    }

    /// At the largest accessibility size the screen still works: sections, tiles, search and the
    /// filter (a menu instead of a segmented control).
    @MainActor
    func testAccessibilityXXXL() throws {
        let app = launch(AccessibilityLaunch.arguments())
        XCTAssertTrue(tile(app, "meds").waitForExistence(timeout: 5))
        XCTAssertTrue(tile(app, "meds").isHittable)
        // The first screenful: header, sections, the first tiles (audit test plan).
        try assertAccessible(app)
        let search = app.textFields["home.search"]
        // Scroll in small steps until the search row is clear of the header (two rows deep at
        // this size), so the filter tap can't land on a header button above it.
        let header = app.buttons["home.settings"]
        func clear() -> Bool { search.frame.minY > header.frame.maxY + 8 && search.frame.maxY < app.frame.maxY - 80 }
        for _ in 0..<20 where !clear() { scroll(app, by: 120) }
        XCTAssertTrue(clear(), "the search row is on screen, below the header")
        app.buttons["home.filter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.status"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// At XXXL the two-row header scrolls with the list instead of staying pinned, so it never
    /// covers the list's controls: after a fling nothing lies under it, and the filter works.
    @MainActor
    func testAtXXXLTheHeaderNeverCoversTheList() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let search = app.textFields["home.search"]
        let filter = app.buttons["home.filter"]
        let header = app.buttons["home.settings"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            scroll(app, by: 150)
            if header.exists && filter.exists {
                XCTAssertFalse(header.frame.intersects(filter.frame), "the header's buttons never sit on the filter")
                XCTAssertLessThan(header.frame.maxY, search.frame.minY, "the header stays above the search row")
            }
        }
        app.swipeUp(velocity: .fast)
        let flung = XCTAttachment(screenshot: app.screenshot())
        flung.name = "home-ax-xxxl-after-fling"
        flung.lifetime = .keepAlways
        add(flung)
        // With real tiles the list at XXXL is many screens long: fling back first, then settle.
        for _ in 0..<10 where !filter.exists { app.swipeDown(velocity: .fast) }
        for _ in 0..<20 where !(filter.exists && filter.isHittable && filter.frame.minY > 60) {
            scroll(app, by: -150)
        }
        filter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.status"].waitForExistence(timeout: 5))
    }

    /// The header's wordmark and sync pill grow with Dynamic Type (bar items wouldn't).
    @MainActor
    func testTheHeaderScalesWithDynamicType() {
        func heights(_ extra: [String]) -> (wordmark: CGFloat, pill: CGFloat) {
            let app = launch(extra)
            defer { app.terminate() }
            let wordmark = app.staticTexts["home.wordmark"]
            let pill = app.buttons["sync.pill"]
            XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
            XCTAssertTrue(pill.waitForExistence(timeout: 10), "the demo store is offline: the pill shows")
            return (wordmark.frame.height, pill.frame.height)
        }
        let normal = heights([])
        let large = heights(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertGreaterThan(large.wordmark, normal.wordmark * 1.5, "the wordmark scales")
        XCTAssertGreaterThan(large.pill, normal.pill * 1.3, "the sync pill scales")
    }
}
