import XCTest

/// Settings ▸ "Offline & sync", About and Licences, against the fake server (`-QuickrUITest`) with
/// the sync debug controls (`-QuickrSyncControls`: offline, online, log an entry).
final class AppSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSyncSectionFollowsTheOutboxAndTheNetwork() {
        let app = launch(extra: ["-QuickrSyncControls"])
        let headline = element(app, "settings.sync.headline")
        XCTAssertTrue(headline.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: headline, label: "All changes synced"))
        XCTAssertEqual(element(app, "settings.sync.connection").label, "Online")
        XCTAssertNotEqual(element(app, "settings.sync.last").label, "Never", "the launch pulled")
        snap(app, "appset-1-synced")

        // Offline, an entry waits; the sheet's items are a tap away.
        app.buttons["debug.offline"].tap()
        XCTAssertTrue(wait(for: element(app, "settings.sync.connection"), label: "Offline"))
        app.buttons["debug.log"].tap()
        XCTAssertTrue(wait(for: headline, label: "Offline · 1 waiting to sync"))
        XCTAssertTrue(element(app, "settings.sync.review").exists)
        snap(app, "appset-2-offline")
        element(app, "settings.sync.review").tap()
        XCTAssertTrue(app.descendants(matching: .any)["sync.sheet"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["sync.done"].tap()

        // Back online: Sync now sends it.
        app.buttons["debug.online"].tap()
        element(app, "settings.syncNow").tap()
        XCTAssertTrue(wait(for: headline, label: "All changes synced", timeout: 20))
        XCTAssertFalse(element(app, "settings.sync.review").exists)
    }

    @MainActor
    func testLicencesShowEachText() {
        let app = launch()
        let licences = element(app, "settings.licences")
        XCTAssertTrue(element(app, "settings.sync.headline").waitForExistence(timeout: 20))
        for _ in 0..<6 where !licences.isHittable { app.swipeUp() }
        licences.tap()
        XCTAssertTrue(element(app, "licences.list").waitForExistence(timeout: 5))
        snap(app, "appset-3-licences")
        for (name, marker) in [
            ("GRDB.swift", "Permission is hereby granted"), ("Bricolage Grotesque", "SIL OPEN FONT LICENSE"),
        ] {
            element(app, "licence.\(name)").tap()
            let text = element(app, "licence.text")
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            XCTAssertTrue(text.label.contains(marker), "\(name): \(text.label.prefix(80))")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    func testAccessibilityXXXL() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let headline = element(app, "settings.sync.headline")
        for _ in 0..<6 where !(headline.exists && headline.isHittable) { app.swipeUp() }
        XCTAssertTrue(headline.waitForExistence(timeout: 20))
        snap(app, "appset-4-ax")
    }

    // MARK: - Helpers

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://settings"] + extra
        app.launch()
        return app
    }
}
