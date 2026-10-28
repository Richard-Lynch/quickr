import XCTest

/// Client API levels (client-versions.md §4.1, §4.5) against the UI-test fake server, whose levels
/// the debug controls switch (`-QuickrLevelControls`): "Outdated" raises its iOS minimum above
/// this build's level, so it refuses every request but `getClientVersions` with 426
/// `client_outdated`; "Current" puts it at this build's level. `-QuickrServerBehind` starts it one
/// level below this build.
final class ClientVersionUITests: XCTestCase {
    static let updateMessage =
        "quickR needs an update to keep syncing with your server. Your unsynced changes (1) are safe on this iPhone."
    static let serverBehindMessage =
        "The quickR server is older than this app. It keeps working, but deploy the server to finish the update."

    override func setUp() {
        continueAfterFailure = false
    }

    /// V9: a response whose minimum is above this build's level brings up "Update required" over
    /// everything, with the held entry counted. Its own check reads the server's link for Open
    /// TestFlight while the minimum stands, and it stays; Settings ▸ Server is reachable from it.
    /// Check again takes it away once the server's minimum drops, and the held entry is then sent.
    @MainActor
    func testUpdateRequiredUntilTheServersMinimumDrops() {
        let app = launch()
        let required = app.descendants(matching: .any)["update.required"]
        XCTAssertFalse(required.exists)

        app.buttons["debug.outdated"].tap()
        app.buttons["debug.log"].tap()  // its send is refused with 426: the entry is held
        XCTAssertTrue(required.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["update.title"].exists)
        let message = app.staticTexts["update.message"]
        XCTAssertTrue(message.waitForLabel(Self.updateMessage), message.label)
        let homeSettings = app.buttons["home.settings"]
        XCTAssertTrue(homeSettings.exists, "Home is still there, under it")
        XCTAssertFalse(homeSettings.isHittable, "Home is covered")
        // The view's check on appearing (getClientVersions) has answered: the minimum stands.
        let open = app.buttons["update.open"]
        XCTAssertTrue(open.waitForValue("itms-beta://quickr.test/update"), "\(String(describing: open.value))")
        XCTAssertTrue(app.buttons["update.check"].waitForEnabled())
        XCTAssertTrue(required.exists)

        // The server-switch escape.
        app.buttons["update.settings"].tap()
        XCTAssertTrue(app.buttons["settings.changeServer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.serverURL"].exists)
        app.buttons["update.settingsDone"].tap()
        XCTAssertTrue(app.buttons["settings.changeServer"].waitForNonExistence(timeout: 5))

        app.buttons["debug.current"].tap()
        app.buttons["update.check"].tap()
        XCTAssertTrue(required.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.buttons["home.settings"].waitForHittable())
        let pill = app.buttons["sync.pill"]
        XCTAssertTrue(pill.waitForNonExistence(timeout: 20), "the held entry stays: \(pill.label)")
    }

    /// "Update required" comes up over the sync sheet that was open: a retry from it is refused
    /// with 426, the view is on top and the sheet is gone (its Fix and Retry would act under it).
    @MainActor
    func testUpdateRequiredCoversAnOpenSheet() {
        let app = launch()
        let pill = app.buttons["sync.pill"]
        app.buttons["debug.reject"].tap()
        app.buttons["debug.log"].tap()
        XCTAssertTrue(pill.waitForLabel("1 failed to sync", timeout: 15), pill.label)
        app.buttons["debug.outdated"].tap()
        pill.tap()
        let retry = app.buttons["sync.row.0.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()

        let required = app.descendants(matching: .any)["update.required"]
        XCTAssertTrue(required.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["update.check"].isHittable, "the view is on top")
        XCTAssertTrue(app.buttons["sync.done"].waitForNonExistence(timeout: 5), "the sheet is gone")

        app.buttons["debug.current"].tap()
        app.buttons["update.check"].tap()
        XCTAssertTrue(required.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.buttons["home.settings"].waitForHittable())
    }

    /// A fresh install whose first connect is refused (426 `client_outdated`): onboarding says to
    /// update, with Open TestFlight to the server's link, instead of a generic error.
    @MainActor
    func testAFirstConnectRefusedSaysToUpdate() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServerOutdated"]
        app.launch()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText("https://quickr.test")
        app.buttons["server.connect"].tap()
        let error = app.descendants(matching: .any)["server.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("needs an update"), error.label)
        let open = app.buttons["server.openTestFlight"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["update.required"].exists, "no store, so no flag")
    }

    /// Check again without the server: an inline error, and the view stays. Online again, the
    /// error goes with the next check. Settings from the view offers no "Review changes…", which
    /// would open the sync sheet beneath it.
    @MainActor
    func testCheckAgainOfflineSaysSoAndStays() {
        let app = launch()
        app.buttons["debug.outdated"].tap()
        app.buttons["debug.log"].tap()
        let required = app.descendants(matching: .any)["update.required"]
        XCTAssertTrue(required.waitForExistence(timeout: 15))
        let check = app.buttons["update.check"]
        XCTAssertTrue(check.waitForEnabled())

        app.buttons["update.settings"].tap()
        XCTAssertTrue(app.buttons["settings.changeServer"].waitForExistence(timeout: 5))
        let syncNow = app.buttons["settings.syncNow"]
        for _ in 0..<6 where !syncNow.isHittable { app.swipeUp() }
        XCTAssertTrue(syncNow.isHittable, "Offline & sync is on screen")
        XCTAssertFalse(app.buttons["settings.sync.review"].exists, "the held entry is there, but not its review")
        app.buttons["update.settingsDone"].tap()
        XCTAssertTrue(app.buttons["settings.changeServer"].waitForNonExistence(timeout: 5))

        app.buttons["debug.offline"].tap()
        check.tap()
        let error = app.staticTexts["update.checkError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(required.exists)

        app.buttons["debug.online"].tap()
        XCTAssertTrue(check.waitForEnabled())
        check.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 15))
        XCTAssertTrue(required.exists, "online, the minimum still stands")
    }

    /// V13 (UI): a server behind this build shows the Home banner and the Settings
    /// line, and blocks nothing. A later response at this build's level removes both.
    @MainActor
    func testServerBehindNoteUntilTheServerCatchesUp() {
        let app = launch(extra: ["-QuickrServerBehind"])
        let banner = app.descendants(matching: .any)["home.serverBehind"]
        app.buttons["debug.log"].tap()  // a response from the store's server (the connect's came before the store)
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["home.serverBehind.text"].label, Self.serverBehindMessage)
        XCTAssertFalse(app.descendants(matching: .any)["update.required"].exists)

        app.buttons["home.settings"].tap()
        let line = app.descendants(matching: .any)["settings.serverBehind"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.contains(Self.serverBehindMessage), line.label)

        // Its next response reports this build's level: the line goes, and so does the banner.
        app.buttons["debug.current"].tap()
        app.buttons["debug.log"].tap()
        XCTAssertTrue(line.waitForNonExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(banner.exists)
    }

    /// V13 (UI): the banner's dismiss hides it for this launch; Settings still says it.
    @MainActor
    func testServerBehindBannerDismissesForTheLaunch() {
        let app = launch(extra: ["-QuickrServerBehind"])
        let banner = app.descendants(matching: .any)["home.serverBehind"]
        app.buttons["debug.log"].tap()  // a response from the store's server (the connect's came before the store)
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        app.buttons["home.serverBehind.dismiss"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))

        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.serverBehind"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(banner.exists)
    }

    /// The widgets' "Update quickR" line (§4.1), in the widget gallery: the Home Screen's topic and
    /// due-list widgets and the Lock Screen's rectangular one.
    @MainActor
    func testWidgetsSayUpdateQuickR() {
        for (page, ids) in [
            ("home", ["widget.small.headache", "widget.medium.headache", "widget.medium.due"]),
            ("lock", ["widget.rect.water"]),
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-QuickrWidgetGallery", page, "outdated"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["widgets.gallery"].waitForExistence(timeout: 15))
            for id in ids {
                let widget = app.descendants(matching: .any)[id]
                XCTAssertTrue(widget.waitForExistence(timeout: 5), id)
                let line = widget.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", "Update quickR")).firstMatch
                XCTAssertTrue(line.exists, "\(id) has no update line")
            }
            app.terminate()
        }
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSyncControls", "-QuickrLevelControls"]
            + extra
        app.launch()
        XCTAssertTrue(app.buttons["debug.outdated"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 20))
        return app
    }
}

extension XCUIElement {
    fileprivate func waitForValue(_ value: String, timeout: TimeInterval = 10) -> Bool {
        wait(NSPredicate(format: "value == %@", value), timeout)
    }

    fileprivate func waitForEnabled(timeout: TimeInterval = 15) -> Bool {
        wait(NSPredicate(format: "enabled == true"), timeout)
    }

    fileprivate func waitForHittable(timeout: TimeInterval = 10) -> Bool {
        wait(NSPredicate(format: "hittable == true"), timeout)
    }

    private func wait(_ predicate: NSPredicate, _ timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
            == .completed
    }
}
