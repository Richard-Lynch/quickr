import XCTest

// T2-M1 (timers2.md §1.6, §12.3 R22): a Timer v2 published from the builder, then run.
extension BuilderUITests {
    /// R22: Mood (untimed) is made timed with two lap types (Run, Rest), a variable `t` = 1:00 and
    /// an alert on Run at `t/2`, reviewed and published as v2. Its run screen then shows "Run 1",
    /// and after a lap "Rest 1".
    @MainActor
    func testPublishingATimerV2Topic() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://t/mood/edit",
        ]
        app.launch()
        XCTAssertTrue(find("editQuestions.q0.header", in: app).waitForExistence(timeout: 15))

        let timed = app.switches["editQuestions.timed"]
        reveal(timed, in: app)
        XCTAssertTrue(timed.waitForExistence(timeout: 5))
        // The switch itself, at the row's trailing edge.
        timed.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(timed.value as? String, "1")
        XCTAssertTrue(find("editQuestions.noLapTypes", in: app).exists, "no lap types yet")

        // Two lap types.
        press("editQuestions.addLapType", in: app)
        typeInto(app.textFields["editQuestions.lap0.label"], "Run", in: app)
        press("editQuestions.addLapType", in: app)
        typeInto(app.textFields["editQuestions.lap1.label"], "Rest", in: app)
        XCTAssertTrue(find("editQuestions.lap0.key", in: app).label.contains("run"))
        XCTAssertTrue(find("editQuestions.lap1.key", in: app).label.contains("rest"))
        XCTAssertFalse(find("editQuestions.noLapTypes", in: app).exists)

        // A variable.
        press("editQuestions.addVariable", in: app)
        typeInto(app.textFields["editQuestions.variable0.name"], "t", in: app)
        typeInto(app.textFields["editQuestions.variable0.duration"], "1:00", in: app)
        XCTAssertFalse(find("editQuestions.noVariables", in: app).exists)

        // An alert on Run, halfway: t/2 evaluates to 0:30 as it is typed.
        press("editQuestions.lap0.alerts", in: app)
        press("editQuestions.lap0.addAlert", in: app)
        typeInto(app.textFields["editQuestions.lap0.alert0.label"], "Halfway", in: app)
        typeInto(app.textFields["editQuestions.lap0.alert0.at"], "t/2", in: app)
        let result = find("editQuestions.lap0.alert0.result", in: app)
        reveal(result, in: app)
        XCTAssertEqual(result.label, "at 0:30")

        press("editQuestions.review", in: app)
        let headline = find("review.headline", in: app)
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertTrue(headline.label.contains("Ready to publish as v2"), headline.label)
        let publish = app.buttons["review.publish"]
        XCTAssertEqual(publish.label, "Publish v2")
        publish.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "toast.text")
                .matching(NSPredicate(format: "label BEGINSWITH 'Published v2'")).firstMatch
                .waitForExistence(timeout: 10))
        XCTAssertTrue(find("versions.v2", in: app).waitForExistence(timeout: 15))

        // Home: Mood is timed now. Start on its tile, then its run screen.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let tileButton = find("tile.mood.run", in: app)
        XCTAssertTrue(tileButton.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(tileButton, labelContains: "Start"), tileButton.label)
        tileButton.tap()
        XCTAssertFalse(waitUntil(tileButton, labelContains: "Start", timeout: 2), "started: \(tileButton.label)")
        Thread.sleep(forTimeInterval: 0.6)  // past the run controls' tap cooldown
        find("tile.mood", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let segment = find("run.segment", in: app)
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(segment, labelContains: "Run 1"), segment.label)
        let lap = find("run.lap", in: app)
        XCTAssertTrue(lap.waitForExistence(timeout: 5))
        lap.tap()
        XCTAssertTrue(waitUntil(segment, labelContains: "Rest 1"), segment.label)
        XCTAssertTrue(waitUntil(find("run.step.lap.1", in: app), labelContains: "Run 1"))
    }

    // MARK: T2-M1 helpers

    @MainActor
    private func find(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func waitUntil(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }

    /// Scrolls `id` into view and taps it.
    @MainActor
    private func press(_ id: String, in app: XCUIApplication) {
        let target = find(id, in: app)
        reveal(target, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), id)
        target.tap()
    }

    /// Scrolls `field` into view, taps it, types `text` once, then puts the keyboard away.
    @MainActor
    private func typeInto(_ field: XCUIElement, _ text: String, in app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), field.debugDescription)
        field.tap()
        field.typeText(text)
        if app.keyboards.firstMatch.exists { app.navigationBars.firstMatch.tap() }
        XCTAssertEqual(field.value as? String, text)
    }

    /// Drags until `element` exists and is whole on screen (bounded): down the list, then back up
    /// (a row just added sits above the Add button that was tapped).
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func shown() -> Bool { element.exists && element.isHittable && app.frame.contains(element.frame) }
        func drag(up: Bool) {
            let (from, to) = up ? (0.2, 0.55) : (0.45, 0.12)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        // Above the screen's middle (made, but scrolled past): up first.
        let above = element.exists && element.frame.midY < app.frame.midY
        for _ in 0..<10 where !shown() { drag(up: above) }
        for _ in 0..<10 where !shown() { drag(up: !above) }
    }
}
// end T2-M1
