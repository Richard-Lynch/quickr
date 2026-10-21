import XCTest

final class LaunchTests: XCTestCase {
    /// A first launch (a clean slate: `-QuickrUITest`) opens onboarding. The topic list after it
    /// is checked by `SettingsUITests`.
    @MainActor
    func testFirstLaunchShowsOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest"]
        app.launch()
        XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["server.connect"].exists)
    }
}
