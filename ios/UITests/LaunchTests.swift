import XCTest

final class LaunchTests: XCTestCase {
    /// The app launches into the home screen (a fresh install asks to connect a server).
    @MainActor
    func testTheAppLaunchesIntoTheHomeScreen() {
        let app = XCUIApplication()
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["home.list"].waitForExistence(timeout: 20))
        XCTAssertTrue(any["home.settings"].exists)
    }
}
