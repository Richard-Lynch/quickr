import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testRootViewShowsAppNameAndCoreVersion() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["root.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["root.title"].label, "quickR")
        XCTAssertTrue(app.staticTexts["root.coreVersion"].label.hasPrefix("Core "))
    }
}
