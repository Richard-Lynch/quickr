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
