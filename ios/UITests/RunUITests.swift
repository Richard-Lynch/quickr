import XCTest

/// R9 (timers.md §13.3): a timed topic's run, against the UI-test fake server's "Morning"
/// (steps Shower, Dress, Breakfast, Teeth; a required Mood question). Start on the tile, then on
/// the run screen Next ×2, Skip (from the More menu), Pause, Resume, Stop; the answers form; Save.
/// The entry shows the segments the fold makes of that history. And the run screen's controls on a
/// stopwatch (active-surfaces.md §2): the hero Lap, the secondaries, nothing twice.
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

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A stopwatch (Workout, timed with no steps: `launchWithStopwatch`) on the run screen
    /// (active-surfaces.md §2.1, §2.2): Lap is the primary, full width and at least 72 pt tall;
    /// Stop and Pause are the 56 pt secondaries under it; Lap shows once, never again in the lap
    /// table. Then Lap, and Stop opens the answers form (Workout's questions are required).
    func testLapIsPrimaryWithChunkyControls() {
        let app = launchWithStopwatch()
        let tileButton = element(app, "tile.workout.run")
        tileButton.tap()
        // Started: the card in "Active now" offers Lap (§3.2).
        XCTAssertTrue(waitForLabel(tileButton, containing: "Lap"), tileButton.label)
        pastCooldown()
        element(app, "tile.workout").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()

        let primary = element(app, "run.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(primary, containing: "Lap"), primary.label)
        XCTAssertTrue(waitForValue(element(app, "run.step.lap.1"), "current"))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(primary.frame.height, 72, "the hero primary is at least 72 pt tall")
        XCTAssertGreaterThan(primary.frame.width, window.width * 0.8, "the primary is full width")

        // Stop and Pause: secondaries under the primary, side by side, 56 pt, Stop first.
        let stop = element(app, "run.stop")
        let pause = element(app, "run.pause")
        XCTAssertTrue(stop.exists && pause.exists)
        XCTAssertTrue(stop.label.contains("Stop"), stop.label)
        XCTAssertFalse(primary.label.contains("Stop"), "Stop is never the primary (§1.2)")
        for secondary in [stop, pause] {
            XCTAssertGreaterThanOrEqual(secondary.frame.height, 56, secondary.identifier)
            XCTAssertLessThan(secondary.frame.height, primary.frame.height, secondary.identifier)
            XCTAssertGreaterThanOrEqual(secondary.frame.minY, primary.frame.maxY, "\(secondary.identifier) is under")
        }
        XCTAssertEqual(stop.frame.minY, pause.frame.minY, accuracy: 1, "one row")
        XCTAssertLessThan(stop.frame.minX, pause.frame.minX, "Stop, then Pause")

        // No duplicate (§2.2): one Lap button on the screen; the table's rows are not controls.
        let lapButtons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lap'"))
        XCTAssertEqual(lapButtons.count, 1, "Lap shows once: \(lapButtons.allElementsBoundByIndex.map(\.label))")
        let lapRow = element(app, "run.step.lap.1")
        XCTAssertGreaterThanOrEqual(lapRow.frame.minY, stop.frame.maxY, "the table is under the controls")
        assertNoControlsInTable(app, below: stop)
        snap(app, "run-lap-primary")

        // Lap: the lap closes and the next opens; the primary is still Lap.
        primary.tap()
        XCTAssertTrue(waitForValue(element(app, "run.step.lap.1"), "done"))
        XCTAssertTrue(waitForValue(element(app, "run.step.lap.2"), "current"))
        XCTAssertTrue(waitForLabel(primary, containing: "Lap"), primary.label)
        XCTAssertEqual(lapButtons.count, 1, "still once")
        assertNoControlsInTable(app, below: stop)
        pastCooldown()

        // Pause (§1.2 row 8): Resume replaces Pause; Lap stays the primary, enabled, once.
        pause.tap()
        let resume = element(app, "run.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertFalse(pause.exists, "Resume replaces Pause")
        XCTAssertTrue(waitForLabel(element(app, "run.state"), containing: "Paused"))
        XCTAssertTrue(waitForLabel(primary, containing: "Lap"), primary.label)
        XCTAssertTrue(primary.isEnabled, "a lap while paused is valid")
        XCTAssertEqual(lapButtons.count, 1, "still once while paused")
        pastCooldown()
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pastCooldown()

        // Stop: the run is finishing and its answers form opens.
        stop.tap()
        XCTAssertTrue(element(app, "runDetails.save").waitForExistence(timeout: 10), "the answers form")
        snap(app, "run-stopped-details")
    }

    /// At the largest accessibility text size (§2.3) on Morning (the stacking doesn't depend on
    /// the primary's kind): the primary keeps its 72 pt, the secondaries stack full width under
    /// it, Stop over Pause, and every control can be tapped.
    func testRunControlsStackAtAnAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://t/morning/run"]
            + AccessibilityLaunch.arguments()
        app.launch()
        let start = element(app, "run.start")
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let primary = element(app, "run.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(primary, containing: "Next"), primary.label)
        let stop = element(app, "run.stop")
        let pause = element(app, "run.pause")
        XCTAssertTrue(stop.waitForExistence(timeout: 10) && pause.exists)
        bringIntoFullView([primary, stop, pause], in: app)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(primary.frame.height, 72)
        XCTAssertGreaterThanOrEqual(stop.frame.minY, primary.frame.maxY, "Stop under the primary")
        XCTAssertGreaterThanOrEqual(pause.frame.minY, stop.frame.maxY, "Pause stacked under Stop")
        for control in [primary, stop, pause] {
            XCTAssertGreaterThan(control.frame.width, window.width * 0.8, "\(control.identifier) is full width")
            XCTAssertTrue(control.isHittable, control.identifier)
        }
        snap(app, "run-controls-xxxl")
        pastCooldown()
        pause.tap()
        XCTAssertTrue(element(app, "run.resume").waitForExistence(timeout: 10), "the stacked Pause works")
    }

    /// No control sits in the step and lap table (§2.2): its rows (`run.step.*`, each one
    /// accessibility element) are below the secondaries, no button overlaps any of them, and there
    /// is no `run.lap` anywhere. The stopwatch's table is a couple of rows, all on screen.
    private func assertNoControlsInTable(
        _ app: XCUIApplication, below secondary: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'run.step.'"))
            .allElementsBoundByIndex.map(\.frame)
        XCTAssertFalse(rows.isEmpty, "the table's rows", file: file, line: line)
        for row in rows {
            XCTAssertGreaterThanOrEqual(
                row.minY, secondary.frame.maxY, "rows under the controls", file: file, line: line)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(row), "row \(row) on screen", file: file, line: line)
        }
        let inTable = app.buttons.allElementsBoundByIndex.filter { button in
            rows.contains { $0.intersects(button.frame) }
        }
        XCTAssertEqual(inTable.map(\.identifier), [], "buttons in the table", file: file, line: line)
        XCTAssertFalse(element(app, "run.lap").exists, "no run.lap control", file: file, line: line)
    }

    /// #239: Start on Morning's tile the moment it exists after launch, with no settle wait. The
    /// fake server answers the connect's feed request and holds every later one
    /// (`-QuickrHoldLaterFeed`), so the launch's next pull is still in flight at the tap however
    /// fast or slow the machine is. One tap starts the run: the local view shows it at once.
    func testStartTheMomentTheTileShows() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrHoldLaterFeed"]
        app.launch()
        let tileButton = element(app, "tile.morning.run")
        XCTAssertTrue(tileButton.waitForExistence(timeout: 20))
        tileButton.tap()
        XCTAssertTrue(waitForLabel(tileButton, containing: "Next: Dress"), tileButton.label)
    }

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

        // Skip sits in the More menu (active-surfaces.md §2.2).
        element(app, "run.menu").tap()
        let skip = element(app, "run.skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(skip, containing: "Skip Breakfast"), skip.label)
        skip.tap()
        XCTAssertTrue(waitForValue(element(app, "run.step.breakfast"), "skipped"))
        XCTAssertTrue(waitForValue(element(app, "run.step.teeth"), "current"))
        // The last step: the primary button is Lap; Stop is never primary (§1.2).
        XCTAssertTrue(waitForLabel(primary, containing: "Lap"), primary.label)
        pastCooldown()

        element(app, "run.pause").tap()
        XCTAssertTrue(element(app, "run.resume").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(element(app, "run.state"), containing: "Paused"))
        pastCooldown()
        element(app, "run.resume").tap()
        XCTAssertTrue(element(app, "run.pause").waitForExistence(timeout: 10))
        pastCooldown()

        element(app, "run.stop").tap()
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
        // The row itself, not its `entry.<id>.summary`/`.timing` children.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier MATCHES %@", "^entry\\.[0-9a-fA-F-]{36}$")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "entry.timing").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.segment.0"), containing: "Shower"))
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.segment.1"), containing: "Dress"))
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.segment.2"), containing: "Teeth"))
        XCTAssertFalse(element(app, "entry.timing.segment.3").exists)
        XCTAssertTrue(waitForLabel(element(app, "entry.timing.skipped.0"), containing: "Breakfast"))
        XCTAssertFalse(element(app, "entry.timing.skipped.1").exists)
        XCTAssertTrue(element(app, "entry.timing.pause.0").exists)
        XCTAssertFalse(element(app, "entry.timing.pause.1").exists)
    }
}
