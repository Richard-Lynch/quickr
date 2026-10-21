#if targetEnvironment(simulator)
import XCTest

/// The milestone PR media (screenshots and GIFs; docs/ios/demo/m3), driven over the demo store:
/// the Siri confirmation snippet, logging from a reminder's action and logging from a Home Screen
/// widget. Each test attaches its screenshots; the capture script records the screen around a
/// test for its GIF. Each test also checks the log landed, so a capture is never of a broken flow.
///
/// Its own plan (Media), skipped in the UI plan: the notification and widget tests drive
/// SpringBoard, whose automation can stall for minutes (see WidgetGalleryTests), so the capture
/// script runs them one at a time under a wall-clock limit. Simulator only: on a device the demo
/// can't reach the App Group, and a real widget's ✓ would log real data.
final class MediaCaptureUITests: XCTestCase {
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() {
        continueAfterFailure = false
    }

    /// The confirmation snippet over demo drafts; its ± runs the snippet's intent, as in Siri.
    @MainActor
    func testSiriConfirmationSnippet() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrSnippetGallery"]
        app.launch()
        let workout = app.descendants(matching: .any)["snippet.card.workout"]
        XCTAssertTrue(workout.waitForExistence(timeout: 15))
        let minutes = app.staticTexts.matching(NSPredicate(format: "label == 'Minutes' AND value CONTAINS '30'"))
        XCTAssertTrue(minutes.firstMatch.waitForExistence(timeout: 5), "the draft's answer")
        snap("siri-snippet")
        app.buttons["More Minutes"].firstMatch.tap()
        let stepped = app.staticTexts.matching(NSPredicate(format: "label == 'Minutes' AND value CONTAINS '31'"))
        XCTAssertTrue(stepped.firstMatch.waitForExistence(timeout: 5), "+ steps the held draft")
        XCTAssertTrue(app.descendants(matching: .any)["snippet.card.check-in"].exists)
    }

    /// A due reminder for Water (`-QuickrDemoNotify`) over the shared demo store, expanded to its
    /// actions; "Log 3 glasses" logs from the background (in the suspended app, or one the system
    /// launches without the demo arguments: hence the shared store), and the entry waits to sync.
    @MainActor
    func testLogFromANotification() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore", "-QuickrDemoShared", "fresh", "-QuickrDemoNotify", "water", "20"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Water"].firstMatch.waitForExistence(timeout: 20), "the demo home")
        // Home before the reminder fires: in the foreground, §7.2 may keep it from showing.
        allowNotifications()
        XCUIDevice.shared.press(.home)

        let banner = springboard.descendants(matching: .any)["NotificationShortLookView"]
        let shown = banner.waitForExistence(timeout: 60)
        snap("notification-banner")
        XCTAssertTrue(shown, "the reminder's banner")
        banner.press(forDuration: 1.2)
        let log = springboard.buttons["Log 3 glasses"]
        XCTAssertTrue(log.waitForExistence(timeout: 10), "the reminder's actions")
        snap("notification-actions")
        log.tap()

        // The app that handled it (suspended, or launched afresh for the action) comes forward;
        // relaunched, it keeps the shared demo as the action left it.
        app.launchArguments = Self.keep
        app.activate()
        app.open(URL(string: "quickr://t/water/entries")!)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 30), "the action's entry, waiting to sync")
        snap("notification-logged")
    }

    /// The Water widget on the Home Screen over the shared demo store (`-QuickrDemoShared`): its
    /// ✓ logs the last answer without the app, the widget shows it queued, and the app has it.
    @MainActor
    func testLogFromAWidget() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore", "-QuickrDemoShared", "fresh"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Water"].firstMatch.waitForExistence(timeout: 20), "the demo home")
        removeQuickRWidgets()
        defer { removeQuickRWidgets() }
        addWidget(topic: "Water")
        snap("widget-home")

        let check = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Log 3 glasses'")).firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 10), "the widget's ✓")
        check.tap()
        let queued = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'waiting to sync'")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 15), "the widget shows the log queued")
        snap("widget-logged")

        relaunchOnWaterEntries(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 15), "the widget's entry, in the app")
        snap("widget-logged-app")
    }

    // MARK: - Helpers

    /// The shared demo as it now is (kept, not reseeded).
    static let keep = ["-QuickrDemoStore", "-QuickrDemoShared"]

    /// The app again over the shared demo, on Water's entries.
    @MainActor
    private func relaunchOnWaterEntries(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = Self.keep + ["-QuickrOpen", "quickr://t/water/entries"]
        app.launch()
    }

    @MainActor
    private func pending(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pending.'")).firstMatch
    }

    /// The permission prompt, when this simulator hasn't answered it yet.
    @MainActor
    private func allowNotifications() {
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    /// WidgetGalleryTests' steps: Home Screen edit mode → Add Widget → quickR → the first (topic)
    /// widget, then Edit Widget → its topic.
    @MainActor
    private func addWidget(topic: String) {
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 2)
        tap(springboard.buttons["Edit"])
        for attempt in 1...4 {
            tap(springboard.buttons["Add Widget"])
            let search = springboard.searchFields.firstMatch
            tap(search)
            search.typeText("quickR")
            if springboard.buttons["Continue"].exists { springboard.buttons["Continue"].tap() }
            if springboard.cells["quickR"].waitForExistence(timeout: 10) || attempt == 4 { break }
            tap(springboard.buttons["Close"])
            sleep(5)
        }
        tap(springboard.cells["quickR"])
        sleep(2)
        // By position: querying SpringBoard while the live preview is up can stall (WidgetGalleryTests).
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.905)).tap()
        tap(springboard.buttons["Done"])
        let widget = quickRWidgets.firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 10), "the widget is on the Home Screen")
        widget.press(forDuration: 1.5)
        tap(springboard.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"])
        tap(springboard.buttons["Choose"])
        tap(springboard.staticTexts[topic].firstMatch)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            springboard.staticTexts[topic].firstMatch.waitForExistence(timeout: 15), "the widget shows \(topic)")
    }

    @MainActor private var quickRWidgets: XCUIElementQuery {
        springboard.icons.matching(NSPredicate(format: "label == 'quickR' AND value == 'Widget'"))
    }

    /// Leaves the Home Screen without quickR widgets (as WidgetGalleryTests does).
    @MainActor
    private func removeQuickRWidgets() {
        XCUIDevice.shared.press(.home)
        for _ in 0..<5 where quickRWidgets.firstMatch.waitForExistence(timeout: 2) {
            for _ in 0..<3 where !quickRWidgets.firstMatch.isHittable { springboard.swipeLeft() }
            quickRWidgets.firstMatch.press(forDuration: 1.5)
            tap(springboard.buttons["com.apple.springboardhome.application-shortcut-item.remove-widget"])
            tap(springboard.alerts.buttons["Remove"])
            sleep(1)
        }
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 10) else {
            snap("missing")
            return XCTFail("missing \(element)", file: file, line: line)
        }
        element.tap()
    }

    @MainActor
    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
