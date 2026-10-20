import XCTest

/// The sync pill and sheet (SYNC-UX) against the UI-test fake server, switched by the debug sync
/// controls (`-QuickrSyncControls`): offline, online, log an entry, reject the next create.
final class SyncUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Offline: the entry waits and the pill says so; back online, it is sent and the pill goes.
    @MainActor
    func testOfflineEntryWaitsThenSyncsWhenBackOnline() {
        let app = launch()
        let pill = app.buttons["sync.pill"]
        XCTAssertFalse(pill.exists)  // all synced: no pill

        app.buttons["debug.offline"].tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(pill.waitForLabel("Offline"))
        app.buttons["debug.log"].tap()
        XCTAssertTrue(pill.waitForLabel("Offline · 1 waiting to sync"))

        pill.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sync.offlineBanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sync.headline"].waitForLabel("1 item waiting"))
        XCTAssertEqual(app.staticTexts["sync.row.0.title"].label, "Entry · Mood")
        app.buttons["sync.done"].tap()

        app.buttons["debug.online"].tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 20), "the pill stays: \(pill.label)")
    }

    /// A rejected entry fails: the sheet shows why and offers Fix, Retry and Discard. Retry sends
    /// it; a second rejected entry is discarded.
    @MainActor
    func testFailedItemRetryThenDiscard() {
        let app = launch()
        let pill = app.buttons["sync.pill"]
        app.buttons["debug.reject"].tap()
        app.buttons["debug.log"].tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        XCTAssertTrue(pill.waitForLabel("1 failed to sync"))

        pill.tap()
        let status = app.staticTexts["sync.row.0.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Failed — Mood is required")
        XCTAssertTrue(app.buttons["sync.row.0.fix"].exists)
        app.buttons["sync.row.0.retry"].tap()  // "Retry as is": the server takes it this time
        XCTAssertTrue(app.staticTexts["sync.headline"].waitForLabel("Everything is synced.", timeout: 15))
        app.buttons["sync.done"].tap()
        XCTAssertTrue(pill.waitForNonExistence(timeout: 10))

        app.buttons["debug.reject"].tap()
        app.buttons["debug.log"].tap()
        XCTAssertTrue(pill.waitForLabel("1 failed to sync", timeout: 15))
        pill.tap()
        app.buttons["sync.row.0.discard"].tap()
        app.buttons["sync.row.0.discardConfirm"].tap()
        XCTAssertTrue(app.staticTexts["sync.headline"].waitForLabel("Everything is synced.", timeout: 10))
    }

    /// At the largest accessibility size, a failed item's actions are all reachable.
    @MainActor
    func testSheetAtAccessibilityXXXL() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["debug.reject"].tap()
        app.buttons["debug.log"].tap()
        let pill = app.buttons["sync.pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        pill.tap()
        XCTAssertTrue(app.staticTexts["sync.row.0.status"].waitForExistence(timeout: 5))
        for id in ["sync.row.0.retry", "sync.row.0.fix", "sync.row.0.discard"] {
            let button = app.buttons[id]
            for _ in 0..<6 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, "\(id) can't be reached")
        }
    }

    /// The demo screenshots (docs/ios/demo/m2/sync-ux-*.png). Runs only with
    /// `TEST_RUNNER_QUICKR_SHOTS_DIR=<dir>` (xcodebuild passes it to the runner as QUICKR_SHOTS_DIR).
    @MainActor
    func testDemoScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["QUICKR_SHOTS_DIR"] else {
            throw XCTSkip("QUICKR_SHOTS_DIR not set: demo screenshots only")
        }
        for (mode, appearance) in [("light", XCUIDevice.Appearance.light), ("dark", .dark)] {
            XCUIDevice.shared.appearance = appearance
            let app = launch()
            app.buttons["debug.reject"].tap()
            app.buttons["debug.log"].tap()
            XCTAssertTrue(app.buttons["sync.pill"].waitForLabel("1 failed to sync", timeout: 15))
            app.buttons["debug.offline"].tap()
            app.buttons["debug.log"].tap()
            sleep(1)
            try save(dir, "sync-ux-pill-\(mode)")
            app.buttons["sync.pill"].tap()
            XCTAssertTrue(app.staticTexts["sync.row.1.status"].waitForExistence(timeout: 5))
            sleep(1)
            try save(dir, "sync-ux-sheet-\(mode)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["debug.reject"].tap()
        app.buttons["debug.log"].tap()
        XCTAssertTrue(app.buttons["sync.pill"].waitForExistence(timeout: 15))
        app.buttons["sync.pill"].tap()
        XCTAssertTrue(app.staticTexts["sync.row.0.status"].waitForExistence(timeout: 5))
        sleep(1)
        try save(dir, "sync-ux-sheet-ax")
    }

    private func save(_ dir: String, _ name: String) throws {
        let url = URL(fileURLWithPath: dir).appending(path: "\(name).png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSyncControls"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["debug.offline"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 20))
        return app
    }
}
