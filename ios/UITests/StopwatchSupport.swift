import XCTest

/// A stopwatch topic for the run-surface tests (active-surfaces.md §1.2: an untyped timer with no
/// steps, where Lap is always the primary). The UI-test fake server has none, so this publishes
/// its Workout (untimed, two required questions) as v2 with the Timed switch on and no steps,
/// through the builder, as `TimingUITests.testPublishingATimedTopic` does, and returns home.
extension XCTestCase {
    /// Launches against the fake server (`-QuickrUITest`) with Workout published as a stopwatch;
    /// home is on screen and `tile.workout.run` reads Start.
    @MainActor
    func launchWithStopwatch(_ extra: [String] = [], file: StaticString = #filePath, line: UInt = #line)
        -> XCUIApplication
    {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://t/workout/edit"]
            + extra
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["editQuestions.q0.header"].waitForExistence(timeout: 20),
            "the builder", file: file, line: line)
        let timed = app.switches["editQuestions.timed"]
        stopwatchScroll(to: timed, in: app)
        XCTAssertTrue(timed.waitForExistence(timeout: 5), "editQuestions.timed", file: file, line: line)
        // The switch itself, at the row's trailing edge.
        timed.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(timed.value as? String, "1", "Timed is on", file: file, line: line)
        let review = app.descendants(matching: .any)["editQuestions.review"].firstMatch
        stopwatchScroll(to: review, in: app)
        review.tap()
        let publish = app.buttons["review.publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 10), "review.publish", file: file, line: line)
        publish.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["versions.v2"].waitForExistence(timeout: 15), "published v2",
            file: file, line: line)

        // Home: back out of the topic.
        let search = app.textFields["home.search"]
        for _ in 0..<4 where !search.exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 3) else { break }
            back.tap()
            _ = search.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10), "home", file: file, line: line)
        let start = app.descendants(matching: .any)["tile.workout.run"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "tile.workout.run", file: file, line: line)
        let isStart = NSPredicate(format: "label CONTAINS 'Start'")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: isStart, object: start)], timeout: 10),
            .completed, "Workout is timed now: its tile offers Start, not Log (\(start.label))", file: file, line: line)
        return app
    }

    /// Drags the screen up (a little at a time) until `element` is hittable.
    @MainActor
    private func stopwatchScroll(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
    }
}
