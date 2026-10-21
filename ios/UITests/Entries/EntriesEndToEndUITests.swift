import XCTest

/// Editing and deleting entries end to end (UIT-5): the app on the simulator against this
/// worktree's integration stack, checked on the server. The outbox side of the same flows
/// (coalescing, held deletes, revisions) is covered against docker in DataTests/Integration
/// (scenarios 17 and 18); these drive it from the screens.
///
/// Run with `make ios-uitest-e2e`; without the stack they skip, like EndToEndUITests.
@MainActor
final class EntriesEndToEndUITests: XCTestCase {
    private var stack: Stack!

    override func setUp() async throws {
        continueAfterFailure = false
        stack = try Stack.fromEnvironment()
        try await stack.resetProxy()
        try await stack.removeAllTopics()
    }

    /// An edit saved on the phone reaches the server: only the changed answer, the rest kept.
    func testAnEditOnThePhoneReachesTheServer() async throws {
        let topic = try await water()
        let id = try await stack.createEntry(topic, answers: ["glasses": 3, "cups": 1])

        let app = stack.launch(open: "quickr://t/\(topic.slug)/entries")
        let glasses = open(app, id)
        XCTAssertTrue((glasses.value as? String ?? "").hasPrefix("3"))
        glasses.replaceText("7")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.staticTexts["Entry updated"].waitForExistence(timeout: 10))

        let entry = try await stack.eventually("the edit on the server") {
            let entry = try await self.stack.entry(id)
            return entry.flatMap { Stack.answer($0, "glasses") as? Int } == 7 ? entry : nil
        }
        XCTAssertEqual(Stack.answer(entry, "cups") as? Int, 1, "an answer not edited is kept")
        XCTAssertEqual(entry["revision"] as? Int, 2)
    }

    /// Delete holds the entry back for the Undo window, and Undo keeps it on the server.
    func testUndoingADeleteKeepsTheEntryOnTheServer() async throws {
        let topic = try await water()
        let id = try await stack.createEntry(topic, answers: ["glasses": 3])

        let app = stack.launch(open: "quickr://t/\(topic.slug)/entries")
        _ = open(app, id)
        app.buttons["edit.delete"].tap()
        let firstDelete = Date()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["Entry restored"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["entry.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // Past the hold, an edit of the same entry: the outbox sends in order, so once the server
        // has the edit, a delete Undo had failed to remove would have gone first (and the edit
        // would have been refused).
        try await Task.sleep(for: .seconds(max(0, 7 - Date().timeIntervalSince(firstDelete))))
        open(app, id).replaceText("5")
        app.buttons["edit.save"].tap()
        let kept = try await stack.eventually("the edit after Undo on the server") {
            let entry = try await self.stack.entry(id)
            return entry.flatMap { Stack.answer($0, "glasses") as? Int } == 5 ? entry : nil
        }
        XCTAssertEqual(kept["revision"] as? Int, 2, "the entry Undo kept, edited once")
    }

    /// Without Undo, the server deletes the entry once the hold is over, not before.
    func testADeleteReachesTheServerAfterTheHold() async throws {
        let topic = try await water()
        let id = try await stack.createEntry(topic, answers: ["glasses": 3])

        let app = stack.launch(open: "quickr://t/\(topic.slug)/entries")
        let row = app.descendants(matching: .any)["entry.\(id)"]
        _ = open(app, id)
        app.buttons["edit.delete"].tap()
        let deletedAt = Date()
        XCTAssertTrue(app.staticTexts["Entry deleted"].waitForExistence(timeout: 5))
        try await Task.sleep(for: .seconds(max(0, 2.5 - Date().timeIntervalSince(deletedAt))))
        let held = try await stack.entry(id)
        XCTAssertNotNil(held, "still on the server during the hold")
        _ = try await stack.eventually("the delete on the server after the hold", timeout: 20) {
            try await self.stack.entry(id) == nil ? true : nil
        }
        // The hold is 6 s from the tap; a little before allows for the tap's own latency.
        XCTAssertGreaterThan(Date().timeIntervalSince(deletedAt), 5, "deleted only once the hold is over")
        XCTAssertFalse(row.exists, "the list no longer shows it")
    }

    /// An entry edited on the web reaches the phone: the list shows the change once the app
    /// syncs (here on coming back to the foreground), and the edit screen has the new answer.
    func testAWebEditReachesThePhone() async throws {
        let topic = try await water()
        let id = try await stack.createEntry(topic, answers: ["glasses": 3])

        let app = stack.launch(open: "quickr://t/\(topic.slug)/entries")
        let row = app.descendants(matching: .any)["entry.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))

        try await stack.updateEntry(id, answers: ["glasses": 9], notes: "from the web")
        XCUIDevice.shared.press(.home)
        app.activate()
        let synced = NSPredicate(format: "label CONTAINS %@", "from the web")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: synced, object: row)], timeout: 30)

        let glasses = open(app, id)
        XCTAssertTrue((glasses.value as? String ?? "").hasPrefix("9"), "\(glasses.value ?? "")")
    }

    // MARK: - Helpers

    private func water() async throws -> Stack.Topic {
        try await stack.createTopic(
            "Water",
            questions: [Stack.int("glasses", "Glasses", max: 20), Stack.int("cups", "Cups", max: 20, required: false)])
    }

    /// From the topic's list, the entry's edit screen: its glasses field.
    private func open(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let row = app.descendants(matching: .any)["entry.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "entry.\(id) in the list")
        row.tap()
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 10))
        return glasses
    }
}
