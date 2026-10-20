import XCTest

/// The design loop's tap counts (frontend/docs/design-loop.md), measured on iOS against this
/// worktree's integration stack with the same topics: every tap goes through `tap(_:)`, each
/// scenario asserts its count, and the server is checked for the entry. The table in
/// docs/ios/demo/m2/tap-counts.md comes from these numbers. Counting as the PWA did: from the
/// open app (or the notification) to the saved entry; typing a value counts as typing.
@MainActor
final class TapCountUITests: XCTestCase {
    private var stack: Stack!
    private var taps = 0

    override func setUp() async throws {
        continueAfterFailure = false
        stack = try Stack.fromEnvironment()
        try await stack.resetProxy()
        taps = 0
    }

    /// (a) a one-question single-select: the chip on the tile. (f) Undo in the toast.
    func testA_OneQuestionChoice_and_F_Undo() async throws {
        let headache = try await stack.createTopic("Headache", questions: [Self.severity])
        let app = launch()
        tap(try tile(app, headache).buttons["chip.mild"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged Mild"))
        try await serverHas(1, headache)
        XCTAssertEqual(taps, 1, "(a)")

        taps = 0
        tap(app.buttons["toast.action"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Undone"))
        try await serverHas(0, headache)
        XCTAssertEqual(taps, 1, "(f)")
    }

    /// (b) a one-question number: ✓ logs the last value; one ± first changes it.
    func testB_OneQuestionNumber() async throws {
        let water = try await stack.createTopic("Water", questions: [Self.glasses])
        try await stack.createEntry(water, answers: ["glasses": 3])
        let app = launch()
        let tile = try tile(app, water)
        XCTAssertTrue(tile.buttons["quick.check"].waitForLabel(prefix: "Log 3"))
        tap(tile.buttons["quick.check"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged 3"))
        try await serverHas(2, water)
        XCTAssertEqual(taps, 1, "(b)")

        taps = 0
        tap(tile.buttons["Increase"])
        tap(tile.buttons["quick.check"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged 4"))
        try await serverHas(3, water)
        XCTAssertEqual(taps, 2, "(b) with ±")
    }

    /// (c) the four-question Workout: Log → Run (focus moves to Duration) → type → RPE → type →
    /// Save.
    func testC_FourQuestionMixed() async throws {
        let workout = try await stack.createTopic("Workout", questions: Self.workout)
        let app = launch()
        tap(try tile(app, workout).buttons["Log \(workout.name)"])
        let run = app.buttons["Run"]
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        tap(run)
        let duration = app.textFields["form.field.duration"]
        XCTAssertTrue(duration.waitForKeyboardFocus(), "the pick moves on to Duration")
        duration.typeText("30")
        // Past the optional Distance: a tap on RPE, as in the PWA (Next twice would also get there).
        let rpe = app.textFields["form.field.rpe"]
        tap(rpe)
        XCTAssertTrue(rpe.waitForKeyboardFocus())
        rpe.typeText("7")
        tap(app.buttons["record.save"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged \(workout.name)", timeout: 15))
        try await serverHas(1, workout)
        XCTAssertEqual(taps, 4, "(c)")
    }

    /// (d) the same answers as last time: Log → Same as last time → Save.
    func testD_SameAsLastTime() async throws {
        let workout = try await stack.createTopic("Workout", questions: Self.workout)
        try await stack.createEntry(workout, answers: ["type": "run", "duration": 30, "rpe": 7])
        let app = launch()
        tap(try tile(app, workout).buttons["Log \(workout.name)"])
        let same = app.buttons["form.sameAsLast"]
        XCTAssertTrue(same.waitForExistence(timeout: 15))
        tap(same)
        tap(app.buttons["record.save"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged \(workout.name)", timeout: 15))
        try await serverHas(2, workout)
        XCTAssertEqual(taps, 3, "(d)")
    }

    /// (e) from a notification: its link opens the record screen (the notification tap is the
    /// first tap). Headache: a chip saves. Water: it starts at the last value, so Save.
    func testE_FromANotification() async throws {
        let headache = try await stack.createTopic("Headache", questions: [Self.severity])
        var app = launch(open: "quickr://t/\(headache.slug)/record")
        taps = 1  // the notification
        let mild = app.buttons["Mild"]
        XCTAssertTrue(mild.waitForExistence(timeout: 20))
        tap(mild)
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged \(headache.name)", timeout: 15))
        try await serverHas(1, headache)
        XCTAssertEqual(taps, 2, "(e) Headache")

        let water = try await stack.createTopic("Water", questions: [Self.glasses])
        try await stack.createEntry(water, answers: ["glasses": 3])
        app.terminate()
        app = launch(open: "quickr://t/\(water.slug)/record")
        taps = 1
        let glasses = app.textFields["form.field.glasses"]
        XCTAssertTrue(glasses.waitForExistence(timeout: 20))
        XCTAssertTrue((glasses.value as? String ?? "").hasPrefix("3"), "starts at the last value")
        tap(app.buttons["record.save"])
        XCTAssertTrue(toast(app).waitForLabel(prefix: "Logged \(water.name)", timeout: 15))
        try await serverHas(2, water)
        XCTAssertEqual(taps, 2, "(e) Water")
    }

    /// (g) offline: the chip queues the entry; it syncs when the app comes back.
    func testG_Offline() async throws {
        let headache = try await stack.createTopic("Headache", questions: [Self.severity])
        let app = launch()
        let tile = try tile(app, headache)
        try await stack.goOffline()
        tap(tile.buttons["chip.moderate"])
        XCTAssertTrue(toast(app).waitForExistence(timeout: 10))
        XCTAssertTrue(toast(app).label.contains("saved on this device"), toast(app).label)
        XCTAssertEqual(taps, 1, "(g)")

        try await stack.goOnline()
        XCUIDevice.shared.press(.home)
        app.activate()
        try await serverHas(1, headache, timeout: 30)
    }

    // MARK: - The design loop's topics

    private static let severity = Stack.choice(
        "severity", "Severity", ["mild": "Mild", "moderate": "Moderate", "severe": "Severe", "migraine": "Migraine"])
    private static let glasses = Stack.int("glasses", "Glasses", max: 20, unit: "glasses")
    private static let workout = [
        Stack.choice("type", "Type", ["run": "Run", "swim": "Swim", "bike": "Bike", "yoga": "Yoga"]),
        Stack.int("duration", "Duration", max: 600, unit: "min"),
        Stack.double("distance", "Distance", max: 100, unit: "km", required: false),
        Stack.int("rpe", "RPE", max: 10),
    ]

    // MARK: - Helpers

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element)")
        element.tap()
        taps += 1
    }

    private func toast(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "toast.text").firstMatch
    }

    private func serverHas(_ count: Int, _ topic: Stack.Topic, timeout: TimeInterval = 15) async throws {
        _ = try await stack.eventually("\(count) entries in \(topic.name)", timeout: timeout) {
            try await self.stack.entries(topic).count == count ? true : nil
        }
    }

    private func launch(open url: String? = nil) -> XCUIApplication { stack.launch(open: url) }

    private func tile(_ app: XCUIApplication, _ topic: Stack.Topic) throws -> XCUIElement {
        let element = app.descendants(matching: .any)["tile.\(topic.slug)"]
        XCTAssertTrue(element.waitForExistence(timeout: 30), "tile.\(topic.slug) after the first sync")
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        return element
    }
}
