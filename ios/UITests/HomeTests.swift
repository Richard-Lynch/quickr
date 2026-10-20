import XCTest

/// The home screen over the debug demo store (`-QuickrDemoStore`: Medication overdue, Water due,
/// Stretch soon, Water the plants later, Mood and Sleep unscheduled, Old habit archived).
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

    /// Due first: the longest overdue, then due, then coming up by next slot, then unscheduled by
    /// recent activity. The archived topic is filtered out.
    @MainActor
    func testTheListIsDueFirst() {
        let app = launch()
        let order = ["meds", "water", "stretch", "plants", "mood", "sleep"]
        var previous = -CGFloat.infinity
        for slug in order {
            let element = tile(app, slug)
            if !element.exists { app.swipeUp() }
            XCTAssertTrue(element.waitForExistence(timeout: 5), slug)
            // Scrolling moves everything equally, so compare against the first tile's position.
            let y = element.frame.minY - tile(app, "meds").frame.minY
            XCTAssertGreaterThan(y, previous, "\(slug) comes after the one before it")
            previous = y
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
