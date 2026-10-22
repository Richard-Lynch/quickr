import XCTest

/// PLAN M1 platform proof, widget half: `TopicEntity` resolves **in the widget extension**.
/// linkd folds the extension's intents metadata into the app's (`com.bahumia.quickr`), so
/// AppIntentsTesting can't address the extension by bundle id; this drives SpringBoard instead.
/// Each step only works if the extension ran the package's query in its own process:
/// - the gallery preview is the extension's `snapshot`, which reads `TopicEntityQuery`;
/// - the configuration's topic picker lists the extension's `TopicEntityQuery.allEntities()`;
/// - after picking, the extension's timeline renders the resolved `TopicEntity`'s name.
/// Screenshots of each step are attached to the result bundle.
///
/// Not in the UI plan: SpringBoard automation intermittently stalls for many minutes (an
/// accessibility snapshot of SpringBoard that never returns, on iOS 26 and 27), which XCTest's
/// timeouts don't catch. It has its own plan, run on demand: `ios/scripts/widget-proof.sh <sim>`.
final class WidgetGalleryTests: XCTestCase {
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    @MainActor private var quickRWidgets: XCUIElementQuery {
        springboard.icons.matching(NSPredicate(format: "label == 'quickR' AND value == 'Widget'"))
    }

    /// Leaves the Home Screen as it was, so a rerun on the same simulator starts from no widget.
    @MainActor
    private func removeQuickRWidgets() {
        XCUIDevice.shared.press(.home)
        for _ in 0..<5 where quickRWidgets.firstMatch.waitForExistence(timeout: 2) {
            // Home goes to the first page; earlier runs may have left the widget on another one.
            for _ in 0..<3 where !quickRWidgets.firstMatch.isHittable { springboard.swipeLeft() }
            quickRWidgets.firstMatch.press(forDuration: 1.5)
            tap(springboard.buttons["com.apple.springboardhome.application-shortcut-item.remove-widget"])
            tap(springboard.alerts.buttons["Remove"])
            sleep(1)
        }
    }

    @MainActor
    func testTopicWidgetResolvesTopicEntityInTheExtension() throws {
        XCUIApplication().launch()  // installs the build, registering the widget
        removeQuickRWidgets()
        defer { removeQuickRWidgets() }

        // Home Screen edit mode → Edit → Add Widget → search → quickR.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 2)
        tap(springboard.buttons["Edit"])
        // Right after an install the gallery may not list the extension yet: reopen it until it does.
        for attempt in 1...4 {
            tap(springboard.buttons["Add Widget"])
            let search = springboard.searchFields.firstMatch
            tap(search)
            search.typeText("quickR")
            // The first-run keyboard tip covers the results.
            if springboard.buttons["Continue"].exists { springboard.buttons["Continue"].tap() }
            if springboard.cells["quickR"].waitForExistence(timeout: 10) || attempt == 4 { break }
            tap(springboard.buttons["Close"])
            sleep(5)
        }
        tap(springboard.cells["quickR"])
        sleep(2)  // the preview renders asynchronously
        attach("gallery")
        // By position: querying SpringBoard while the live preview is up can stall the accessibility
        // snapshot (it waits on the extension) for many minutes.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.905)).tap()
        tap(springboard.buttons["Done"])
        let widget = quickRWidgets.firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 10), "the widget is on the Home Screen")
        XCTAssertTrue(springboard.staticTexts["Choose a topic"].waitForExistence(timeout: 10), "unconfigured")

        // Long press → Edit Widget → the Topic parameter → its picker.
        widget.press(forDuration: 1.5)
        tap(springboard.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"])
        tap(springboard.buttons["Choose"])
        XCTAssertTrue(springboard.staticTexts["Coffee"].waitForExistence(timeout: 10), "the picker lists topics")
        XCTAssertTrue(springboard.staticTexts["Mood"].exists)
        XCTAssertFalse(springboard.staticTexts["Old habit"].exists, "archived topics stay out of pickers")
        attach("picker")

        tap(springboard.staticTexts["Coffee"])
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.staticTexts["Coffee"].waitForExistence(timeout: 15), "the widget shows the topic")
        attach("configured")
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 10) else {
            attach("missing")
            return XCTFail("missing \(element)", file: file, line: line)
        }
        element.tap()
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "skel-widget-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
