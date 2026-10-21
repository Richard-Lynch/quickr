import XCTest

/// PERF: cold starts over a heavy user's store (`-QuickrPerfStore`: 10,000 entries in 20 topics,
/// offline), on the debug build. Real time, so only with `QUICKR_UIT_PERF=1` (`make
/// ios-perf-launch`); the UI plan skips them. The release build's cold start, which the < 1 s
/// target is for, is `make ios-perf-cold-start`. The first launch seeds the store and isn't measured. Simulator numbers; device
/// numbers come at M4-DEV.
final class PerfLaunchUITests: XCTestCase {
    static let launches = 5

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["QUICKR_UIT_PERF"] == "1" else {
            throw XCTSkip("Real-time launch measurements only (make ios-perf-launch)")
        }
        continueAfterFailure = false
    }

    @MainActor
    private func perfApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrPerfStore"]
        return app
    }

    /// Launches and reads the app's own measure: process start to Home's first tile on screen.
    @MainActor
    private func firstRender(_ app: XCUIApplication, timeout: TimeInterval) -> Int? {
        app.launch()
        let probe = app.staticTexts["perf.firstRender"]
        let read = NSPredicate { _, _ in Int(probe.label) != nil }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: read, object: nil)], timeout: timeout)
        defer { app.terminate() }
        return found == .completed ? Int(probe.label) : nil
    }

    @MainActor
    private func seed() throws {
        let seeded = firstRender(perfApp(), timeout: 180)
        XCTAssertNotNil(seeded, "the seeding launch reaches Home")
    }

    /// Process start to Home's first tile, the median of five launches. The < 1 s target is for
    /// a release build, which `perf-cold-start.sh` measures (the scheme's test action needs a
    /// debug build); a debug build (unoptimised Swift and GRDB) is bounded at 2 s here.
    @MainActor
    func testColdStartToHomesFirstTile() throws {
        try seed()
        var times: [Int] = []
        for _ in 0..<Self.launches {
            let ms = try XCTUnwrap(firstRender(perfApp(), timeout: 30), "Home shows a tile")
            times.append(ms)
        }
        let median = times.sorted()[times.count / 2]
        print("PERF cold start to Home's first tile (ms): \(times), median \(median)")
        XCTContext.runActivity(named: "PERF cold start: \(times) ms, median \(median) ms") { _ in }
        XCTAssertLessThan(median, 2_000, "median cold start \(median) ms over \(times)")
    }

    /// The system's launch metric (to the first frame), over the same seeded store.
    @MainActor
    func testLaunchMetric() throws {
        try seed()
        let options = XCTMeasureOptions()
        options.iterationCount = Self.launches
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            perfApp().launch()
        }
    }
}
