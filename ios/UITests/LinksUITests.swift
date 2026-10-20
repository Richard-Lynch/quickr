import XCTest

/// Links open the screen they name (`-QuickrOpen` hands the URL to the router at launch, as
/// `onOpenURL` would, without the system's "Open in quickR?" prompt). The topic screens are still
/// placeholders that show their route's PWA path.
final class LinksUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAQuickrLinkOpensItsScreenAndBackReturnsToTheList() {
        // A screen still to be built shows its route's path (Entries is LIST's now).
        let app = launch(open: "quickr://t/workout/versions")
        let path = app.staticTexts["route.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 15))
        XCTAssertEqual(path.label, "/t/workout/versions")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 5))
    }

    /// A notification's link (`/t/{slug}/record`) opens the record screen.
    @MainActor
    func testARecordLinkOpensTheRecordScreen() {
        let app = launch(open: "quickr://t/workout/record")
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Workout"].exists)
    }

    @MainActor
    func testALinkToTheServersPWAOpensSettings() {
        let app = launch(open: "https://quickr.test/settings")
        XCTAssertTrue(app.descendants(matching: .any)["settings.serverURL"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testAnUnknownLinkSaysSo() {
        let app = launch(open: "quickr://t/water/nonsense")
        XCTAssertTrue(app.alerts["Can’t open that link"].waitForExistence(timeout: 15))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["home.wordmark"].exists)
    }

    @MainActor
    private func launch(open url: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", url]
        app.launch()
        return app
    }
}
