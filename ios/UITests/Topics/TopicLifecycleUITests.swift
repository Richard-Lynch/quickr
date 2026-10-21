import XCTest

/// UIT-6: a topic's life through the app, against the fake server (`-QuickrUITest`,
/// https://quickr.test): create it, log an entry, publish v2 with a new question, and log again on
/// v2. The record screen follows the new version; the entries list reads both rows' answers and
/// marks only the first as older; and each entry, opened, is exactly its version (the edit screen's
/// "v1"/"v2", the older-version banner) with its own answers (Glasses 3; Glasses 4 and Energy 7).
final class TopicLifecycleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateLogPublishV2AndLogAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrOpen", "quickr://new"]
        app.launch()
        let screen = TopicScreen(app: app)

        // 1. Create "Water" with one number question.
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        screen.type("Water", into: name)
        screen.addQuestion("int", label: "Glasses", prefix: "newTopic")  // a new topic starts with none
        screen.dismissKeyboard()
        screen.tap("newTopic.create")
        XCTAssertTrue(screen.toast("Topic created").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Water"].waitForExistence(timeout: 15), "its record screen")

        // 2. Log v1: 3 glasses.
        let glasses = screen.field("form.field.glasses")
        XCTAssertTrue(glasses.waitForExistence(timeout: 10))
        screen.replace(glasses, with: "3")
        snap(app, "uit6-1-v1-record")
        screen.tap("record.save")
        XCTAssertTrue(screen.toast("Logged Water").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 10))

        // 3. Publish v2: the topic's Edit questions, add "Energy", review, publish.
        screen.openTopic("water")
        screen.tap("topic.editQuestions")
        XCTAssertTrue(screen.element("editQuestions.q0.header").waitForExistence(timeout: 15))
        screen.addQuestion("int", label: "Energy")
        screen.tap("editQuestions.review")
        let headline = screen.element("review.headline")
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertTrue(headline.label.contains("Ready to publish as v2"), headline.label)
        let publish = app.buttons["review.publish"]
        XCTAssertEqual(publish.label, "Publish v2")
        snap(app, "uit6-2-review")
        publish.tap()
        XCTAssertTrue(screen.toast("Published v2").waitForExistence(timeout: 10))
        let v2 = screen.element("versions.v2")
        XCTAssertTrue(v2.waitForExistence(timeout: 15))
        XCTAssertTrue(v2.label.contains("current"), v2.label)

        // 4. Log on v2: the record screen asks for Energy too.
        screen.backToHome()
        let log = app.buttons["Log Water"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        log.tap()
        let energy = screen.field("form.field.energy")
        XCTAssertTrue(energy.waitForExistence(timeout: 15), "v2's new question")
        screen.replace(energy, with: "7")
        screen.replace(screen.field("form.field.glasses"), with: "4")
        snap(app, "uit6-3-v2-record")
        screen.tap("record.save")
        XCTAssertTrue(screen.toast("Logged Water").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["home.wordmark"].waitForExistence(timeout: 10))

        // 5. Both entries: the rows read their answers, only the v1 one is marked older, and each
        //    entry, opened, is exactly its version with its own answers.
        screen.openTopic("water")
        let tabs = app.segmentedControls["topic.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Entries"].tap()
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'entry.' AND identifier != 'entry.delete'"))
        XCTAssertTrue(screen.waits(for: { rows.count == 2 }), "two entries, synced (\(rows.count))")
        let older = rows.matching(NSPredicate(format: "label CONTAINS 'Version 1'"))
        XCTAssertEqual(older.count, 1, "exactly one row is marked as an older version")
        XCTAssertTrue(older.firstMatch.label.contains("Glasses, 3"), older.firstMatch.label)
        let current = rows.matching(NSPredicate(format: "NOT (label CONTAINS 'Version ')")).firstMatch
        XCTAssertTrue(current.exists, "the other row has no version badge")
        XCTAssertTrue(current.label.contains("Glasses, 4"), current.label)
        XCTAssertTrue(current.label.contains("Energy, 7"), current.label)
        snap(app, "uit6-4-entries")

        screen.openEntry(older.firstMatch)
        XCTAssertTrue(screen.entryLine.label.hasPrefix("v1,"), screen.entryLine.label)
        XCTAssertTrue(screen.element("edit.outdated").exists, "logged against version 1")
        XCTAssertEqual(screen.number("form.field.glasses"), "3")
        XCTAssertFalse(screen.field("form.field.energy").exists, "v1 has no Energy")
        screen.back()

        screen.openEntry(current)
        XCTAssertTrue(screen.entryLine.label.hasPrefix("v2,"), screen.entryLine.label)
        XCTAssertFalse(screen.element("edit.outdated").exists)
        XCTAssertEqual(screen.number("form.field.glasses"), "4")
        XCTAssertEqual(screen.number("form.field.energy"), "7")
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// The steps the topic tests share, on one app. A struct, not an `XCTestCase` extension: other test
/// classes have private helpers of the same names, which an extension's would clash with.
@MainActor
struct TopicScreen {
    let app: XCUIApplication

    func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// A text field, or a text view (a multi-line field).
    func field(_ id: String) -> XCUIElement {
        let field = app.textFields[id]
        return field.exists ? field : element(id)
    }

    func toast(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toast.text")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func tap(_ id: String) {
        let target = element(id)
        scrollTo(target)
        XCTAssertTrue(target.waitForExistence(timeout: 5), id)
        target.tap()
    }

    /// Replaces a field's text: the cursor to the end, the old text deleted. Typed once and
    /// checked: a dropped character is a failure, not something to retype (it was the Builder's
    /// label binding losing keystrokes). A number field may show a unit after the value.
    func replace(_ field: XCUIElement, with text: String) {
        scrollTo(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        let delete = current == (field.placeholderValue ?? "") ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: delete) + text)
        XCTAssertEqual((field.value as? String)?.split(separator: " ").first.map(String.init), text, field.identifier)
    }

    /// Drags until `element` exists and is hittable (bounded): down the screen by default, `up`
    /// toward its top. Above where a keyboard would be.
    func scrollTo(_ element: XCUIElement, up: Bool = false) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            let (from, to) = up ? (0.2, 0.55) : (0.45, 0.12)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
    }

    /// Types `text` into an empty field, once, and checks it arrived whole: a dropped character is
    /// an app bug (the Builder's label binding lost keystrokes under load), so no retyping.
    func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "typed into \(field.identifier)")
    }

    func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        app.navigationBars.firstMatch.tap()
    }

    /// "Add question" → `type`, then types its label into the new (open) card.
    func addQuestion(_ type: String, label: String, prefix: String = "editQuestions") {
        let count = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH '.header'", "\(prefix).q")
        ).count
        tap("\(prefix).addQuestion")
        // The dialog's buttons can appear twice in the tree (the sheet and its presentation).
        let choice = app.buttons["\(prefix).addQuestion.\(type)"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        let field = app.textFields["\(prefix).q\(count).label"]
        scrollTo(field, up: true)
        scrollTo(field)
        self.type(label, into: field)  // `type` here is the question type
        dismissKeyboard()
    }

    /// Opens a topic from its home tile (its title, not a control).
    func openTopic(_ slug: String) {
        let tile = app.descendants(matching: .any)["tile.\(slug)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "tile.\(slug)")
        scrollTo(tile)
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        XCTAssertTrue(app.segmentedControls["topic.tabs"].waitForExistence(timeout: 10), "the topic's screen")
    }

    /// Back through the navigation stack to the home screen (bounded).
    func backToHome() {
        let home = app.staticTexts["home.wordmark"]
        for _ in 0..<4 where !home.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = home.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(home.exists, "home")
    }

    /// The edit screen's line about the entry ("v2, iOS, logged …").
    var entryLine: XCUIElement { element("edit.entryLine") }

    /// Opens an entry from the list (the edit screen), once its line shows.
    func openEntry(_ row: XCUIElement) {
        scrollTo(row)
        row.tap()
        XCTAssertTrue(entryLine.waitForExistence(timeout: 10), "the entry's screen")
    }

    /// Back one screen (no changes made, so no question).
    func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// A number field's value, without a unit or placeholder ("3", not "3 glasses").
    func number(_ id: String) -> String? {
        let field = self.field(id)
        guard field.waitForExistence(timeout: 5), let value = field.value as? String,
            value != field.placeholderValue
        else { return nil }
        return value.split(separator: " ").first.map(String.init)
    }

    /// Polls `condition` every 0.2 s for up to `seconds`.
    func waits(for condition: () -> Bool, seconds: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }
}
