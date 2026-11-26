#if targetEnvironment(simulator)
import XCTest

/// T2-M1's PR media (docs/t2/evidence/M1): the builder's lap types, variables and alerts editors,
/// and a lap alert's banner in the foreground. Each test attaches its screenshots (exported from
/// the xcresult; dark is the simulator's appearance set before the run) and checks what it shows,
/// so a capture is never of a broken screen. In the Media plan, skipped in the UI plan: the alert
/// asks SpringBoard for permission and waits for its banner.
final class T2M1MediaUITests: XCTestCase {
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTimerEditors() {
        timerEditors(extra: [], suffix: "")
    }

    @MainActor
    func testTimerEditorsAtTheLargestTextSize() {
        timerEditors(
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            suffix: "-xxxl")
    }

    /// TikTok with an alert 5 s into each Run lap (`-QuickrTikTokAlert`): notifications allowed in
    /// Settings, a run started, and the alert's banner shows over the run screen.
    @MainActor
    func testLapAlertInTheForeground() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTikTok", "-QuickrTikTokAlert",
        ]
        app.launch()
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        // Asked once per simulator: a rerun finds it allowed already.
        let allow = find("notifications.allow", in: app)
        let allowed = find("notifications.allowed", in: app)
        reveal(allow, in: app)
        if !allowed.exists {
            XCTAssertTrue(allow.waitForExistence(timeout: 10))
            allow.tap()
            let system = springboard.alerts.buttons["Allow"]
            XCTAssertTrue(system.waitForExistence(timeout: 10))
            system.tap()
        }
        XCTAssertTrue(allowed.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let tileButton = find("tile.tiktok.run", in: app)
        XCTAssertTrue(tileButton.waitForExistence(timeout: 15))
        tileButton.tap()
        Thread.sleep(forTimeInterval: 0.6)
        find("tile.tiktok", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(find("run.lap", in: app).waitForExistence(timeout: 10))
        snap(app, "i1-alert-run")

        let banner = springboard.descendants(matching: .any)["NotificationShortLookView"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the alert's banner")
        snapScreen("i1-alert-banner")
        XCTAssertTrue(banner.label.contains("Cue"), banner.label)
    }

    // MARK: Helpers

    @MainActor
    private func timerEditors(extra: [String], suffix: String) {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://t/mood/edit"] + extra
        app.launch()
        XCTAssertTrue(find("editQuestions.q0.header", in: app).waitForExistence(timeout: 15))
        let timed = app.switches["editQuestions.timed"]
        reveal(timed, in: app)
        timed.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(timed.value as? String, "1")
        press("editQuestions.addLapType", in: app)
        typeInto(app.textFields["editQuestions.lap0.label"], "Run", in: app)
        press("editQuestions.addLapType", in: app)
        typeInto(app.textFields["editQuestions.lap1.label"], "Rest", in: app)
        press("editQuestions.addVariable", in: app)
        typeInto(app.textFields["editQuestions.variable0.name"], "t", in: app)
        typeInto(app.textFields["editQuestions.variable0.duration"], "1:00", in: app)
        press("editQuestions.lap0.alerts", in: app)
        press("editQuestions.lap0.addAlert", in: app)
        typeInto(app.textFields["editQuestions.lap0.alert0.label"], "Halfway", in: app)
        typeInto(app.textFields["editQuestions.lap0.alert0.at"], "t/2", in: app)

        let lap = app.textFields["editQuestions.lap1.label"]
        reveal(lap, in: app)
        XCTAssertTrue(lap.isHittable)
        snap(app, "i1-builder-lap-types\(suffix)")
        let variable = app.textFields["editQuestions.variable0.duration"]
        reveal(variable, in: app)
        XCTAssertTrue(variable.isHittable)
        snap(app, "i1-builder-variables\(suffix)")
        let result = find("editQuestions.lap0.alert0.result", in: app)
        reveal(result, in: app)
        XCTAssertEqual(result.label, "at 0:30")
        snap(app, "i1-builder-alerts\(suffix)")
    }

    @MainActor
    private func find(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func press(_ id: String, in app: XCUIApplication) {
        let target = find(id, in: app)
        reveal(target, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), id)
        target.tap()
    }

    @MainActor
    private func typeInto(_ field: XCUIElement, _ text: String, in app: XCUIApplication) {
        reveal(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), field.debugDescription)
        field.tap()
        field.typeText(text)
        if app.keyboards.firstMatch.exists { app.navigationBars.firstMatch.tap() }
        XCTAssertEqual(field.value as? String, text)
    }

    /// Drags until `element` is whole on screen (bounded), toward where it is.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        func shown() -> Bool { element.exists && element.isHittable && app.frame.contains(element.frame) }
        func drag(up: Bool) {
            let (from, to) = up ? (0.2, 0.55) : (0.45, 0.12)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        let above = element.exists && element.frame.midY < app.frame.midY
        for _ in 0..<10 where !shown() { drag(up: above) }
        for _ in 0..<10 where !shown() { drag(up: !above) }
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The whole screen (SpringBoard's banner over the app).
    @MainActor
    private func snapScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
