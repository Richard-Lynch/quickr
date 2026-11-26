import XCTest

// M2-RESUME (active-surfaces.md §3.3, §1.2 rows 2, 11 and 13): an idle timed tile's
// "Resume · 0:04" for 15 minutes after its stop, against the UI-test fake server's "TikTok"
// (`-QuickrSeedTikTok`: no steps, no questions, so Stop saves at once). The window is read on the
// run clock: `-QuickrClockControl`'s "+16 min" moves the fake server's clock ahead, and the next
// response moves the store's (`UITestClockControl`).
extension TileUITests {
    private func launchTikTok(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTikTok"] + extra
        app.launch()
        return app
    }

    private func headline(_ card: XCUIElement, _ text: String) -> XCUIElement {
        card.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'run.status' AND label CONTAINS %@", text)
        ).firstMatch
    }

    private func resumeWait(_ element: XCUIElement, prefix: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Start and Stop on the tile: the idle tile offers Resume under its meta line; Resume reopens
    /// the run (the card, Running); stopped again it offers Resume again, and 16 minutes later on
    /// the run clock it is gone and only Start is left.
    @MainActor
    func testIdleTileOffersResumeWithin15Min() {
        let app = launchTikTok(["-QuickrClockControl"])
        let find = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        let start = find("tile.tiktok.run")
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(resumeWait(start, prefix: "Start"), start.label)
        XCTAssertFalse(find("tile.tiktok.reopen").exists, "no stop yet, no Resume")
        start.tap()
        let stop = find("tile.tiktok.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "started: the card")
        Thread.sleep(forTimeInterval: 0.6)  // past the run controls' tap cooldown (450 ms)
        stop.tap()

        // Idle, with Resume beside Start.
        let reopen = find("tile.tiktok.reopen")
        XCTAssertTrue(reopen.waitForExistence(timeout: 10), "the idle tile offers Resume")
        XCTAssertEqual(reopen.label, "Resume the last run of TikTok")
        XCTAssertTrue(resumeWait(start, prefix: "Start"), start.label)
        shot(app, "resume-idle-tile")
        Thread.sleep(forTimeInterval: 0.6)
        reopen.tap()
        let card = find("tile.tiktok")
        XCTAssertTrue(headline(card, "Running").waitForExistence(timeout: 15), "reopened: the card, Running")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertFalse(reopen.exists, "an open run is never offered Resume")

        Thread.sleep(forTimeInterval: 0.6)
        stop.tap()
        XCTAssertTrue(reopen.waitForExistence(timeout: 10), "stopped again: Resume again")

        // 16 minutes later on the run clock: past the window, only Start.
        XCTAssertTrue(find("toast.text").waitForNonExistence(timeout: 10), "the toast went")
        find("debug.clockForward").tap()
        XCTAssertTrue(resumeWait(find("debug.clockAhead"), prefix: "16 min"))
        XCTAssertTrue(reopen.waitForNonExistence(timeout: 15), "Resume is gone after 15 minutes")
        XCTAssertTrue(resumeWait(start, prefix: "Start"), start.label)
    }

    /// A reopen from the entry (the stop acked, so no run row is left here) queued offline: the
    /// card shows "Resuming…" and no controls until the ack (§1.2 row 11, timers2.md §5.3); back
    /// online, it is Running with its controls.
    @MainActor
    func testResumingCardHasNoControlsUntilTheAck() {
        let app = launchTikTok(["-QuickrSyncControls", "-QuickrRunControls"])
        let find = { (id: String) in app.descendants(matching: .any)[id].firstMatch }
        let start = find("tile.tiktok.run")
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let stop = find("tile.tiktok.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        stop.tap()
        // The server has the stop, so the run row is gone here: a reopen goes from the entry.
        XCTAssertTrue(resumeWait(find("debug.serverRun"), prefix: "stopped", timeout: 15))
        let reopen = find("tile.tiktok.reopen")
        XCTAssertTrue(reopen.waitForExistence(timeout: 10))

        find("debug.offline").tap()
        Thread.sleep(forTimeInterval: 0.6)
        reopen.tap()
        let card = find("tile.tiktok")
        XCTAssertTrue(headline(card, "Resuming…").waitForExistence(timeout: 10), "Resuming… until the ack")
        XCTAssertFalse(find("tile.tiktok.stop").exists, "no controls while resuming")
        XCTAssertFalse(find("tile.tiktok.run").exists)
        XCTAssertFalse(find("tile.tiktok.pause").exists)
        shot(app, "resume-resuming-card")

        find("debug.online").tap()
        XCTAssertTrue(headline(card, "Running").waitForExistence(timeout: 20), "acked: Running")
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "its controls are back")
    }
}
