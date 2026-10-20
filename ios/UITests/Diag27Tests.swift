import XCTest

/// TEMPORARY (not committed): does iOS 27 do a content swipe back at all under XCUITest, on a
/// screen with the system back button?
final class Diag27Tests: XCTestCase {
    @MainActor
    func testContentSwipeOnSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test"]
        app.launch()
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        XCTAssertTrue(app.staticTexts["settings.serverURL"].waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        start.press(
            forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.3)),
            withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 5), "content swipe pops Settings")
    }
}
