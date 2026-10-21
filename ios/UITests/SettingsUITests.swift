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

        // The home screen, over the new server's store.
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["home.list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home.noServer"].exists)
    }

    @MainActor
    func testSettingsShowsTheServerAndKeepsTheTokenInTheKeychain() {
        let app = launch()
        onboard(app)
        app.buttons["home.settings"].tap()
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
        dismissSavePasswordOffer(app)
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

    /// The token fields are labelled for AutoFill (Client ID as the username, Secret as the
    /// password), so iOS may offer to save them as the sheet goes: Cancel still saves nothing in
    /// quickR, whatever the user answers to the offer.
    @MainActor
    func testCancellingTheTokenSheetSavesNothing() {
        let app = launch()
        onboard(app)
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.addToken"].waitForExistence(timeout: 10))
        app.buttons["settings.addToken"].tap()
        let clientId = app.textFields["token.clientId"]
        XCTAssertTrue(clientId.waitForExistence(timeout: 5))
        clientId.tap()
        clientId.typeText("abc123.access")
        let secret = app.secureTextFields["token.clientSecret"]
        secret.tap()
        secret.typeText("very-secret")
        app.buttons["token.cancel"].tap()
        dismissSavePasswordOffer(app)
        XCTAssertTrue(app.buttons["settings.addToken"].waitForExistence(timeout: 5), "closed, no token saved")
        XCTAssertFalse(app.descendants(matching: .any)["settings.accessClientId"].exists)
    }

    /// Onboarding with a service token: it connects with it (the fake server takes any), and iOS
    /// may offer to save it as the server step goes.
    @MainActor
    func testOnboardingWithAServiceToken() {
        let app = launch()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText("https://quickr.test")
        app.buttons["Cloudflare Access token"].tap()
        let clientId = app.textFields["server.clientId"]
        XCTAssertTrue(clientId.waitForExistence(timeout: 5))
        clientId.tap()
        clientId.typeText("abc123.access")
        let secret = app.secureTextFields["server.clientSecret"]
        secret.tap()
        secret.typeText("very-secret")
        app.buttons["server.connect"].tap()
        dismissSavePasswordOffer(app)
        finishOnboarding(app)
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        app.buttons["home.settings"].tap()
        let shown = app.descendants(matching: .any)["settings.accessClientId"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10))
        XCTAssertTrue(shown.label.contains("abc123.access"), shown.label)
    }

    /// Dismisses iOS's "Save Password?" offer (AutoFill, for the token fields) if it shows within
    /// `seconds`, in the app or above it (SpringBoard): saving it is the user's choice, and a test
    /// declines it.
    @MainActor
    private func dismissSavePasswordOffer(_ app: XCUIApplication, within seconds: TimeInterval = 3) {
        let places = [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")]
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            for place in places {
                let notNow = place.buttons["Not Now"]
                if notNow.exists {
                    notNow.tap()
                    return
                }
            }
            usleep(200_000)
        } while Date() < deadline
    }

    /// At the largest accessibility text size, onboarding still fits: the address and Connect are
    /// reachable, and it ends at the topic list.
    @MainActor
    func testOnboardingWorksAtAnAccessibilityTextSize() throws {
        let app = launch(extra: AccessibilityLaunch.arguments())
        // At this size the address wraps (vertical axis; still a text field to XCUITest), so a long
        // one stays readable while typed.
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        try assertAccessible(app)
        address.tap()
        address.typeText("quickr.test\n")  // Return still connects, from the keyboard
        finishOnboarding(app)
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["home.settings"].isHittable)
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
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
    }

    /// The reminders step shows only while the permission is undecided on this simulator; "Not now"
    /// leaves it without the system prompt.
    @MainActor
    private func finishOnboarding(_ app: XCUIApplication) {
        let done = app.buttons["onboarding.done"]
        let root = app.staticTexts["home.wordmark"]
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
