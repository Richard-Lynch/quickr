import XCTest

/// Water's entries over the debug demo store, with `-QuickrDemoOutbox`: a refused log and one
/// waiting to sync pinned on top (the refused one first: it was logged first), then the server's
/// entries, newest first, some from a second source ("shortcut").
final class EntriesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrDemoStore", "-QuickrDemoOutbox", "-QuickrOpen", "quickr://t/water/entries"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["entries.count"].waitForExistence(timeout: 20))
        return app
    }

    /// The rows themselves (`entry.<uuid>`, `pending.<uuid>`), not their identified children
    /// (`entry.<uuid>.summary`, `.timing`), which XCUITest lists under a combined row too.
    @MainActor
    private func rows(_ app: XCUIApplication, _ prefix: String) -> XCUIElementQuery {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: prefix) + "[0-9a-fA-F-]{36}$"
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", pattern))
    }

    @MainActor
    private func count(_ app: XCUIApplication) -> Int {
        Int(app.staticTexts["entries.count"].label.split(separator: " ")[0].replacingOccurrences(of: ",", with: ""))!
    }

    /// A timed row (content-display.md §3.1), one accessibility element: its summary line, then
    /// its timing chip spoken with the lap count. Intervals' newest run (`-QuickrSeedTypedTopic`,
    /// `FakeLapTypes`): 5:00 active in typed laps, a 20 s pause that the chip leaves out, Effort 7.
    @MainActor
    func testRowShowsSummaryAndTiming() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTypedTopic", "-QuickrOpen",
            "quickr://t/intervals/entries",
        ]
        app.launch()
        let row = app.descendants(matching: .any)["entry.00000000-0000-4000-8000-0000000000f1"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let label = row.label
        let summary = label.range(of: "5:00 · Run 3 · Rest 2 · Effort: 7")
        let chip = label.range(of: "5 minutes, 5 laps")
        XCTAssertNotNil(summary, "the summary line in \(label)")
        XCTAssertNotNil(chip, "the chip's spoken text in \(label)")
        if let summary, let chip { XCTAssertLessThan(summary.upperBound, chip.lowerBound, "summary, then chip") }
    }

    /// Intervals (`-QuickrSeedTypedTopic`, `FakeLapTypes`) on the fake server, its entries list
    /// showing the newest run (`f1`).
    @MainActor
    private func launchTyped(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedTypedTopic", "-QuickrOpen",
                "quickr://t/intervals/entries",
            ] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[Self.newest].waitForExistence(timeout: 20))
        return app
    }

    /// Intervals' newest run: 5:00 active, a 20 s pause in Rest 1, logged yesterday.
    private static let newestId = "00000000-0000-4000-8000-0000000000f1"
    private static let newest = "entry.\(newestId)"

    @MainActor
    private func find(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Remove on a pause row (content-display.md §3.2): it confirms, then the pause's time turns
    /// active. Offline, the remove queues: the row goes and the total grows at once, with
    /// "Waiting" (A14); back online the fake server applies it (`FakeLapTypes.record`) and the
    /// ack's entry (revision 2) clears the mark.
    @MainActor
    func testRemovePauseFromEntryDetail() {
        let app = launchTyped(["-QuickrSyncControls"])
        find(app, Self.newest).tap()
        let pause = find(app, "entry.timing.pause.0")
        let total = find(app, "entry.timing.total")
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "the newest run's pause row")
        XCTAssertEqual(pause.label, "Paused, 20 seconds")
        XCTAssertEqual(total.label, "Total 5 minutes")
        XCTAssertFalse(find(app, "entry.timing.pending").exists)

        find(app, "debug.offline").tap()
        find(app, "entry.timing.pause.remove.0").tap()
        let alert = app.alerts["Remove this pause?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the confirmation")
        // SwiftUI lists the alert's action twice under the alert: the first is the button.
        alert.buttons["entry.timing.remove.confirm"].firstMatch.tap()

        XCTAssertTrue(find(app, "entry.timing.pending").waitForExistence(timeout: 10), "Waiting while queued")
        XCTAssertTrue(waitForAbsence(pause), "the pause row is gone")
        XCTAssertTrue(waitForLabel(total, "Total 5 minutes 20 seconds"), "its 20 s became active")

        find(app, "debug.online").tap()
        XCTAssertTrue(waitForAbsence(find(app, "entry.timing.pending"), timeout: 20), "the ack clears Waiting")
        XCTAssertFalse(find(app, "entry.timing.pause.0").exists)
        XCTAssertEqual(total.label, "Total 5 minutes 20 seconds")
        XCTAssertTrue(find(app, "entry.timing.segment.1").label.hasPrefix("Rest 1"), "the laps stay")
    }

    /// Resume run (content-display.md §3.2): the run reopens and the screen goes to it, Running
    /// once the fake server's ack lands. The entry is then the open run (OQ-14): the list hides
    /// it, so it offers neither Remove nor Resume.
    @MainActor
    func testResumeRunFromEntryDetail() {
        let app = launchTyped()
        find(app, Self.newest).tap()
        let resume = app.buttons["entry.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "yesterday's run is within the 7 days")
        resume.tap()

        let state = find(app, "run.state")
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the run screen")
        XCTAssertTrue(waitForLabel(state, "Running", timeout: 15), "Running, not \(state.label)")
        // The reopen is no longer only on this device: the fake server acked it.
        XCTAssertTrue(waitForAbsence(app.staticTexts["Saved on this device"], timeout: 15), "the ack")
        XCTAssertEqual(state.label, "Running")

        // Back to the list (the run took the detail's place): the open run's entry isn't there.
        // An `app.open` link would relaunch the app, and with it the fake server.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            find(app, "entry.00000000-0000-4000-8000-0000000000f2").waitForExistence(timeout: 10), "the list")
        XCTAssertTrue(waitForAbsence(find(app, Self.newest)), "the open run's entry is hidden")
        XCTAssertFalse(app.buttons["entry.resume"].exists, "no Resume")
        XCTAssertFalse(find(app, "entry.timing.pause.remove.0").exists, "no Remove")
    }

    /// Device-only logs pin on top, in the order they were logged; the count says so.
    @MainActor
    func testUnsyncedEntriesPinAboveTheList() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["entries.count"].label.hasSuffix("· 2 not synced yet"))
        let pinned = rows(app, "pending.")
        XCTAssertEqual(pinned.count, 2)
        XCTAssertTrue(pinned.element(boundBy: 0).label.contains("Failed — tap to fix"))
        XCTAssertTrue(pinned.element(boundBy: 0).label.contains("glasses: must be at most 20"))
        XCTAssertTrue(pinned.element(boundBy: 1).label.contains("Waiting to sync"))
        let first = rows(app, "entry.").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(pinned.element(boundBy: 1).frame.maxY, first.frame.minY, "pinned above the list")
    }

    /// Swipe to delete: the entry goes and a toast offers Undo, which brings it back.
    @MainActor
    func testSwipeDeleteThenUndo() {
        let app = launch()
        let before = count(app)
        let first = rows(app, "entry.").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let id = first.identifier
        first.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("\(before - 1) "))
        XCTAssertFalse(app.descendants(matching: .any)[id].exists)

        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["Entry restored"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("\(before) "))
        XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5))
    }

    /// An entry opens its edit screen; a refused one opens RECORD's screen to fix it.
    @MainActor
    func testTappingOpensEditOrFix() {
        let app = launch()
        rows(app, "entry.").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["edit.save"].waitForExistence(timeout: 10), "EDIT's screen")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // RECORD's screen in fix mode, on the refused log.
        rows(app, "pending.").element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["record.fixBanner"].waitForExistence(timeout: 10))
    }

    /// The source filter narrows the list; the range "All" widens it.
    @MainActor
    func testFilters() {
        let app = launch()
        let thirty = count(app)
        app.segmentedControls["entries.range"].buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("120 "), "every Water entry")
        XCTAssertGreaterThan(120, thirty)
        app.buttons["entries.source"].tap()
        app.buttons["shortcut"].tap()
        XCTAssertTrue(app.staticTexts["entries.count"].waitForLabelPrefix("30 "), "every fourth is from a shortcut")
    }

    /// From Home: a tile opens the topic, and its Entries tab shows the list.
    @MainActor
    func testTheEntriesTabFromHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore"]
        app.launch()
        let water = app.descendants(matching: .any)["tile.water"]
        XCTAssertTrue(water.waitForExistence(timeout: 20))
        water.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        selectTopicTab("Entries", in: app)
        XCTAssertTrue(app.staticTexts["entries.count"].waitForExistence(timeout: 10))
    }

    /// At the largest accessibility size: rows, filters (a menu) and delete still work, and the
    /// list passes the accessibility audit. Delete is a long press (a11y L1): a row is ~400 pt tall
    /// here, and its swipe's button can land under the home indicator.
    @MainActor
    func testAccessibilityXXXL() throws {
        let app = launch(AccessibilityLaunch.arguments())
        XCTAssertTrue(app.buttons["entries.range"].waitForExistence(timeout: 5), "a menu at this size")
        try assertAccessible(app, allowing: EntriesAccessibility.list)
        let first = rows(app, "entry.").firstMatch
        for _ in 0..<15 where !(first.exists && first.isHittable) { app.swipeUp() }
        XCTAssertTrue(first.isHittable, "the first row, in view")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "entries-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
        first.press(forDuration: 1.2)
        let delete = app.buttons["entry.contextDelete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row's Delete, from its menu")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
    }
}

extension XCUIElement {
    /// Waits up to 10 s for the label to start with `prefix`.
    func waitForLabelPrefix(_ prefix: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
