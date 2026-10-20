import XCTest

/// Quick-log tiles on the home screen over `DemoStore` (`-QuickrDemoStore`). Its transport is
/// always offline, so every log is queued: the offline path (design loop row g).
@MainActor
final class TileUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore"] + extra
        app.launch()
        return app
    }

    /// Rows a, f and g: one tap logs, the chip confirms, the toast offers Undo, and one tap on
    /// Undo removes the entry again.
    @MainActor
    func testAChipLogsInOneTapAndUndoRemovesTheEntry() {
        let app = launch()
        let headache = tile(app, "headache")
        XCTAssertTrue(headache.waitForExistence(timeout: 15))
        XCTAssertTrue(text(in: headache, containing: "Last Mild").waitForExistence(timeout: 10))

        let chip = headache.buttons["chip.moderate"]
        reveal(chip, in: app)
        chip.tap()
        // Lit for 1.6 s once the outcome is known (then it reads "Same as last time"): too short
        // for an expectation's polling, so look often.
        XCTAssertTrue(sees(chip, valueContaining: "Logged", within: 5), "the chip confirms the log")

        let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.hasPrefix("Logged Moderate"), toast.label)
        XCTAssertTrue(toast.label.contains("saved on this device, will sync"), toast.label)
        XCTAssertTrue(text(in: headache, containing: "Last Moderate").waitForExistence(timeout: 5))
        attach(app, "tiles-logged")

        app.buttons["toast.action"].tap()

        XCTAssertTrue(waitForLabel(app.staticTexts.matching(identifier: "toast.text").firstMatch, prefix: "Undone"))
        XCTAssertTrue(
            text(in: headache, containing: "Last Mild").waitForExistence(timeout: 5), "Undo removes the entry")
        XCTAssertFalse(text(in: headache, containing: "Last Moderate").exists)
    }

    /// Row b: the stepper starts at the last value, so ✓ alone logs it.
    @MainActor
    func testTheStepperStartsAtTheLastValueSoCheckLogsInOneTap() {
        let app = launch()
        let water = tile(app, "water")
        XCTAssertTrue(water.waitForExistence(timeout: 15))
        let field = water.textFields["quick.number"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "3")

        let check = water.buttons["quick.check"]
        XCTAssertEqual(check.label, "Log 3 glasses")
        check.tap()

        let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.hasPrefix("Logged 3 glasses"), toast.label)
    }

    /// A topic with several required questions has no quick-log, only its Log block.
    @MainActor
    func testOnlyQuickLogTopicsGetControls() {
        let app = launch()
        let workout = tile(app, "workout")
        XCTAssertTrue(workout.waitForExistence(timeout: 15))
        XCTAssertEqual(workout.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chip.'")).count, 0)
        XCTAssertFalse(workout.textFields["quick.number"].exists)
        XCTAssertTrue(workout.buttons["Log Workout"].isHittable)
        XCTAssertTrue(text(in: workout, containing: "No entries yet").exists)
    }

    /// At the largest accessibility text size a chip still logs and the toast's Undo is reachable;
    /// the screen passes the accessibility audit.
    @MainActor
    func testTilesWorkAtAnAccessibilityTextSize() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.descendants(matching: .any)["tile.water"].waitForExistence(timeout: 20))
        attach(app, "tiles-ax")
        // The first screenful: the due tiles, a number quick-log and its ✓.
        // TILES audits its tiles; issues elsewhere on the home screen are HOME's.
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tile.'"))
            .allElementsBoundByIndex.map(\.frame)
        try app.performAccessibilityAudit(for: [
            .dynamicType, .elementDetection, .hitRegion, .sufficientElementDescription,
        ]) { issue in
            guard let frame = issue.element?.frame else { return false }
            return !tiles.contains { $0.contains(frame) }
        }

        let headache = tile(app, "headache")
        let chip = headache.buttons["chip.severe"]
        reveal(chip, in: app)
        XCTAssertTrue(chip.isHittable)
        chip.tap()
        let undo = app.buttons["toast.action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.isHittable, "Undo must stay reachable at AX sizes")
    }

    /// A tile, scrolled fully into view: the home list is lazy, so a tile further down doesn't
    /// exist until it is scrolled to.
    private func tile(_ app: XCUIApplication, _ slug: String) -> XCUIElement {
        let element = app.descendants(matching: .any)["tile.\(slug)"]
        let window = app.windows.firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["tile.meds"].waitForExistence(timeout: 20), "the home list")
        // Until its top is on screen: at accessibility sizes a tile can be taller than the window.
        for _ in 0..<10
        where !(element.exists && window.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.minY + 1))) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "tile.\(slug)")
        return element
    }

    /// Scrolls (a little at a time) until `element` can be tapped.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        for _ in 0..<8 where !element.isHittable { start.press(forDuration: 0.05, thenDragTo: end) }
    }

    /// Polls every 0.1 s: true once `element`'s value contains `fragment`.
    private func sees(_ element: XCUIElement, valueContaining fragment: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (element.value as? String)?.contains(fragment) == true { return true }
            usleep(100_000)
        }
        return false
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
