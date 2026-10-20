import XCTest

/// Quick-log tiles over `DemoStore` (`-QuickrTilesDemo -QuickrDemoStore`). Its server never
/// answers, so every log is queued: the offline path (design loop row g).
final class TileUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrTilesDemo", "-QuickrDemoStore"] + extra
        app.launch()
        return app
    }

    /// Rows a, f and g: one tap logs, the chip confirms, the toast offers Undo, and one tap on
    /// Undo removes the entry again.
    @MainActor
    func testAChipLogsInOneTapAndUndoRemovesTheEntry() {
        let app = launch()
        let tile = app.otherElements["tile.headache"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        XCTAssertTrue(text(in: tile, containing: "Last Mild").waitForExistence(timeout: 10))

        let chip = tile.buttons["chip.moderate"]
        chip.tap()
        // Lit for 1.6 s once the outcome is known (then it reads "Same as last time").
        let lit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'Logged'"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [lit], timeout: 5), .completed, "the chip confirms the log")

        let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.hasPrefix("Logged Moderate"), toast.label)
        XCTAssertTrue(toast.label.contains("saved on this device, will sync"), toast.label)
        XCTAssertTrue(text(in: tile, containing: "Last Moderate").waitForExistence(timeout: 5))
        attach(app, "tiles-logged")

        app.buttons["toast.action"].tap()

        XCTAssertTrue(waitForLabel(app.staticTexts.matching(identifier: "toast.text").firstMatch, prefix: "Undone"))
        XCTAssertTrue(text(in: tile, containing: "Last Mild").waitForExistence(timeout: 5), "Undo removes the entry")
        XCTAssertFalse(text(in: tile, containing: "Last Moderate").exists)
    }

    /// Row b: the stepper starts at the last value, so ✓ alone logs it.
    @MainActor
    func testTheStepperStartsAtTheLastValueSoCheckLogsInOneTap() {
        let app = launch()
        let tile = app.otherElements["tile.water"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        let field = tile.textFields["quick.number"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "3")

        tile.buttons["quick.check"].tap()

        let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.hasPrefix("Logged 3 glasses"), toast.label)
    }

    /// A topic with several required questions has no quick-log; its Log block opens the record
    /// screen, and an archived topic has no Log block at all.
    @MainActor
    func testOnlyQuickLogTopicsGetControlsAndArchivedOnesNoLogBlock() {
        let app = launch()
        let workout = app.otherElements["tile.workout"]
        XCTAssertTrue(workout.waitForExistence(timeout: 15))
        XCTAssertEqual(workout.buttons.matching(identifier: "chip.none").count, 0)
        workout.buttons["Log Workout"].tap()
        XCTAssertEqual(app.staticTexts["tiles.opened"].label, "record workout")

        let old = app.otherElements["tile.old-habit"]
        for _ in 0..<4 where !old.exists { app.swipeUp() }
        XCTAssertTrue(old.waitForExistence(timeout: 5))
        XCTAssertFalse(old.buttons["Log Old habit"].exists)
        XCTAssertTrue(text(in: old, containing: "Archived").exists)
    }

    /// At the largest accessibility text size a chip still logs and the toast's Undo is reachable;
    /// the screen passes the accessibility audit.
    @MainActor
    func testTilesWorkAtAnAccessibilityTextSize() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let tile = app.otherElements["tile.headache"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        attach(app, "tiles-ax")
        try app.performAccessibilityAudit(for: [.dynamicType, .elementDetection, .hitRegion, .sufficientElementDescription])

        let chip = tile.buttons["chip.severe"]
        XCTAssertTrue(chip.isHittable)
        chip.tap()
        let undo = app.buttons["toast.action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.isHittable, "Undo must stay reachable at AX sizes")
    }

    private func text(in element: XCUIElement, containing fragment: String) -> XCUIElement {
        element.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, prefix: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
