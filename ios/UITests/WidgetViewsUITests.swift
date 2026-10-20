import XCTest

/// The widget views (the extension's own), in the app's widget gallery: each family shows its
/// content in light, dark, the tinted approximation and at an accessibility text size. Screenshots
/// go to the results (docs/ios/demo/m3). SpringBoard's own widget proof is `widget-proof.sh`.
final class WidgetViewsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ page: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrWidgetGallery", page] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["widgets.gallery"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func widget(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[id]
        XCTAssertTrue(element.waitForExistence(timeout: 5), id)
        return element
    }

    @MainActor
    private func shows(_ element: XCUIElement, _ fragment: String) -> Bool {
        element.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch.exists
            || element.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment))
                .firstMatch.exists
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Home Screen families: a topic with chips and its last answer, a number topic that is
    /// queued, and the due list (due first), in light and dark.
    @MainActor
    func testHomeScreenWidgetsInLightAndDark() {
        for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            let app = launch("home")
            let headache = widget(app, "widget.small.headache")
            XCTAssertTrue(shows(headache, "Headache"))
            XCTAssertTrue(shows(headache, "Mild"), "the last answer")
            let water = widget(app, "widget.small.water")
            XCTAssertTrue(shows(water, "waiting to sync") || shows(water, "1"), "queued")
            XCTAssertTrue(shows(water, "✓"), "✓ last")
            let due = widget(app, "widget.medium.due")
            XCTAssertTrue(shows(due, "DUE NOW"))
            snap(app, "widgets-home-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    /// Lock Screen families (and the Home Screen's tinted mode): one colour, accented parts.
    @MainActor
    func testLockScreenAndTintedWidgets() {
        let lock = launch("lock")
        XCTAssertTrue(shows(widget(lock, "widget.rect.due"), "due"))
        XCTAssertTrue(shows(widget(lock, "widget.rect.water"), "Water"))
        _ = widget(lock, "widget.circle.headache")
        XCTAssertTrue(shows(widget(lock, "widget.circle.due"), "due"))
        _ = widget(lock, "widget.inline.due")
        snap(lock, "widgets-lock")
        lock.terminate()

        let tinted = launch("home", ["tinted"])
        XCTAssertTrue(shows(widget(tinted, "widget.small.headache"), "Headache"))
        snap(tinted, "widgets-home-tinted")
    }

    /// At the largest accessibility size the widgets still show their name and controls (text
    /// shrinks or truncates; nothing overlaps off the widget).
    @MainActor
    func testWidgetsAtAnAccessibilityTextSize() {
        let app = launch("home", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let headache = widget(app, "widget.small.headache")
        XCTAssertTrue(shows(headache, "Headache"))
        snap(app, "widgets-home-ax")
    }
}
