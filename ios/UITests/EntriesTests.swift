import XCTest

/// Water's entries over the debug demo store, with `-QuickrDemoOutbox`: a refused log and one
/// waiting to sync pinned on top (the refused one first: it was logged first), then the server's
/// entries, newest first, some from a second source ("shortcut").
final class EntriesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrDemoStore", "-QuickrDemoOutbox", "-QuickrOpen", "quickr://t/water/entries"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["entries.count"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func rows(_ app: XCUIApplication, _ prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    @MainActor
    private func count(_ app: XCUIApplication) -> Int {
        Int(app.staticTexts["entries.count"].label.split(separator: " ")[0].replacingOccurrences(of: ",", with: ""))!
    }

    /// Device-only logs pin on top, in the order they were logged; the count says so.
    @MainActor
    func testUnsyncedEntriesPinAboveTheList() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["entries.count"].label.hasSuffix("· 2 not synced yet"))
        let pinned = rows(app, "pending.")
        XCTAssertEqual(pinned.count, 2)
        XCTAssertTrue(pinned.element(boundBy: 0).label.contains("Failed — tap to fix"))
        XCTAssertTrue(pinned.element(boundBy: 0).label.contains("glasses: must be at most 20"))
        XCTAssertTrue(pinned.element(boundBy: 1).label.contains("Waiting to sync"))
        let first = rows(app, "entry.").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(pinned.element(boundBy: 1).frame.maxY, first.frame.minY, "pinned above the list")
    }

    /// Swipe to delete: the entry goes and a toast offers Undo, which brings it back.
    @MainActor
    func testSwipeDeleteThenUndo() {
        let app = launch()
        let before = count(app)
        let first = rows(app, "entry.").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let id = first.identifier
        first.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("\(before - 1) "))
        XCTAssertFalse(app.descendants(matching: .any)[id].exists)

        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["Entry restored"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("\(before) "))
        XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5))
    }

    /// An entry opens its edit screen (a placeholder until EDIT); a refused one opens RECORD's
    /// screen to fix it.
    @MainActor
    func testTappingOpensEditOrFix() {
        let app = launch()
        let path = app.staticTexts["route.path"]
        rows(app, "entry.").firstMatch.tap()
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertTrue(path.label.hasPrefix("/t/water/entries/"), path.label)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // RECORD's screen in fix mode, on the refused log.
        rows(app, "pending.").element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["record.fixBanner"].waitForExistence(timeout: 10))
    }

    /// The source filter narrows the list; the range "All" widens it.
    @MainActor
    func testFilters() {
        let app = launch()
        let thirty = count(app)
        app.segmentedControls["entries.range"].buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("120 "), "every Water entry")
        XCTAssertGreaterThan(120, thirty)
        app.buttons["entries.source"].tap()
        app.buttons["shortcut"].tap()
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("30 "), "every fourth is from a shortcut")
    }

    /// From Home: a tile opens the topic, and its Entries tab shows the list.
    @MainActor
    func testTheEntriesTabFromHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore"]
        app.launch()
        let water = app.descendants(matching: .any)["tile.water"]
        XCTAssertTrue(water.waitForExistence(timeout: 20))
        water.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        let tabs = app.segmentedControls["topic.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["Entries"].tap()
        XCTAssertTrue(app.staticTexts["entries.count"].waitForExistence(timeout: 10))
    }

    /// At the largest accessibility size: rows, filters (a menu) and delete still work.
    @MainActor
    func testAccessibilityXXXL() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["entries.range"].waitForExistence(timeout: 5), "a menu at this size")
        let first = rows(app, "entry.").firstMatch
        for _ in 0..<10 where !(first.exists && first.isHittable) { app.swipeUp() }
        XCTAssertTrue(first.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "entries-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
        first.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
    }
}

extension XCUIElement {
    /// Waits up to 10 s for the label to start with `prefix`.
    func waitForLabelPrefix(_ prefix: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
