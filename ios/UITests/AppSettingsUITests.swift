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
        XCTAssertTrue(reveal(headline, in: app))
        XCTAssertTrue(wait(for: headline, label: "All changes synced"))
        XCTAssertTrue(wait(for: element(app, "settings.sync.connection"), label: "Online"))
        XCTAssertFalse(value(of: element(app, "settings.sync.last")).isEmpty)
        XCTAssertNotEqual(value(of: element(app, "settings.sync.last")), "Never", "the launch pulled")
        snap(app, "appset-1-synced")

        // Offline, an entry waits; the sheet's items are a tap away.
        app.buttons["debug.offline"].tap()
        XCTAssertTrue(wait(for: element(app, "settings.sync.connection"), label: "Offline"))
        app.buttons["debug.log"].tap()
        XCTAssertTrue(wait(for: headline, label: "Offline · 1 waiting to sync"))
        let review = element(app, "settings.sync.review")
        XCTAssertTrue(reveal(review, in: app))
        snap(app, "appset-2-offline")
        review.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sync.sheet"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["sync.done"].tap()

        // Back online: Sync now sends it and pulls.
        app.buttons["debug.online"].tap()
        let syncNow = element(app, "settings.syncNow")
        XCTAssertTrue(reveal(syncNow, in: app))
        syncNow.tap()
        XCTAssertTrue(wait(for: headline, label: "All changes synced", timeout: 20))
        XCTAssertTrue(wait(for: element(app, "settings.sync.connection"), label: "Online"))
        XCTAssertFalse(review.exists)
    }

    /// Every licence opens and shows its text.
    @MainActor
    func testEveryLicenceOpens() {
        let app = launch()
        openLicences(app)
        snap(app, "appset-3-licences")
        for (name, marker) in [
            ("GRDB.swift", "Permission is hereby granted"),
            ("Bricolage Grotesque", "The Bricolage Grotesque Project Authors"),
            ("Instrument Sans", "The Instrument Sans Project Authors"),
            ("JetBrains Mono", "The JetBrains Mono Project Authors"),
        ] {
            openLicence(name, marker: marker, in: app)
        }
    }

    /// At XXXL the section's actions are reachable and a licence opens.
    @MainActor
    func testAccessibilityXXXL() throws {
        let app = launch(extra: AccessibilityLaunch.arguments())
        XCTAssertTrue(reveal(element(app, "settings.sync.headline"), in: app))
        try assertAccessible(app)
        XCTAssertTrue(reveal(element(app, "settings.syncNow"), in: app), "Sync now is reachable")
        snap(app, "appset-4-ax")
        element(app, "settings.syncNow").tap()
        openLicences(app)
        openLicence("GRDB.swift", marker: "Permission is hereby granted", in: app)
    }

    // MARK: - Helpers

    @MainActor
    private func openLicences(_ app: XCUIApplication) {
        let licences = element(app, "settings.licences")
        XCTAssertTrue(reveal(licences, in: app), "Licences is reachable")
        licences.tap()
        XCTAssertTrue(element(app, "licences.list").waitForExistence(timeout: 5))
    }

    @MainActor
    private func openLicence(_ name: String, marker: String, in app: XCUIApplication) {
        let row = element(app, "licence.\(name)")
        XCTAssertTrue(reveal(row, in: app), "\(name) is listed")
        row.tap()
        let text = element(app, "licence.text")
        XCTAssertTrue(text.waitForExistence(timeout: 5), name)
        XCTAssertTrue(text.label.contains(marker), "\(name): \(text.label.prefix(80))")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Scrolls until `element` is on screen and hittable (lists build rows lazily).
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 10), element.isHittable { return true }
        for _ in 0..<12 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// A `LabeledContent` row's value ("Never" in "Last synced, Never").
    private func value(of element: XCUIElement) -> String {
        guard let comma = element.label.range(of: ", ") else { return element.label }
        return String(element.label[comma.upperBound...])
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// A `LabeledContent` row reads as one element, "Status, All changes synced": its value is what
    /// follows the label. A badge reads as just its text.
    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR label ENDSWITH %@", label, ", " + label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
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
