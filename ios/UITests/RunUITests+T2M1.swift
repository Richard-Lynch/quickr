import XCTest

// T2-M1 (timers2.md §3.2, §6.2, §6.4, §12.3 R14): lap types on the run screen and a run another
// device changes, against the UI-test fake server's "TikTok" (`-QuickrSeedTikTok`: no steps, lap
// types Run and Rest, no questions, so Stop saves at once). `-QuickrRunControls` adds the debug
// buttons that record another device's reopen or remove on the fake server and then pull
// (`UITestRunControls`).
extension RunUITests {
    /// Laps cycle through the lap types with a per-type ordinal: Run 1, Rest 1, Run 2, Rest 2. The
    /// entry keeps the labels.
    func testTikTokLapLabels() {
        let app = launchTikTok()
        openTikTokRun(app)
        let segment = find(app, "run.segment")
        XCTAssertTrue(waitFor(segment, label: "Run 1"), segment.label)

        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Rest 1"), segment.label)
        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Run 2"), segment.label)
        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Rest 2"), segment.label)
        // The closed laps in the list, each under its own label; the open one current.
        XCTAssertTrue(waitFor(find(app, "run.step.lap.1"), label: "Run 1"))
        XCTAssertTrue(waitFor(find(app, "run.step.lap.2"), label: "Rest 1"))
        XCTAssertTrue(waitFor(find(app, "run.step.lap.3"), label: "Run 2"))
        XCTAssertEqual(find(app, "run.step.lap.4").value as? String, "current")
        XCTAssertTrue(find(app, "run.step.lap.4").label.contains("Rest 2"), find(app, "run.step.lap.4").label)

        stopAndOpenEntry(app)
        for (index, label) in ["Run 1", "Rest 1", "Run 2", "Rest 2"].enumerated() {
            XCTAssertTrue(waitFor(find(app, "entry.timing.segment.\(index)"), label: label), label)
        }
        XCTAssertFalse(find(app, "entry.timing.segment.4").exists)
    }

    /// R14 on screen: the run is stopped and its entry listed; another device reopens it (the fake
    /// server records the reopen and logs the run in the feed). The entry list hides the entry and
    /// the run screen shows the run Running again, in the lap the stop closed.
    func testRunComesBackAfterRemoteReopen() {
        let app = launchTikTok()
        openTikTokRun(app)
        let segment = find(app, "run.segment")
        XCTAssertTrue(waitFor(segment, label: "Run 1"), segment.label)
        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Rest 1"), segment.label)

        // Stop: no questions, so it saves and the screen closes.
        find(app, "run.primary").tap()
        let tileButton = find(app, "tile.tiktok.run")
        XCTAssertTrue(waitFor(tileButton, label: "Start", timeout: 15), tileButton.label)

        // The entry, on the topic's Entries tab.
        find(app, "tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        selectTopicTab("Entries", in: app)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'entry.'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let entry = find(app, row.identifier)

        // Another device reopens the run, once the server has the stop; the pull brings it back open.
        XCTAssertTrue(waitFor(find(app, "debug.serverRun"), label: "stopped · laps 1", timeout: 15))
        tapRunControl(app, "debug.reopenElsewhere", expecting: "reopened")
        XCTAssertTrue(entry.waitForNonExistence(timeout: 15), "the reopened run's entry is hidden")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(find(app, "tile.tiktok").waitForExistence(timeout: 10))
        find(app, "tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let state = find(app, "run.state")
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(state, label: "Running"), state.label)
        XCTAssertTrue(waitFor(find(app, "run.segment"), label: "Rest 1"), find(app, "run.segment").label)
        XCTAssertTrue(waitFor(find(app, "run.step.lap.1"), label: "Run 1"))
    }

    /// timers2.md §6.4: a double-tapped lap (Run 1, Rest 1, Run 2, open Rest 2) that another device
    /// removes: Rest 1 runs on to the third lap's boundary, and the open lap is Run 2 again.
    func testRemoteRemoveRenumbersLaps() {
        let app = launchTikTok()
        openTikTokRun(app)
        let segment = find(app, "run.segment")
        XCTAssertTrue(waitFor(segment, label: "Run 1"), segment.label)
        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Rest 1"), segment.label)
        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Run 2"), segment.label)
        lapOnce(app)
        XCTAssertTrue(waitFor(segment, label: "Rest 2"), segment.label)
        // Every lap has reached the server.
        XCTAssertTrue(waitFor(find(app, "debug.serverRun"), label: "running · laps 3", timeout: 15))

        // Another device removes the second lap boundary (the one that opened Run 2).
        tapRunControl(app, "debug.removeLap2Elsewhere", expecting: "removed")
        XCTAssertTrue(waitFor(segment, label: "Run 2", timeout: 15), segment.label)
        XCTAssertTrue(waitFor(find(app, "run.step.lap.1"), label: "Run 1"))
        XCTAssertTrue(waitFor(find(app, "run.step.lap.2"), label: "Rest 1"))
        XCTAssertEqual(find(app, "run.step.lap.3").value as? String, "current")
        XCTAssertTrue(find(app, "run.step.lap.3").label.contains("Run 2"), find(app, "run.step.lap.3").label)
        XCTAssertFalse(find(app, "run.step.lap.4").exists)

        stopAndOpenEntry(app)
        for (index, label) in ["Run 1", "Rest 1", "Run 2"].enumerated() {
            XCTAssertTrue(waitFor(find(app, "entry.timing.segment.\(index)"), label: label), label)
        }
        XCTAssertFalse(find(app, "entry.timing.segment.3").exists)
    }

    // MARK: T2-M1 helpers

    private func launchTikTok() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTikTok", "-QuickrRunControls",
        ]
        app.launch()
        return app
    }

    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ element: XCUIElement, label text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }

    /// Start on the tile, then the tile opens the run screen.
    private func openTikTokRun(_ app: XCUIApplication) {
        let tile = find(app, "tile.tiktok")
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        let tileButton = find(app, "tile.tiktok.run")
        XCTAssertTrue(tileButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(tileButton, label: "Start"), tileButton.label)
        tileButton.tap()
        XCTAssertFalse(waitFor(tileButton, label: "Start", timeout: 2), "started: \(tileButton.label)")
        afterCooldown()
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(find(app, "run.lap").waitForExistence(timeout: 10))
    }

    /// One Lap tap, then past the controls' tap cooldown.
    private func lapOnce(_ app: XCUIApplication) {
        let lap = find(app, "run.lap")
        XCTAssertTrue(lap.waitForExistence(timeout: 5))
        lap.tap()
        afterCooldown()
    }

    /// Past the run controls' tap cooldown (450 ms), so the next tap is a new one.
    private func afterCooldown() { Thread.sleep(forTimeInterval: 0.6) }

    /// A `UITestRunControls` button, and the fake server's answer it shows.
    private func tapRunControl(_ app: XCUIApplication, _ id: String, expecting result: String) {
        let control = app.buttons[id].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), id)
        control.tap()
        let shown = find(app, "debug.runResult")
        XCTAssertTrue(waitFor(shown, label: result), "\(id): \(shown.label)")
    }

    /// Stop (it saves: TikTok has no questions), then the run's entry from the topic's Entries tab.
    private func stopAndOpenEntry(_ app: XCUIApplication) {
        find(app, "run.primary").tap()
        let tileButton = find(app, "tile.tiktok.run")
        XCTAssertTrue(waitFor(tileButton, label: "Start", timeout: 15), tileButton.label)
        find(app, "tile.tiktok").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        selectTopicTab("Entries", in: app)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'entry.'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(find(app, "entry.timing").waitForExistence(timeout: 15))
    }
}
// end T2-M1
