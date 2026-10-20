import XCTest

/// Editing an entry over the debug demo store (`-QuickrDemoStore`, offline), from Water's entries
/// list. With `-QuickrDemoOutbox` Water also has a refused log and one waiting to sync.
final class EditTests: XCTestCase {
    /// Water's newest entry (3 glasses), and the two device-only logs (`DemoStore`).
    let newest = "00000000-0000-4000-9002-000000000000"
    let refused = "00000000-0000-4000-a000-0000000000f1"
    let waiting = "00000000-0000-4000-a000-0000000000f2"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(open url: String = "quickr://t/water/entries", _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrDemoStore", "-QuickrDemoOutbox", "-QuickrOpen", url] + extra
        app.launch()
        return app
    }

    /// From the list, the newest entry's edit screen.
    @MainActor
    private func openNewest(_ app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["entry.\(newest)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 10))
        return glasses
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    /// Save changes queues the edit and returns to the list, which shows it (waiting to sync).
    @MainActor
    func testSavingAnEditReturnsToTheListWithTheChange() {
        let app = launch()
        let glasses = openNewest(app)
        XCTAssertEqual(glasses.value as? String, "3")
        XCTAssertTrue(app.descendants(matching: .any)["edit.entryLine"].exists)
        replace(glasses, with: "7")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["entry.\(newest)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("7 glasses"), row.label)
        XCTAssertTrue(row.label.contains("Change waiting to sync"), row.label)
    }

    /// Delete on the edit screen: back to the list without it, with Undo, which brings it back.
    @MainActor
    func testDeleteFromTheEditScreenThenUndo() {
        let app = launch()
        _ = openNewest(app)
        app.buttons["edit.delete"].tap()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["entry.\(newest)"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 5)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["Entry restored"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// Leaving with unsaved changes asks first.
    @MainActor
    func testLeavingWithChangesAsks() {
        let app = launch()
        let glasses = openNewest(app)
        replace(glasses, with: "9")
        app.buttons["edit.back"].tap()
        XCTAssertTrue(app.alerts["Discard your changes?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Keep editing"].tap()
        XCTAssertEqual(glasses.value as? String, "9")
    }

    /// A log only this device has, still waiting: it edits like any other (the outbox merges the
    /// change into the queued create).
    @MainActor
    func testAWaitingLogEdits() {
        let app = launch(open: "quickr://t/water/entries/\(waiting)")
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 20))
        XCTAssertEqual(glasses.value as? String, "5")
        replace(glasses, with: "6")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))
    }

    /// An edit the server refused opens in fix mode: its values with the error on the field, and
    /// Save again replaces it.
    @MainActor
    func testARefusedEditOpensInFixMode() {
        let app = launch(open: "quickr://t/water/entries/00000000-0000-4000-9002-000000000001")
        XCTAssertTrue(app.descendants(matching: .any)["edit.fixBanner"].waitForExistence(timeout: 20))
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertEqual(glasses.value as? String, "99", "the refused value")
        XCTAssertEqual(app.staticTexts["form.error.glasses"].label, "Must be at most 20")
        replace(glasses, with: "4")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))
    }

    /// A log the server refused is fixed on the record screen.
    @MainActor
    func testARefusedLogOffersFix() {
        let app = launch(open: "quickr://t/water/entries/\(refused)")
        XCTAssertTrue(app.descendants(matching: .any)["edit.refused"].waitForExistence(timeout: 20))
        app.buttons["edit.fix"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["record.fixBanner"].waitForExistence(timeout: 10))
    }

    /// An entry that isn't there says so.
    @MainActor
    func testAMissingEntrySaysSo() {
        let app = launch(open: "quickr://t/water/entries/00000000-0000-4000-9002-000000009999")
        XCTAssertTrue(app.descendants(matching: .any)["edit.gone"].waitForExistence(timeout: 20))
    }

    /// At the largest accessibility size the form, Details and both buttons are reachable.
    @MainActor
    func testAccessibilityXXXL() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let glasses = openNewest(app)
        XCTAssertTrue(glasses.isHittable)
        XCTAssertTrue(app.buttons["edit.save"].isHittable)
        XCTAssertTrue(app.buttons["edit.delete"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "edit-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
