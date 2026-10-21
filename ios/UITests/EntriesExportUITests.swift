import XCTest

/// CSV: "Export CSV" on Mood's entries over the fake server (`-QuickrUITest`): online it opens
/// the share sheet with the file; offline it says export needs a connection. Also at the largest
/// accessibility size, and in light and dark.
final class EntriesExportUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSyncControls", "-QuickrOpen",
                "quickr://t/mood/entries",
            ] + extra
        app.launch()
        XCTAssertTrue(app.buttons["entries.export"].waitForExistence(timeout: 20))
        return app
    }

    /// The system share sheet, showing the file (its name, or the sheet's own list).
    @MainActor
    private func shareSheet(_ app: XCUIApplication) -> Bool {
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'mood-'")).firstMatch
        let sheet = app.otherElements["ActivityListView"]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if named.exists || sheet.exists { return true }
            usleep(200_000)
        }
        return false
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testExportOpensTheShareSheet() {
        let app = launch()
        app.buttons["entries.export"].tap()
        XCTAssertTrue(shareSheet(app), "the share sheet with the CSV")
        attach(app, "csv-share-sheet")
    }

    @MainActor
    func testOfflineSaysExportNeedsAConnection() {
        let app = launch()
        app.buttons["debug.offline"].tap()
        app.buttons["entries.export"].tap()
        XCTAssertTrue(app.staticTexts["Export needs a connection"].waitForExistence(timeout: 5))
        XCTAssertFalse(shareSheet(app))
    }

    /// At the largest accessibility size the button is reachable, and its message shows.
    @MainActor
    func testAccessibilityXXXL() throws {
        let app = launch(AccessibilityLaunch.arguments())
        let button = app.buttons["entries.export"]
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable)
        try assertAccessible(app, allowing: EntriesAccessibility.export, within: [button.frame])
        attach(app, "csv-ax-xxxl")
        app.buttons["debug.offline"].tap()
        button.tap()
        XCTAssertTrue(app.staticTexts["Export needs a connection"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLightAndDark() {
        for (mode, appearance) in [("light", XCUIDevice.Appearance.light), ("dark", .dark)] {
            XCUIDevice.shared.appearance = appearance
            let app = launch()
            XCTAssertTrue(app.buttons["entries.export"].isHittable)
            attach(app, "csv-entries-\(mode)")
            app.buttons["entries.export"].tap()
            XCTAssertTrue(shareSheet(app), "\(mode)")
            attach(app, "csv-share-sheet-\(mode)")
            app.terminate()
        }
    }
}
