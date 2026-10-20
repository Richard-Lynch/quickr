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

    /// At the largest accessibility size the screen still works: sections, tiles, search and the
    /// filter (a menu instead of a segmented control).
    @MainActor
    func testAccessibilityXXXL() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(tile(app, "meds").waitForExistence(timeout: 5))
        XCTAssertTrue(tile(app, "meds").isHittable)
        let search = app.textFields["home.search"]
        for _ in 0..<6 where !search.isHittable { app.swipeUp() }
        XCTAssertTrue(search.isHittable)
        app.buttons["home.filter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.status"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
