import XCTest

// #294: the run screen's two clocks, on the fake server's "TikTok" (`-QuickrSeedTikTok`: a stopwatch
// with lap types Run and Rest). The total is the biggest thing on the screen; the open lap's clock
// is a second big clock (at least 60% of the total) with its label smaller; both sit above the
// controls. Each test attaches a screenshot before it asserts, so a failing layout still shows.
extension RunUITests {
    func testRunClocksInLight() {
        assertRunClocks(appearance: .light, name: "run-clocks-light")
    }

    func testRunClocksInDark() {
        assertRunClocks(appearance: .dark, name: "run-clocks-dark")
    }

    /// At the largest accessibility text size the label stacks above the lap clock, and nothing is
    /// cut off: both clocks fit the screen's width.
    func testRunClocksAtAnAccessibilitySize() {
        assertRunClocks(appearance: .light, name: "run-clocks-xxxl", extra: AccessibilityLaunch.arguments())
    }

    private func assertRunClocks(
        appearance: XCUIDevice.Appearance, name: String, extra: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCUIDevice.shared.appearance = appearance
        defer { XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTikTok",
                "-QuickrOpen", "quickr://t/tiktok/run",
            ] + extra
        app.launch()
        let find = { (id: String) in app.descendants(matching: .any)[id].firstMatch }

        // Start on the run screen and lap once: "Rest 1" is open.
        let start = find("run.start")
        XCTAssertTrue(start.waitForExistence(timeout: 20), "run.start", file: file, line: line)
        start.tap()
        let primary = find("run.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 10), file: file, line: line)
        Thread.sleep(forTimeInterval: 0.6)
        let segment = find("run.segment")
        XCTAssertTrue(clockWait(segment, containing: "Run 1"), segment.label, file: file, line: line)
        bringIntoFullView([primary], in: app)
        primary.tap()
        XCTAssertTrue(clockWait(segment, containing: "Rest 1"), segment.label, file: file, line: line)

        let total = find("run.total")
        bringIntoFullView([total, segment], in: app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(total.frame.height, 90, "the total is a big clock", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            segment.frame.height, total.frame.height * 0.6, "the lap clock is at least 60% of the total",
            file: file, line: line)
        if extra.isEmpty {
            // One row, label beside the clock: the element is the clock's height, so the ratio is
            // the clock's own, not padded by a stacked label.
            XCTAssertLessThan(
                segment.frame.height, total.frame.height, "label beside the lap clock", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(
            segment.frame.minY, total.frame.maxY, "the lap clock is under the total", file: file, line: line)
        for clock in [total, segment] {
            XCTAssertTrue(window.contains(clock.frame), "\(clock.identifier) fits the screen", file: file, line: line)
        }
        // Separation (M2): the controls come after the clocks.
        XCTAssertGreaterThanOrEqual(
            primary.frame.minY, segment.frame.maxY, "controls under the clocks", file: file, line: line)
        app.terminate()
    }

    private func clockWait(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
            == .completed
    }
}
