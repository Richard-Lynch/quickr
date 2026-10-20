import XCTest

/// The record screen against the fake server (`-QuickrUITest`): Workout (a chip and a number)
/// and Mood (one chip). Each test opens the screen with `-QuickrOpen`, the way a link would.
final class RecordUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordToastAndUndo() {
        let app = launch(open: "quickr://t/workout/record")
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 15))
        snap(app, "record-1-open")
        app.buttons["Run"].tap()
        XCTAssertTrue(duration.waitForKeyboardFocus(), "the pick moves on to Duration")
        snap(app, "record-2-picked")
        duration.typeText("30")
        snap(app, "record-3-typed")
        app.buttons["record.save"].tap()

        // Saved: the screen closes and the toast offers Undo.
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Logged Workout"].waitForExistence(timeout: 5))
        snap(app, "record-4-logged")
        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Undone"].waitForExistence(timeout: 5))
        snap(app, "record-5-undone")
    }

    @MainActor
    func testLogAnotherOffersSameAsLastTime() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Swim"].waitForExistence(timeout: 15))
        let logAnother = app.switches["record.logAnother"]
        scrollTo(logAnother, in: app)
        // On the switch itself (the right edge): tapping the label doesn't flip a toggle.
        logAnother.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(logAnother.value as? String, "1")
        app.buttons["Swim"].tap()
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForKeyboardFocus())
        duration.typeText("45")
        app.buttons["record.save"].tap()

        // Still here, with a fresh form that offers the entry just logged.
        let count = app.descendants(matching: .any).matching(identifier: "record.loggedCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "1 logged")
        XCTAssertFalse(app.staticTexts["form.error.duration"].exists, "a fresh form has no errors")
        let same = app.buttons["form.sameAsLast"]
        XCTAssertTrue(same.waitForExistence(timeout: 5))
        same.tap()
        XCTAssertTrue((duration.value as? String ?? "").hasPrefix("45"))
        app.buttons["record.save"].tap()
        XCTAssertTrue(count.waitForLabel("2 logged"))
    }

    @MainActor
    func testFixModeFromALink() {
        let app = launch(
            open: "quickr://t/workout/record?fix=0f1e2d3c-4b5a-4968-8778-0000000000f1",
            extra: ["-QuickrSeedRejectedEntry"])
        let banner = app.descendants(matching: .any)["record.fixBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars["Fix entry · Workout"].exists)

        // What was sent, with the server's reason on the field.
        let duration = app.textFields["form.field.duration"]
        // The stepper reads its value with the unit ("900 min").
        XCTAssertTrue((duration.value as? String ?? "").hasPrefix("900"), "\(String(describing: duration.value))")
        let error = app.staticTexts["form.error.duration"]
        XCTAssertTrue(error.exists)
        XCTAssertTrue(error.label.contains("600"), error.label)

        duration.tap()
        duration.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "90")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Logged Workout"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testASingleChipTopicSavesOnTap() {
        let app = launch(open: "quickr://t/mood/record")
        XCTAssertTrue(app.buttons["Good"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Tap an answer to log it right away."].exists)
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Logged Mood"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLeavingWithChangesAsksFirst() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 15))
        app.buttons["Yoga"].tap()
        let back = app.buttons["record.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let alert = app.alerts["Discard this entry?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue(app.buttons["Yoga"].exists)
        back.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Discard"].tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 10))
    }

    /// The first edit (which adds the back guard to the navigation bar) keeps the Save bar above
    /// the keyboard's Next/Done: it once dropped under it until something laid the screen out again.
    @MainActor
    func testTheSaveBarStaysAboveTheKeyboardAfterTheFirstEdit() {
        let app = launch(open: "quickr://t/workout/record")
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 15))
        duration.tap()
        let advance = app.buttons["form.keyboard.advance"]
        let save = app.buttons["record.save"]
        XCTAssertTrue(advance.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(save.frame.maxY, advance.frame.minY, "before the edit")

        duration.typeText("4")
        usleep(1_000_000)
        snap(app, "record-first-edit")
        XCTAssertLessThanOrEqual(save.frame.maxY, advance.frame.minY, "after the first edit")
    }

    /// A swipe from the left edge goes back while nothing has changed, and does nothing once the
    /// form has an answer (the back button asks first instead).
    @MainActor
    func testSwipingBackWorksOnlyWithoutChanges() {
        var app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 15))
        swipeBack(app)
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 5), "a clean form swipes back")

        app.terminate()
        app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 15))
        app.buttons["Yoga"].tap()
        swipeBack(app)
        XCTAssertTrue(app.buttons["record.save"].exists, "a changed form stays")
        XCTAssertFalse(app.staticTexts["home.wordmark"].exists)
    }

    /// At the largest accessibility size the Save bar steps aside while the keyboard is up, and
    /// comes back to save.
    @MainActor
    func testRecordAtAnAccessibilityTextSize() {
        let app = launch(
            open: "quickr://t/workout/record",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["record.save"].isHittable)
        app.buttons["Run"].tap()
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForKeyboardFocus())
        duration.typeText("20")
        XCTAssertTrue(app.buttons["record.save"].waitForNonExistence(timeout: 5), "hidden while typing")
        app.buttons["Done"].firstMatch.tap()  // the number pad's toolbar
        let save = app.buttons["record.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "record-ax"
        shot.lifetime = .keepAlways
        add(shot)
        save.tap()
        XCTAssertTrue(app.staticTexts["Logged Workout"].waitForExistence(timeout: 15))
    }

    // MARK: - Helpers

    /// A screenshot kept with the results (the demo GIF is made from them).
    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func launch(open url: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", url] + extra
        app.launch()
        return app
    }

    @MainActor
    private func swipeBack(_ app: XCUIApplication) {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        usleep(800_000)
    }

    /// Drags in the top half (clear of the Save bar) until `element` is hittable.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
    }
}

extension XCUIElement {
    func waitForKeyboardFocus(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
