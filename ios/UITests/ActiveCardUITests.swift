import XCTest

/// Home's "Active now" card (active-surfaces.md §3.2) against the UI-test fake server's Morning
/// (timed, steps): its Pause is a real button, and the topic's pages (entries, stats, the builder
/// and settings) stay reachable while the run is open, from the card and from the run screen.
@MainActor
final class ActiveCardUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Starts Morning from its tile and returns its "Active now" card.
    private func startMorning(_ app: XCUIApplication) -> XCUIElement {
        let start = element(app, "tile.morning.run")
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(start.label.contains("Start"), start.label)
        start.tap()
        let active = element(app, "home.section.active")
        XCTAssertTrue(active.waitForExistence(timeout: 10))
        let card = element(app, "tile.morning")
        XCTAssertTrue(card.descendants(matching: .any)["tile.morning.stop"].firstMatch.waitForExistence(timeout: 10))
        // At the largest text size the list has scrolled on: back to the top, the card's title in view.
        for _ in 0..<4 where !active.isHittable { app.swipeDown() }
        return card
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Light, dark and light at the largest accessibility size: (appearance, launch arguments, name).
    private static let modes: [(XCUIDevice.Appearance, [String], String)] = [
        (.light, [], "light"), (.dark, [], "dark"),
        (.light, AccessibilityLaunch.arguments(contentSize: AccessibilityLaunch.xxxl), "xxxl"),
    ]

    /// The card with an open run in each mode (the evidence screenshots, docs/evidence/active-card/).
    func testActiveCardScreenshots() {
        for (appearance, extra, name) in Self.modes {
            XCUIDevice.shared.appearance = appearance
            let app = launch(extra)
            _ = startMorning(app)
            snap(app, "active-card-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    /// Pause is a real button (§3.2): a button element with a full 44 pt frame, clear of the
    /// clock; it pauses, and Resume takes its place. The "…" beside it is 44 pt too.
    func testPauseIsAButtonWithAFullTarget() {
        let app = launch()
        let card = startMorning(app)
        let pause = card.buttons["tile.morning.pause"]
        XCTAssertTrue(pause.exists, "Pause is a button element")
        XCTAssertTrue(pause.label.hasPrefix("Pause"), pause.label)
        XCTAssertGreaterThanOrEqual(pause.frame.height, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(pause.frame.width, 44 - 0.001)
        let clock = card.descendants(matching: .any)["tile.morning.segment"].firstMatch
        XCTAssertFalse(pause.frame.intersects(clock.frame), "\(pause.frame) clear of the clock \(clock.frame)")
        let menu = card.buttons["tile.morning.menu"]
        XCTAssertTrue(menu.exists, "the topic's pages")
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44 - 0.001)
        XCTAssertFalse(menu.frame.intersects(pause.frame))

        Thread.sleep(forTimeInterval: 0.6)  // past the run controls' tap cooldown (450 ms)
        pause.tap()
        let resume = card.buttons["tile.morning.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "Resume replaces Pause")
        XCTAssertGreaterThanOrEqual(resume.frame.height, 44 - 0.001)
        snap(app, "active-card-paused")
    }

    /// Picks `page` (a `TopicPage` id) in the menu `menu` opens.
    private func open(_ page: String, from menu: String, in app: XCUIApplication) {
        let trigger = element(app, menu)
        XCTAssertTrue(trigger.waitForExistence(timeout: 10), menu)
        trigger.tap()
        let item = app.buttons["\(menu == "run.menu" ? "run.topic" : menu).\(page)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(menu) offers \(page)")
        item.tap()
    }

    /// Checks the screen `page` opened, then goes back to the one before.
    private func checkAndReturn(_ page: String, in app: XCUIApplication) {
        switch page {
        case "entries":
            XCTAssertEqual(selectedTopicTab(in: app, timeout: 10), "Entries")
        case "stats":
            XCTAssertEqual(selectedTopicTab(in: app, timeout: 10), "Overview")
        case "edit":
            XCTAssertTrue(element(app, "editQuestions.q0.header").waitForExistence(timeout: 10), "the builder")
        default:
            XCTAssertTrue(element(app, "topicSettings.name").waitForExistence(timeout: 10), "the settings")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// The card's "…" opens the topic's entries, stats, builder and settings while the run is
    /// open; back on home the card is still there.
    func testTheCardMenuOpensTheTopicsPages() {
        let app = launch()
        _ = startMorning(app)
        for page in ["entries", "stats", "edit", "settings"] {
            open(page, from: "tile.morning.menu", in: app)
            if page == "entries" { snap(app, "active-card-menu-entries") }
            checkAndReturn(page, in: app)
            XCTAssertTrue(element(app, "tile.morning.stop").waitForExistence(timeout: 10), "the run is still open")
        }
    }

    /// The run screen's More menu lists the topic's pages too, under the run's own items.
    func testTheRunScreenMenuOpensTheTopicsPages() {
        let app = launch()
        let card = startMorning(app)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(element(app, "run.state").waitForExistence(timeout: 10), "the run screen")
        for page in ["settings", "entries"] {
            open(page, from: "run.menu", in: app)
            checkAndReturn(page, in: app)
            XCTAssertTrue(element(app, "run.state").waitForExistence(timeout: 10), "back on the run screen")
        }
    }
}
