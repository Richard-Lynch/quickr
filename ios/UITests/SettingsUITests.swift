import XCTest

/// Onboarding and Settings on a clean slate (`-QuickrUITest`: a fresh store and defaults, an
/// in-memory Keychain, and a fake quickR server at https://quickr.test).
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingConnectsAndEndsAtTheTopicList() {
        let app = launch()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))

        // A public http:// address is refused before anything connects.
        address.tap()
        address.typeText("http://example.com")
        app.buttons["server.connect"].tap()
        let error = app.descendants(matching: .any)["server.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("https://"), error.label)

        // The fake server, typed without a scheme.
        replace(address, with: "quickr.test")
        app.buttons["server.connect"].tap()
        finishOnboarding(app)

        XCTAssertTrue(app.staticTexts["root.title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["root.title"].label, "quickR")
        XCTAssertTrue(app.staticTexts["root.coreVersion"].label.hasPrefix("Core "))
        XCTAssertTrue(app.staticTexts["root.storeStatus"].waitForLabel("Store ready"))
    }

    @MainActor
    func testSettingsShowsTheServerAndKeepsTheTokenInTheKeychain() {
        let app = launch()
        onboard(app)
        app.buttons["root.settings"].tap()
        let url = app.staticTexts["settings.serverURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        // LabeledContent reads as one element: "Address, https://quickr.test".
        XCTAssertTrue(url.label.hasSuffix("https://quickr.test"), url.label)

        // Add a service token: only the Client ID shows afterwards.
        app.buttons["settings.addToken"].tap()
        let clientId = app.textFields["token.clientId"]
        XCTAssertTrue(clientId.waitForExistence(timeout: 5))
        clientId.tap()
        clientId.typeText("abc123.access")
        let secret = app.secureTextFields["token.clientSecret"]
        secret.tap()
        secret.typeText("very-secret")
        app.buttons["token.save"].tap()
        let shown = app.descendants(matching: .any)["settings.accessClientId"]
        XCTAssertTrue(shown.waitForExistence(timeout: 5))
        XCTAssertTrue(shown.label.contains("abc123.access"), shown.label)
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'very-secret'")).firstMatch.exists)

        app.buttons["settings.removeToken"].tap()
        XCTAssertTrue(app.buttons["settings.addToken"].waitForExistence(timeout: 5))

        // About shows the version.
        let version = app.descendants(matching: .any)["settings.version"]
        for _ in 0..<5 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.exists)
    }

    /// At the largest accessibility text size, onboarding still fits: the address and Connect are
    /// reachable, and it ends at the topic list.
    @MainActor
    func testOnboardingWorksAtAnAccessibilityTextSize() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText("quickr.test\n")  // Go connects from the keyboard
        finishOnboarding(app)
        XCTAssertTrue(app.staticTexts["root.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["root.settings"].isHittable)
    }

    // MARK: - Helpers

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func onboard(_ app: XCUIApplication) {
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText("https://quickr.test")
        app.buttons["server.connect"].tap()
        finishOnboarding(app)
        XCTAssertTrue(app.buttons["root.settings"].waitForExistence(timeout: 15))
    }

    /// The reminders step shows only while the permission is undecided on this simulator; "Not now"
    /// leaves it without the system prompt.
    @MainActor
    private func finishOnboarding(_ app: XCUIApplication) {
        let done = app.buttons["onboarding.done"]
        let root = app.staticTexts["root.title"]
        for _ in 0..<30 where !done.exists && !root.exists { usleep(500_000) }
        if done.exists {
            for _ in 0..<4 where !done.isHittable { app.swipeUp() }
            done.tap()
        }
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
}

extension XCUIElement {
    /// Waits up to 10 s for the label to equal `label`.
    func waitForLabel(_ label: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
