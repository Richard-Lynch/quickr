import XCTest

/// The answer form's focus rules on the design loop's 4-question Workout topic
/// (`-QuickrFormDemo workout`): chip, int, optional double, optional text.
final class FormUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFillingAMixedTopicMovesFocusAndSubmitsTheBody() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrFormDemo", "workout"]
        app.launch()

        let duration = app.textFields["form.field.duration"]
        let distance = app.textFields["form.field.distance"]
        let note = app.textFields["form.field.note"]
        XCTAssertTrue(duration.waitForExistence(timeout: 10))

        // The first unanswered question is a chip: nothing is focused, so no keyboard.
        sleep(1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a chip question must not open the keyboard")

        // Saving empty shows the errors and focuses nothing (the first invalid question is a chip).
        app.buttons["formDemo.save"].tap()
        XCTAssertTrue(app.staticTexts["form.error.type"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["form.error.duration"].label, "Required")
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        // Picking the chip moves focus to the next empty typed field.
        app.buttons["Run"].tap()
        XCTAssertTrue(waitForFocus(duration), "the pick should focus Duration")
        XCTAssertFalse(app.staticTexts["form.error.type"].exists)
        duration.typeText("45")
        XCTAssertFalse(app.staticTexts["form.error.duration"].exists, "a touched field revalidates as you type")

        // The number pad has no Return key: the keyboard toolbar's Next moves on.
        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(waitForFocus(distance), "Next should focus Distance")
        distance.typeText("5.2")
        app.buttons["Next"].firstMatch.tap()
        XCTAssertTrue(waitForFocus(note), "Next should focus the note")

        // Return in the last empty field dismisses the keyboard instead of saving.
        note.typeText("Easy pace\n")
        XCTAssertTrue(waitForKeyboard(app, shown: false))
        XCTAssertFalse(app.staticTexts["formDemo.body"].exists)

        app.buttons["formDemo.save"].tap()
        let body = app.staticTexts["formDemo.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.label, #"{"distance":5.2,"duration":45,"note":"Easy pace","type":"run"}"#)
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: focused, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForKeyboard(_ app: XCUIApplication, shown: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: shown))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.keyboards.firstMatch)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
