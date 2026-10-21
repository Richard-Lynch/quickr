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
        // A topic tab's link (Versions, BUILDER-UI's) opens on that tab.
        let app = launch(open: "quickr://t/workout/versions")
        XCTAssertTrue(app.descendants(matching: .any)["versions.v1"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(selectedTopicTab(in: app), "Versions")
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

    // MARK: - Links that name their server (notifications.md §7.5)

    /// The fake server's id and its store's generation on a clean launch, and Workout's id.
    static let fakeScope = "00000000-0000-4000-8000-0000000000aa/1"
    static let workoutId = "00000000-0000-4000-8000-0000000000c1"

    /// A widget's link from another registered server ("Other") isn't opened on this one: the app
    /// says which server it's from.
    @MainActor
    func testALinkFromAnotherServerIsRefusedNamingIt() {
        let app = launch(
            open: "quickr://t/\(Self.workoutId)/record?scope=00000000-0000-4000-8000-0000000000bb/1",
            extra: ["-QuickrSecondServer"])
        let alert = app.alerts["Can’t open that here"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertTrue(
            alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Other'")).firstMatch.exists,
            "the message names the server")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["record.save"].exists, "no record screen")
    }

    /// The active server's widget link, at a cold launch (before the session has bound its
    /// store): it waits, then opens the topic by id.
    @MainActor
    func testTheActiveServersScopedLinkOpensAtLaunch() {
        let app = launch(open: "quickr://t/\(Self.workoutId)/record?scope=\(Self.fakeScope)")
        XCTAssertTrue(app.buttons["record.save"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Workout"].exists)
    }

    @MainActor
    private func launch(open url: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", url] + extra
        app.launch()
        return app
    }
}
