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

    /// While the keyboard is up, Save is in the keyboard's toolbar: one Save, reachable, clear of
    /// Next/Done, before and after the first edit. (A bar of our own above the keyboard slid under
    /// Next/Done once the form changed.)
    @MainActor
    func testSaveIsInTheKeyboardToolbarWhileTyping() {
        let app = launch(open: "quickr://t/workout/record")
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 15))
        duration.tap()
        let advance = app.buttons["form.keyboard.advance"]
        XCTAssertTrue(advance.waitForExistence(timeout: 5))
        func checkSave(_ when: String) {
            let saves = app.buttons.matching(identifier: "record.save")
            XCTAssertEqual(saves.count, 1, when)
            let save = saves.firstMatch
            XCTAssertTrue(save.isHittable, when)
            XCTAssertEqual(save.label, "Save", when)
            XCTAssertGreaterThan(save.frame.minX, advance.frame.maxX, "after Next/Done: \(when)")
            XCTAssertFalse(save.frame.intersects(advance.frame), when)
            // Not covered: on screen, below the field and above the keys.
            XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame), when)
            XCTAssertGreaterThanOrEqual(save.frame.minY, duration.frame.maxY, "below the field: \(when)")
            XCTAssertLessThanOrEqual(save.frame.maxY, app.keyboards.keys["1"].frame.minY, "above the keys: \(when)")
        }
        checkSave("before the edit")
        app.buttons["Swim"].tap()
        duration.tap()
        duration.typeText("45")
        usleep(1_000_000)
        snap(app, "record-keyboard-save")
        checkSave("after the first edit")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.staticTexts["Logged Workout"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(homeNeverAppears(app), "a changed form stays")
        XCTAssertTrue(app.buttons["record.save"].exists)
    }

    /// iOS 26's swipe back from anywhere in the content goes back from a clean form (the control
    /// for the guarded case below).
    @MainActor
    func testAContentSwipeGoesBackFromACleanForm() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 15))
        // Up to three swipes: a synthesized one sometimes starts the pop and lets it snap back. Only
        // here, where a retry can't make the result wrong; "a changed form stays" gets one.
        let home = app.staticTexts["home.wordmark"]
        for _ in 0..<3 where !home.exists {
            contentSwipe(app)
            _ = home.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(home.waitForExistence(timeout: 3), "a clean form goes back")
    }

    /// The content swipe is guarded like the edge swipe: a changed form stays.
    @MainActor
    func testAContentSwipeKeepsAChangedForm() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 15))
        app.buttons["Yoga"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the pick moves on to Duration")
        contentSwipe(app)
        XCTAssertTrue(homeNeverAppears(app), "a changed form stays")
        XCTAssertTrue(app.buttons["record.save"].exists)
    }

    /// A swipe back let go part way (cancelled) leaves the screen as it was, and it still saves.
    @MainActor
    func testACancelledSwipeBackLeavesTheScreenWorking() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Swim"].waitForExistence(timeout: 15))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(homeNeverAppears(app), "still on the record screen")
        XCTAssertTrue(app.buttons["record.save"].isHittable)

        app.buttons["Swim"].tap()
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForKeyboardFocus())
        duration.typeText("30")
        app.buttons["record.save"].tap()
        XCTAssertTrue(app.staticTexts["Logged Workout"].waitForExistence(timeout: 15))
    }

    /// Leaving the record screen gives the swipes back their own delegate; coming back takes them
    /// again: a clean form still swipes back, and a changed one still stays.
    @MainActor
    func testTheSwipeGuardSurvivesLeavingAndComingBack() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()  // a clean form: the system's back
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 5))

        let log = app.buttons["Log Workout"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        log.tap()
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 10))
        swipeBack(app)
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 5), "a clean form swipes back")

        log.tap()
        XCTAssertTrue(app.buttons["Yoga"].waitForExistence(timeout: 10))
        app.buttons["Yoga"].tap()
        swipeBack(app)
        XCTAssertTrue(homeNeverAppears(app), "a changed form stays")
        XCTAssertTrue(app.buttons["record.save"].exists)
    }

    /// At the largest accessibility size, Save is in the keyboard's toolbar while typing (the field
    /// stays in view), and the bar is back to save once the keyboard goes.
    @MainActor
    func testRecordAtAnAccessibilityTextSize() throws {
        let app = launch(open: "quickr://t/workout/record", extra: AccessibilityLaunch.arguments())
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["record.save"].isHittable)
        try assertAccessible(
            app,
            allowing: [
                KnownAccessibilityIssue(
                    "E1", .textClipped, element: "· iOS app",
                    reason: "EntryDetailsSection's one-line summary; slice B fixes it (remove on merge)")
            ])
        app.buttons["Run"].tap()
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForKeyboardFocus())
        duration.typeText("20")
        // While typing, the one Save is in the keyboard's toolbar: the field stays in view.
        XCTAssertEqual(app.buttons.matching(identifier: "record.save").count, 1)
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

    /// A quick rightward flick from 30% of the width (well clear of the edge swipe), at the height
    /// of the first question's label ("Type"): above the keyboard a pick can bring up (a flick on
    /// the keys isn't a swipe back), in any size or orientation. Starting on the label itself (near
    /// the edge) doesn't make a content swipe.
    @MainActor
    private func contentSwipe(_ app: XCUIApplication) {
        let label = app.staticTexts["Type"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        settle(label)
        // Most of the width at the edge swipe's (default) speed: a short fast flick sometimes began
        // the pop but let it go too early, and it snapped back.
        let window = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.width * 0.15, dy: label.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: window.width * 0.85, dy: 0)))
    }

    /// Waits (up to 3 s) until `element` stops moving: a push from a link at launch may still be
    /// animating when the screen's elements first exist, and a swipe then isn't the screen's.
    @MainActor
    private func settle(_ element: XCUIElement) {
        var last = element.frame
        for _ in 0..<20 {
            usleep(150_000)
            let now = element.frame
            if now == last { return }
            last = now
        }
    }

    /// Polls Home for `seconds`: true if it never appeared (a swipe that was refused, or let go).
    @MainActor
    private func homeNeverAppears(_ app: XCUIApplication, within seconds: TimeInterval = 2) -> Bool {
        let home = app.staticTexts["home.wordmark"]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if home.exists { return false }
            usleep(100_000)
        }
        return !home.exists
    }

    @MainActor
    private func swipeBack(_ app: XCUIApplication) {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
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
