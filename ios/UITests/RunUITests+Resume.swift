import XCTest

// M2-RESUME (active-surfaces.md §3.2, §2.4; timers2.md R21): the stop toast's Resume, against the
// UI-test fake server's "TikTok" (`-QuickrSeedTikTok`: no steps, lap types Run and Rest, no
// questions, so Stop saves at once and the toast says "Saved TikTok: 0:07").
extension RunUITests {
    /// Lap, Stop: the toast offers Resume; Resume reopens the run where the stop left it (Running,
    /// in Rest 1), and the stop-to-resume gap is a pause: after a second Stop the entry's timing
    /// lists it as a pause row.
    func testStopToastOffersResume() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTikTok"]
        app.launch()
        let find = { (id: String) in app.descendants(matching: .any)[id].firstMatch }

        // Start on the tile, then its run screen; one lap.
        let tileButton = find("tile.tiktok.run")
        XCTAssertTrue(tileButton.waitForExistence(timeout: 20))
        XCTAssertTrue(resumeWait(tileButton, containing: "Start"), tileButton.label)
        tileButton.tap()
        resumeCooldown()
        find("tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let segment = find("run.segment")
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        XCTAssertTrue(resumeWait(segment, containing: "Run 1"), segment.label)
        find("run.primary").tap()
        XCTAssertTrue(resumeWait(segment, containing: "Rest 1"), segment.label)
        resumeCooldown()

        // Stop saves (no questions): home, and the toast with Resume.
        find("run.stop").tap()
        let toast = find("toast.text")
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "the saved toast")
        XCTAssertTrue(toast.label.contains("Saved TikTok"), toast.label)
        let resume = app.buttons["toast.action"].firstMatch
        XCTAssertTrue(resume.exists, "the toast offers Resume")
        XCTAssertEqual(resume.label, "Resume")
        resumeSnap(app, "resume-stop-toast")
        resume.tap()

        // The run is back: the card, Running, in the lap the stop closed.
        let card = find("tile.tiktok")
        let running = card.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'run.status' AND label CONTAINS 'Running · Rest 1'")
        ).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 15), "reopened, Running in Rest 1")
        XCTAssertTrue(find("tile.tiktok.stop").waitForExistence(timeout: 10), "its controls are back")
        resumeCooldown()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let state = find("run.state")
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(resumeWait(state, containing: "Running"), state.label)
        XCTAssertTrue(resumeWait(find("run.segment"), containing: "Rest 1"), find("run.segment").label)
        XCTAssertTrue(resumeWait(find("run.step.lap.1"), containing: "Run 1"))

        // Stop again: the same entry, its timing now with the gap pause.
        resumeCooldown()
        find("run.stop").tap()
        XCTAssertTrue(resumeWait(find("tile.tiktok.run"), containing: "Start", timeout: 15))
        find("tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        selectTopicTab("Entries", in: app)
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier MATCHES '^entry\\\\.[0-9a-f-]{36}$'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(rows.count, 1, "the re-stop updated the entry; it made no second one")
        rows.firstMatch.tap()
        XCTAssertTrue(find("entry.timing").waitForExistence(timeout: 15))
        XCTAssertTrue(find("entry.timing.pause.0").waitForExistence(timeout: 10), "the gap pause")
        XCTAssertTrue(resumeWait(find("entry.timing.segment.1"), containing: "Rest 1"))
        resumeSnap(app, "resume-entry-gap-pause")
    }

    /// Undo resume… (§1.2 row 10): from the run screen's menu, after its confirmation, the reopen
    /// is undone and the stop kept: the screen is idle with the stop's Resume under Start (§2.4),
    /// which goes once the run clock is 16 minutes on (`-QuickrClockControl`); the entry has no
    /// gap pause.
    func testUndoResumeKeepsTheStop() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTikTok", "-QuickrClockControl",
        ]
        app.launch()
        let find = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        let tileButton = find("tile.tiktok.run")
        XCTAssertTrue(tileButton.waitForExistence(timeout: 20))
        tileButton.tap()
        let stop = find("tile.tiktok.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        resumeCooldown()
        stop.tap()
        let resume = app.buttons["toast.action"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "reopened: the card's controls")
        resumeCooldown()
        find("tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(resumeWait(find("run.state"), containing: "Running", timeout: 15))

        find("run.menu").tap()
        let revert = app.buttons["run.revert"].firstMatch
        XCTAssertTrue(revert.waitForExistence(timeout: 5), "Undo resume… in the menu")
        XCTAssertFalse(app.buttons["run.discard"].exists, "revert instead of discard")
        revert.tap()
        let confirm = app.alerts.buttons["Undo resume"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "it confirms")
        confirm.tap()

        // The screen stays, idle: Start, and the kept stop's Resume under it, not also in a menu.
        let screenStart = find("run.start")
        let screenReopen = app.buttons["run.reopen"].firstMatch
        XCTAssertTrue(screenStart.waitForExistence(timeout: 15), "idle again")
        XCTAssertTrue(screenReopen.waitForExistence(timeout: 10), "the stop is kept: Resume again")
        XCTAssertEqual(screenReopen.label, "Resume the last run of TikTok")
        XCTAssertLessThan(screenStart.frame.maxY, screenReopen.frame.minY + 1, "under Start")
        XCTAssertFalse(find("run.menu").exists, "Resume shows once, not also in the menu")
        resumeSnap(app, "resume-idle-run-screen")

        // 16 minutes later on the run clock: the screen's Resume is gone, Start stays.
        find("debug.clockForward").tap()
        XCTAssertTrue(resumeWait(find("debug.clockAhead"), containing: "16 min"))
        XCTAssertTrue(screenReopen.waitForNonExistence(timeout: 15), "gone after 15 minutes")
        XCTAssertTrue(screenStart.exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(resumeWait(find("tile.tiktok.run"), containing: "Start", timeout: 15))
        XCTAssertFalse(find("tile.tiktok.reopen").exists, "nor on the tile")
        find("tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        selectTopicTab("Entries", in: app)
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier MATCHES '^entry\\\\.[0-9a-f-]{36}$'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(rows.count, 1)
        rows.firstMatch.tap()
        XCTAssertTrue(find("entry.timing").waitForExistence(timeout: 15))
        XCTAssertFalse(find("entry.timing.pause.0").exists, "no gap pause: the resume was undone")
    }

    // MARK: M2-RESUME helpers

    private func resumeWait(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }

    /// Past the run controls' tap cooldown (450 ms), so the next tap is a new one.
    private func resumeCooldown() { Thread.sleep(forTimeInterval: 0.6) }

    private func resumeSnap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
