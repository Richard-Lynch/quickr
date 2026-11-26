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
        let app = launch(AccessibilityLaunch.arguments())
        XCTAssertTrue(app.descendants(matching: .any)["tile.water"].waitForExistence(timeout: 20))
        attach(app, "tiles-ax")
        // The first screenful: the due tiles, a number quick-log and its ✓.
        // TILES audits its tiles; issues elsewhere on the home screen are HOME's.
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tile.'"))
            .allElementsBoundByIndex.map(\.frame)
        try assertAccessible(app, within: tiles)

        let headache = tile(app, "headache")
        let chip = headache.buttons["chip.severe"]
        reveal(chip, in: app)
        XCTAssertTrue(chip.isHittable)
        chip.tap()
        let undo = app.buttons["toast.action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.isHittable, "Undo must stay reachable at AX sizes")
    }

    /// The active card's inline controls (active-surfaces.md §3.2), on a stopwatch against the
    /// UI-test fake server (`launchWithStopwatch`; the demo store has no timed topic): started,
    /// the card offers Lap with Stop beside it and Pause; Lap records a lap right there, on home;
    /// Stop stops the run from home (Workout's required questions open its answers form).
    @MainActor
    func testActiveCardInlineLapAndStop() {
        let app = launchWithStopwatch()
        let element = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        element("tile.workout.run").tap()

        let card = element("tile.workout")
        let lap = card.descendants(matching: .any)["tile.workout.run"].firstMatch
        let stop = card.descendants(matching: .any)["tile.workout.stop"].firstMatch
        XCTAssertTrue(element("home.section.active").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(lap, prefix: "Lap"), lap.label)
        XCTAssertTrue(stop.exists)
        XCTAssertTrue(stop.label.hasPrefix("Stop"), stop.label)
        XCTAssertTrue(card.descendants(matching: .any)["tile.workout.pause"].firstMatch.exists)
        // Inline: the primary fills the row, Stop sits beside it.
        XCTAssertEqual(lap.frame.midY, stop.frame.midY, accuracy: 2, "one row")
        XCTAssertLessThan(lap.frame.maxX, stop.frame.minX + 1, "Lap, then Stop")
        XCTAssertGreaterThan(lap.frame.width, stop.frame.width, "the primary takes the row")
        // The headline badge's text (its icon carries the badge's id too, labelled "Timer").
        func headline(_ text: String) -> XCUIElement {
            card.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == 'run.status' AND label CONTAINS %@", text)
            ).firstMatch
        }
        XCTAssertTrue(headline("Lap 1").exists, "the headline names the open lap")
        XCTAssertFalse(headline("Lap 2").exists)
        attach(app, "tiles-active-card")

        Thread.sleep(forTimeInterval: 0.6)  // past the run controls' tap cooldown (450 ms)
        lap.tap()
        // A lap, on home: the headline counts it and the card stays (no run screen).
        XCTAssertTrue(headline("Lap 2").waitForExistence(timeout: 10), "the headline counts the lap")
        XCTAssertTrue(app.textFields["home.search"].exists, "still on home")
        XCTAssertFalse(element("run.primary").exists, "the run screen didn't open")
        XCTAssertTrue(waitForLabel(lap, prefix: "Lap"), "the primary is still Lap: \(lap.label)")
        attach(app, "tiles-active-card-lapped")

        Thread.sleep(forTimeInterval: 0.6)
        stop.tap()
        XCTAssertTrue(element("runDetails.save").waitForExistence(timeout: 10), "stopped: the answers form")
    }

    /// The active card at the largest accessibility text size (§3.2, §7), on Morning against the
    /// UI-test fake server: Pause moves under the headline and the primary stacks over a
    /// full-width Stop; both can be tapped.
    @MainActor
    func testActiveCardStacksAtAnAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test"] + AccessibilityLaunch.arguments()
        app.launch()
        let element = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        let start = element("tile.morning.run")
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        reveal(start, in: app)
        start.tap()

        // Started, Morning moves up into "Active now", above where the list was scrolled to.
        let active = element("home.section.active")
        XCTAssertTrue(active.waitForExistence(timeout: 10))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<12 where !(active.exists && active.isHittable) {
            top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 300)))
        }
        let card = element("tile.morning")
        let next = card.descendants(matching: .any)["tile.morning.run"].firstMatch
        let stop = card.descendants(matching: .any)["tile.morning.stop"].firstMatch
        let pause = card.descendants(matching: .any)["tile.morning.pause"].firstMatch
        XCTAssertTrue(waitForLabel(next, prefix: "Next"), next.label)
        // Home has no navigation bar (its header is in the list): scroll until Stop can be tapped.
        reveal(stop, in: app)
        XCTAssertGreaterThanOrEqual(stop.frame.minY, next.frame.maxY, "Stop stacks under the primary")
        XCTAssertEqual(stop.frame.width, next.frame.width, accuracy: 2, "both full width")
        XCTAssertLessThan(pause.frame.maxY, next.frame.minY, "Pause sits above the controls row")
        XCTAssertTrue(next.isHittable && stop.isHittable)
        attach(app, "tiles-active-card-ax")
        Thread.sleep(forTimeInterval: 0.6)  // past the run controls' tap cooldown (450 ms)
        stop.tap()
        XCTAssertTrue(element("runDetails.save").waitForExistence(timeout: 10), "the stacked Stop works")
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
