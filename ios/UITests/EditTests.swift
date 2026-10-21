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

    /// Replaces a field's text: the cursor goes to its end (a tap at the right edge), then
    /// everything is deleted.
    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + text)
    }

    /// A number field's number: its value reads with the unit ("3 glasses").
    @MainActor
    private func number(_ field: XCUIElement) -> String? {
        (field.value as? String)?.split(separator: " ").first.map(String.init)
    }

    /// Save changes queues the edit and returns to the list, which shows it (waiting to sync).
    @MainActor
    func testSavingAnEditReturnsToTheListWithTheChange() {
        let app = launch()
        let glasses = openNewest(app)
        XCTAssertEqual(number(glasses), "3")
        XCTAssertTrue(app.descendants(matching: .any)["edit.entryLine"].exists)
        replace(glasses, with: "7")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["entry.\(newest)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Change waiting to sync"), row.label)
        // The store shows the queued edit: it reopens with 7.
        row.tap()
        XCTAssertTrue(glasses.waitForExistence(timeout: 10))
        XCTAssertEqual(number(glasses), "7")
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
        XCTAssertEqual(number(glasses), "9")
    }

    /// A swipe from the left edge goes back while nothing has changed, and does nothing once the
    /// form has a change (the back button asks first instead), as on the record screen.
    @MainActor
    func testSwipingBackWorksOnlyWithoutChanges() {
        var app = launch()
        _ = openNewest(app)
        swipeBack(app)
        XCTAssertTrue(app.staticTexts["entries.count"].waitForExistence(timeout: 5), "a clean form swipes back")

        app.terminate()
        app = launch()
        let glasses = openNewest(app)
        replace(glasses, with: "9")
        app.buttons["form.keyboard.advance"].tap()  // the keyboard down: a plain edge swipe
        swipeBack(app)
        XCTAssertFalse(app.staticTexts["Entry deleted"].exists, "the drag never deletes the entry")
        XCTAssertTrue(glasses.isHittable, "a changed form stays")
        XCTAssertEqual(number(glasses), "9")
    }

    /// Delete fires on a tap or a VoiceOver activation only: a drag that ends on its full-width
    /// row (a scroll released on it, a blocked swipe back across it) leaves the entry alone.
    @MainActor
    func testOnlyATapOnDeleteDeletes() {
        let app = launch()
        let glasses = openNewest(app)
        replace(glasses, with: "9")
        app.buttons["form.keyboard.advance"].tap()  // the keyboard down
        let delete = app.buttons["edit.delete"]
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        // A button to VoiceOver, named for what it does: its activation is the row's action.
        XCTAssertEqual(delete.label, "Delete entry")

        let row = delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // A scroll that starts on the row: the content follows the finger, so it lifts on the row.
        for dy in [-150.0, 150.0] {
            row.press(
                forDuration: 0.1, thenDragTo: row.withOffset(CGVector(dx: 0, dy: dy)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            usleep(800_000)
            XCTAssertFalse(app.staticTexts["Entry deleted"].exists, "a scroll released on Delete (\(dy))")
            XCTAssertTrue(glasses.exists)
            for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        }
        // A swipe back (blocked: the form has a change) from the edge along the row, ending on it.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0))
            .withOffset(CGVector(dx: 0, dy: delete.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: row)
        usleep(800_000)
        XCTAssertFalse(app.staticTexts["Entry deleted"].exists, "a swipe ending on Delete")
        XCTAssertEqual(number(glasses), "9")

        // A plain tap still deletes.
        delete.tap()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func swipeBack(_ app: XCUIApplication) {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        usleep(800_000)
    }

    /// A log only this device has, still waiting: it edits like any other (the outbox merges the
    /// change into the queued create).
    @MainActor
    func testAWaitingLogEdits() {
        let app = launch(open: "quickr://t/water/entries/\(waiting)")
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 20))
        XCTAssertEqual(number(glasses), "5")
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
        XCTAssertEqual(number(glasses), "99", "the refused value, not the later queued edit's 2")
        XCTAssertTrue(app.staticTexts["form.error.glasses"].label.hasPrefix("Must be at most 20"))
        replace(glasses, with: "4")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))

        // Back to the entry from its list: the correction is the latest word, over the later
        // queued edit's 2 (it lost glasses and kept its note).
        let water = app.descendants(matching: .any)["tile.water"]
        XCTAssertTrue(water.waitForExistence(timeout: 10))
        water.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        selectTopicTab("Entries", in: app)
        let row = app.descendants(matching: .any)["entry.00000000-0000-4000-9002-000000000001"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(glasses.waitForExistence(timeout: 10))
        XCTAssertEqual(number(glasses), "4")
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

    /// With the keyboard up, Save is in its toolbar: one of it, beside Done, not over the field or
    /// the keys, and it stays so after the first edit (the iOS 26 keyboard safe-area bug RECORD hit).
    @MainActor
    private func checkKeyboardSave(_ app: XCUIApplication, field: XCUIElement, _ when: String) {
        let advance = app.buttons["form.keyboard.advance"]
        XCTAssertTrue(advance.waitForExistence(timeout: 5), when)
        let saves = app.buttons.matching(identifier: "edit.save")
        XCTAssertEqual(saves.count, 1, when)
        let save = saves.firstMatch
        XCTAssertTrue(save.isHittable, when)
        XCTAssertFalse(save.frame.intersects(advance.frame), when)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame), when)
        XCTAssertGreaterThanOrEqual(save.frame.minY, field.frame.maxY, "below the field: \(when)")
        XCTAssertLessThanOrEqual(save.frame.maxY, app.keyboards.keys["1"].frame.minY, "above the keys: \(when)")
    }

    @MainActor
    func testSaveIsInTheKeyboardToolbarWhileTyping() {
        let app = launch()
        let glasses = openNewest(app)
        glasses.tap()
        checkKeyboardSave(app, field: glasses, "before the edit")
        replace(glasses, with: "8")
        usleep(1_000_000)
        checkKeyboardSave(app, field: glasses, "after the first edit")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))
    }

    /// Fix mode puts focus on the refused field, so the keyboard is up at once.
    @MainActor
    func testFixModeSaveIsInTheKeyboardToolbarAtOnce() {
        let app = launch(open: "quickr://t/water/entries/00000000-0000-4000-9002-000000000001")
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 20))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "focus on the refused field")
        checkKeyboardSave(app, field: glasses, "on opening")
        replace(glasses, with: "4")
        usleep(1_000_000)
        checkKeyboardSave(app, field: glasses, "after the first edit")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "edit-fix-keyboard"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 5))
    }

    /// At the largest accessibility size the form, Details and both buttons are reachable.
    @MainActor
    func testAccessibilityXXXL() throws {
        // By link: at this size the list's tall header and pinned rows keep the row off screen.
        let app = launch(open: "quickr://t/water/entries/\(newest)", AccessibilityLaunch.arguments())
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 20))
        XCTAssertTrue(glasses.isHittable)
        XCTAssertTrue(app.buttons["edit.save"].isHittable)
        // At the top: nothing sits under the Save bar (the audit reads that as clipped text).
        try assertAccessible(app, allowing: EntriesAccessibility.edit)
        // Delete is the form's last row: scroll to it.
        let delete = app.buttons["edit.delete"]
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "edit-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
