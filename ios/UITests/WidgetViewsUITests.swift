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
            XCTAssertTrue(shows(water, "Log 3 glasses"), "✓ last, read as the tile reads it")
            let due = widget(app, "widget.medium.due")
            XCTAssertTrue(shows(due, "due now"), "the header reads as one \"<n> due now\" heading")
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

    /// The timed states (active-surfaces.md §5.1, §5.3) in light, dark, tinted and at an
    /// accessibility size: a stopwatch's Lap with Stop beside it, the small size's one Auto chip
    /// (Stop on a stopwatch without lap types, Next while a step remains), and a paused run. Each
    /// widget is attached on its own (`widgets-timed-<mode>-<state>`). The alert state (a typed lap
    /// with a pending alert) is checked for clipping too.
    @MainActor
    func testTimedWidgetsShowTheLapPrimary() {
        let modes: [(name: String, appearance: XCUIDevice.Appearance, extra: [String])] = [
            ("light", .light, []), ("dark", .dark, []), ("tinted", .light, ["tinted"]),
            ("ax", .light, ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
        ]
        for mode in modes {
            XCUIDevice.shared.appearance = mode.appearance
            let app = launch("home", mode.extra)
            let lap = reveal(app, "widget.medium.timed.lap")
            XCTAssertTrue(shows(lap, "Lap 3"), "\(mode.name): the open lap")
            XCTAssertEqual(buttons(lap, "Lap"), 1, "\(mode.name): Lap once, the primary")
            XCTAssertEqual(buttons(lap, "Stop"), 1, "\(mode.name): Stop beside it")
            XCTAssertEqual(buttons(lap, "Next"), 0, "\(mode.name): no Next on a stopwatch")
            snapWidget(lap, "widgets-timed-\(mode.name)-lap")
            let typed = reveal(app, "widget.medium.timed.typedlap")
            XCTAssertEqual(buttons(typed, "Lap"), 1, "\(mode.name): typed lap's primary")
            XCTAssertEqual(buttons(typed, "Stop"), 1)
            snapWidget(typed, "widgets-timed-\(mode.name)-typedlap")
            let auto = reveal(app, "widget.small.timed.auto")
            XCTAssertEqual(buttons(auto, "Stop"), 1, "\(mode.name): a stopwatch's Auto chip is Stop")
            XCTAssertEqual(buttons(auto, "Lap"), 0, "\(mode.name): one chip on the small size")
            snapWidget(auto, "widgets-timed-\(mode.name)-auto")
            let step = reveal(app, "widget.small.timed.step")
            XCTAssertEqual(buttons(step, "Next: Breakfast"), 1, "\(mode.name): Next while a step remains")
            XCTAssertEqual(buttons(step, "Stop"), 0)
            snapWidget(step, "widgets-timed-\(mode.name)-step")
            let paused = reveal(app, "widget.medium.timed.paused")
            XCTAssertTrue(shows(paused, "Paused"), "\(mode.name): paused")
            snapWidget(paused, "widgets-timed-\(mode.name)-paused")
            // After paused (the gallery's order; `reveal` only scrolls down). The typed lap's
            // headline with the pending alert beside the total (§5.1); no labelled element runs
            // past the widget's edge (truncation inside a frame is checked on the screenshots).
            let alert = reveal(app, "widget.medium.timed.alert")
            XCTAssertTrue(shows(alert, "Go"), "\(mode.name): the alert's label")
            XCTAssertEqual(buttons(alert, "Lap"), 1, "\(mode.name): the alert widget's primary")
            XCTAssertEqual(buttons(alert, "Stop"), 1)
            assertInside(alert, mode.name)
            snapWidget(alert, "widgets-timed-\(mode.name)-alert")
            snap(app, "widgets-timed-\(mode.name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    /// Scrolls the gallery until the widget is wholly on screen.
    @MainActor
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[id]
        let window = app.windows.firstMatch.frame
        for _ in 0..<10 where !(element.exists && window.contains(element.frame)) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
        }
        XCTAssertTrue(element.exists && window.contains(element.frame), "\(id) on screen")
        return element
    }

    /// Every labelled element of the widget lies wholly inside its frame: a guard against content
    /// pushed past the edge. The widget combines its text into one element, so truncation inside it
    /// is checked on the attached screenshots, not here.
    @MainActor
    private func assertInside(_ widget: XCUIElement, _ mode: String) {
        let bounds = widget.frame.insetBy(dx: -1, dy: -1)
        let parts = widget.descendants(matching: .any).allElementsBoundByIndex.filter {
            !$0.label.isEmpty && $0.frame.width > 0
        }
        XCTAssertFalse(parts.isEmpty, "\(mode): the widget's parts")
        for part in parts where !bounds.contains(part.frame) {
            XCTFail("\(mode): \"\(part.label)\" \(part.frame) runs outside \(widget.identifier) \(widget.frame)")
        }
    }

    /// How many of the widget's controls (links, buttons) are labelled starting with `title`.
    @MainActor
    private func buttons(_ element: XCUIElement, _ title: String) -> Int {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", title)
        return element.buttons.matching(predicate).count + element.links.matching(predicate).count
    }

    @MainActor
    private func snapWidget(_ element: XCUIElement, _ name: String) {
        let shot = XCTAttachment(screenshot: element.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
