import XCTest

/// R9 (timers.md §13.3): a timed topic's run, against the UI-test fake server's "Morning"
/// (steps Shower, Dress, Breakfast, Teeth; a required Mood question). Start on the tile, then on
/// the run screen Next ×2, Skip, Pause, Resume, Stop; the answers form; Save. The entry shows the
/// segments the fold makes of that history.
@MainActor
final class RunUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Waits until `element`'s label contains `text`.
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }

    /// Waits until `element`'s value is `value`.
    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }

    /// Past the run controls' tap cooldown (450 ms), so the next tap is a new one.
    private func pastCooldown() { Thread.sleep(forTimeInterval: 0.6) }

    func testStartNextNextSkipPauseResumeStopAnswerSave() {
        let app = launch()
        let tile = element(app, "tile.morning")
        XCTAssertTrue(tile.waitForExistence(timeout: 20))

        // Start on the tile: one tap, and the tile's button becomes Next.
        let tileButton = element(app, "tile.morning.run")
        XCTAssertTrue(tileButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(tileButton, containing: "Start"), tileButton.label)
        tileButton.tap()
        XCTAssertTrue(waitForLabel(tileButton, containing: "Next: Dress"), tileButton.label)
        pastCooldown()

        // The tile opens the run screen.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let primary = element(app, "run.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(element(app, "run.step.shower"), "current"))

        primary.tap()  // Next: Dress
        XCTAssertTrue(waitForValue(element(app, "run.step.shower"), "done"))
        XCTAssertTrue(waitForLabel(primary, containing: "Next: Breakfast"), primary.label)
        pastCooldown()

        primary.tap()  // Next: Breakfast
        XCTAssertTrue(waitForValue(element(app, "run.step.breakfast"), "current"))
        pastCooldown()

        let skip = element(app, "run.skip")
        XCTAssertTrue(waitForLabel(skip, containing: "Skip Breakfast (step 3)"), skip.label)
        skip.tap()
        XCTAssertTrue(waitForValue(element(app, "run.step.breakfast"), "skipped"))
        XCTAssertTrue(waitForValue(element(app, "run.step.teeth"), "current"))
        // The last step: the primary button is Stop.
        XCTAssertTrue(waitForLabel(primary, containing: "Stop"), primary.label)
        pastCooldown()

        element(app, "run.pause").tap()
        XCTAssertTrue(element(app, "run.resume").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(element(app, "run.state"), containing: "Paused"))
        pastCooldown()
        element(app, "run.resume").tap()
        XCTAssertTrue(element(app, "run.pause").waitForExistence(timeout: 10))
        pastCooldown()

        primary.tap()  // Stop
        // The version has a required question: the answers form opens; the run is finishing.
        let save = element(app, "runDetails.save")
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        app.buttons["Good"].firstMatch.tap()
        save.tap()

        // Saved: back home, the tile is idle again.
        XCTAssertTrue(waitForLabel(tileButton, containing: "Start", timeout: 15), tileButton.label)

        // The entry: Shower, Dress and Teeth timed, Breakfast skipped, one pause.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        selectTopicTab("Entries", in: app)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'entry.'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "entry.timing").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.segment.0"), containing: "Shower"))
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.segment.1"), containing: "Dress"))
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.segment.2"), containing: "Teeth"))
        XCTAssertFalse(element(app, "entry.timing.segment.3").exists)
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.skipped.0"), containing: "breakfast"))
        XCTAssertFalse(element(app, "entry.timing.skipped.1").exists)
        XCTAssertTrue(element(app, "entry.timing.pause.0").exists)
        XCTAssertFalse(element(app, "entry.timing.pause.1").exists)
    }
}
