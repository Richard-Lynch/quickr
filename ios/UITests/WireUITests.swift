import XCTest

/// T2-WIRE (docs/specs/t2-plan.md §T2-WIRE-I) on the fake server with `-QuickrSeedAppearance`:
/// Mood teal 🙂 with four tags, Morning blue ☀️ with one, Workout untinted. The tiles show the
/// summary line, at most three tag chips then "+N" (appearance.md §5); the home tag filter lists
/// only the topics with the tapped tag; a themed run's card, run screen and Live Activity mock
/// (the widget gallery's "la" page). Colours are proved by `TopicChromeTests` on the host and by
/// the screenshots each test attaches (light, dark, the largest text size), which
/// docs/t2/evidence/WIRE.md carries.
///
/// `WIRE_SHOTS_ONLY=1` in the test environment takes the screenshots without the wiring's
/// assertions: the "before" pass on `feat/t2` without this PR's views.
@MainActor
final class WireUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private var shotsOnly: Bool { ProcessInfo.processInfo.environment["WIRE_SHOTS_ONLY"] == "1" }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-QuickrUITest", "-QuickrServer", "https://quickr.test", "-QuickrSeedAppearance"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func text(in element: XCUIElement, containing fragment: String) -> XCUIElement {
        element.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Light, dark and light at the largest accessibility size: (appearance, launch arguments, name).
    private static let modes: [(XCUIDevice.Appearance, [String], String)] = [
        (.light, [], "light"), (.dark, [], "dark"),
        (.light, AccessibilityLaunch.arguments(contentSize: AccessibilityLaunch.xxxl), "xxxl"),
    ]

    /// The home tiles: Mood's summary line after a log ("Mood: Good"), its chips "Daily, Health,
    /// Home, +1"; Workout's untinted tile has no chips.
    func testThemedTilesShowTheSummaryLineAndTagChips() {
        for (appearance, extra, name) in Self.modes {
            XCUIDevice.shared.appearance = appearance
            let app = launch(extra)
            let mood = element(app, "tile.mood")
            XCTAssertTrue(mood.waitForExistence(timeout: 20))
            let chip = mood.buttons["chip.good"]
            XCTAssertTrue(chip.waitForExistence(timeout: 10))
            chip.tap()
            let toast = app.staticTexts.matching(identifier: "toast.text").firstMatch
            XCTAssertTrue(toast.waitForExistence(timeout: 10))
            if !shotsOnly {
                XCTAssertTrue(
                    text(in: mood, containing: "Mood: Good").waitForExistence(timeout: 10),
                    "the summary line replaces \"Last Good\"")
                // The meta reads as one element (title, badges, summary, chips): the chips' label is in it.
                XCTAssertTrue(text(in: mood, containing: "Tags: Daily, Health, Home, and 1 more").exists)
                XCTAssertFalse(text(in: element(app, "tile.workout"), containing: "Tags:").exists)
            }
            snap(app, "home-tiles-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    /// The filter panel's "Tag" row (appearance.md §5): Daily keeps Mood and Morning, hides
    /// Workout; ✕ brings it back.
    func testTheTagFilterListsOnlyThatTagsTopics() throws {
        if shotsOnly { throw XCTSkip("no tag filter before T2-WIRE") }
        let app = launch()
        XCTAssertTrue(element(app, "tile.workout").waitForExistence(timeout: 20))
        element(app, "home.filter").tap()
        let daily = element(app, "home.tag.Daily")
        XCTAssertTrue(daily.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "home.tag.Evening").exists)
        daily.tap()
        XCTAssertTrue(daily.isSelected)
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: element(app, "tile.workout"))], timeout: 5),
            .completed, "Workout has no Daily tag")
        XCTAssertTrue(element(app, "tile.mood").exists)
        XCTAssertTrue(element(app, "tile.morning").exists)
        snap(app, "home-tag-filter")
        element(app, "home.tag.clear").tap()
        XCTAssertTrue(element(app, "tile.workout").waitForExistence(timeout: 5))
    }

    /// A themed run: the Active now card (its primary in the topic's tint, #286), then its run
    /// screen (the hero primary), in each mode.
    func testThemedActiveCardAndRunScreen() {
        for (appearance, extra, name) in Self.modes {
            XCUIDevice.shared.appearance = appearance
            let app = launch(extra)
            let start = element(app, "tile.morning.run")
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            start.tap()
            let next = element(app, "tile.morning.run")
            let predicate = NSPredicate(format: "label CONTAINS 'Next'")
            XCTAssertEqual(
                XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: next)], timeout: 10), .completed,
                "the card offers Next")
            snap(app, "active-card-\(name)")
            element(app, "tile.morning").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
            XCTAssertTrue(element(app, "run.primary").waitForExistence(timeout: 10))
            snap(app, "run-screen-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    /// The Live Activity's Lock Screen view in the widget gallery (#202): Morning untinted,
    /// Intervals orange 🏃 with its `tintSoft` background and `tint` primary.
    func testLiveActivityMock() throws {
        for (appearance, extra, name) in Self.modes {
            XCUIDevice.shared.appearance = appearance
            let app = XCUIApplication()
            app.launchArguments = ["-QuickrWidgetGallery", "la"] + extra
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["widgets.gallery"].waitForExistence(timeout: 15))
            if shotsOnly, !element(app, "activity.step").exists {
                throw XCTSkip("no Live Activity page before T2-WIRE (#202)")
            }
            let themed = element(app, "activity.themed")
            XCTAssertTrue(themed.waitForExistence(timeout: 5))
            XCTAssertTrue(text(in: themed, containing: "Intervals").exists)
            XCTAssertTrue(themed.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lap'")).firstMatch.exists)
            XCTAssertTrue(text(in: element(app, "activity.ended"), containing: "Saved").exists)
            snap(app, "live-activity-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }
}
