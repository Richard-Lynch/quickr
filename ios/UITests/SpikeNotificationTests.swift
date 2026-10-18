import XCTest

/// SPIKE (M1, docs/ios/demo/m1/spike-findings.md): a reminder's action logs an entry while the
/// app is not running, on the simulator, against a real backend.
///
/// Driven by `ios/scripts/spike-proof.sh`, which brings up the integration stack, creates the
/// topics, renders their APNs payloads with the server's own code and serves a small coordinator
/// on the host. The test asks the coordinator to push (`GET /push/<case>`: it runs
/// `xcrun simctl push` and answers once it has), then drives SpringBoard. It asserts on the
/// server (`GET /api/v1/topics/{id}/entries`), on the app's state, and on the handler's events
/// in the App Group log (`GET /log`), and reports what it saw (`POST /result/<case>`).
///
/// Cases (from the coordinator's `/cases`), each starting with the app not running:
/// - `log`: the app registered the category through the registry table before it was killed
///   (CAT's primary path, notifications.md §5.2). Tapping an option launches the app in the
///   background, logs the entry on the server, and completes on the main thread.
/// - `error`: the same category, but the reminder names another version: the handler refuses the
///   action (§7.1 step 1), writes nothing, posts "Couldn't log" and still completes.
/// - `default`: tapping the reminder's body opens the app in the foreground; nothing is logged.
/// - `observe`: only the NSE would register the category (§6, the backstop). Whether its actions
///   show is the finding; it isn't asserted (the simulator didn't run the NSE, F1).
///
/// Not in the UI plan (SpringBoard automation can stall); its own plan, run by the script.
final class SpikeNotificationTests: XCTestCase {
    struct SpikeCase: Decodable {
        var name: String
        var kind: String
        var topicId: String
        var topicName: String
        var optionLabel: String
        var optionValue: String
    }

    struct Setup: Decodable {
        var server: String
        /// Base64 JSON array of the payloads the app registers before it is killed.
        var register: String
        var cases: [SpikeCase]
    }

    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    @MainActor private var coordinator: URL {
        get throws {
            let raw = ProcessInfo.processInfo.environment["SPIKE_COORDINATOR"] ?? ""
            return try XCTUnwrap(URL(string: raw), "run through ios/scripts/spike-proof.sh (SPIKE_COORDINATOR)")
        }
    }

    @MainActor
    func testActionLogsFromAKilledApp() async throws {
        let setup = try JSONDecoder().decode(Setup.self, from: try await get("cases"))
        let app = XCUIApplication()
        app.launchArguments = ["-spikeServer", setup.server, "-spikeRegister", setup.register]
        app.launch()
        let status = app.staticTexts["spike.status"]
        for _ in 0..<30 where !(status.exists && status.label.hasPrefix("spike: ready")) {
            if springboard.alerts.buttons["Allow"].exists { springboard.alerts.buttons["Allow"].tap() }
            sleep(1)
        }
        XCTAssertTrue(status.label.hasPrefix("spike: ready"), "app setup: \(status.label)")
        attach("app-ready")
        app.terminate()

        for spikeCase in setup.cases {
            try await run(spikeCase, app: app, server: setup.server)
        }
    }

    @MainActor
    private func run(_ spikeCase: SpikeCase, app: XCUIApplication, server: String) async throws {
        XCUIDevice.shared.press(.home)
        XCTAssertEqual(app.state, .notRunning, "\(spikeCase.name): the app isn't running before the push")
        let completedBefore = try await completions().count
        let entriesBefore = try await entries(server: server, topicId: spikeCase.topicId).count
        _ = try await get("push/\(spikeCase.name)")  // returns once `simctl push` has delivered
        var observed: [String: String] = ["case": spikeCase.name]

        // The simulator's notification pipeline holds a reminder for up to ~10 s (an Apple
        // Intelligence inference step that waits out its timer) before the banner shows.
        let banner = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", spikeCase.topicName)
        ).firstMatch
        if !banner.waitForExistence(timeout: 30) {
            // The banner may have gone already: open Notification Center.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
                .press(
                    forDuration: 0.1,
                    thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)))
        }
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "\(spikeCase.name): the notification is shown")
        attach("\(spikeCase.name)-delivered")

        if spikeCase.kind == "default" {
            XCTAssertEqual(app.state, .notRunning, "\(spikeCase.name): not running right before the tap")
            banner.tap()  // the body: the default action
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the default action opens the app")
            observed["appStateAfterTap"] = Self.name(app.state)
            let completion = try await waitForCompletion(after: completedBefore)
            XCTAssertEqual(completion["outcome"], "ignored")
            XCTAssertEqual(completion["mainThread"], "true")
            let entriesAfter = try await entries(server: server, topicId: spikeCase.topicId).count
            XCTAssertEqual(entriesAfter, entriesBefore)
            attach("\(spikeCase.name)-opened")
            _ = try await post("result/\(spikeCase.name)", observed.merging(completion) { $1 })
            app.terminate()
            return
        }

        banner.press(forDuration: 1.5)  // expands it, with its actions
        let action = springboard.buttons[spikeCase.optionLabel]
        let shown = action.waitForExistence(timeout: 5)
        observed["actionsShown"] = String(shown)
        observed["buttons"] = springboard.buttons.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: ",")
        attach("\(spikeCase.name)-expanded")
        guard shown else {
            XCUIDevice.shared.press(.home)
            if spikeCase.kind != "observe" {
                XCTFail("\(spikeCase.name): the registered category's actions aren't shown")
            }
            _ = try await post("result/\(spikeCase.name)", observed)
            return
        }

        // A log or error action runs in the background: the app goes from not running to a
        // background state, never the foreground.
        XCTAssertEqual(app.state, .notRunning, "\(spikeCase.name): not running right before the tap")
        observed["appStateBeforeTap"] = Self.name(app.state)
        action.tap()
        let completion = try await waitForCompletion(after: completedBefore)
        observed["appStateAfterTap"] = Self.name(app.state)
        XCTAssertTrue(
            [.runningBackground, .runningBackgroundSuspended].contains(app.state),
            "\(spikeCase.name): the action ran in the background (state \(Self.name(app.state)))")
        XCTAssertEqual(completion["mainThread"], "true", "\(spikeCase.name): completion on the main thread")
        attach("\(spikeCase.name)-done")

        switch spikeCase.kind {
        case "log", "observe":
            XCTAssertEqual(completion["outcome"], "logged")
            let entry = try await waitForEntry(server: server, topicId: spikeCase.topicId, count: entriesBefore + 1)
            observed["entry"] = entry.map { String(describing: $0) } ?? "none"
            XCTAssertNotNil(entry, "\(spikeCase.name): the action logged an entry on the server")
            if let entry {
                XCTAssertEqual(entry["source"] as? String, "ios.notification")
                let answers = entry["answers"] as? [[String: Any]] ?? []
                XCTAssertTrue(answers.contains { $0["value"] as? String == spikeCase.optionValue }, "\(answers)")
            }
        case "error":
            XCTAssertEqual(completion["outcome"], "failed")
            let entriesAfter = try await entries(server: server, topicId: spikeCase.topicId).count
            XCTAssertEqual(entriesAfter, entriesBefore)
            let error = springboard.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Couldn't log")
            ).firstMatch
            XCTAssertTrue(error.waitForExistence(timeout: 30), "the handler posted Couldn't log")
            attach("\(spikeCase.name)-couldnt-log")
        default:
            XCTFail("unknown case kind \(spikeCase.kind)")
        }
        _ = try await post("result/\(spikeCase.name)", observed.merging(completion) { $1 })
        app.terminate()
    }

    // MARK: - The handler's log and the server

    /// The handler's `handler.completed` events, in order.
    @MainActor
    private func completions() async throws -> [[String: String]] {
        String(decoding: try await get("log"), as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                event["event"] == "handler.completed"
            else { return nil }
            return event
        }
    }

    /// Waits (30 s) for the handler's next completion.
    @MainActor
    private func waitForCompletion(after count: Int) async throws -> [String: String] {
        for _ in 0..<60 {
            let completed = try await completions()
            if completed.count > count { return completed[count] }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("the handler never completed")
        return [:]
    }

    @MainActor
    private func entries(server: String, topicId: String) async throws -> [[String: Any]] {
        let url = try XCTUnwrap(URL(string: "\(server)/api/v1/topics/\(topicId)/entries"))
        let (data, _) = try await URLSession.shared.data(from: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    /// Polls the server until the topic has `count` entries (30 s); returns the newest.
    @MainActor
    private func waitForEntry(server: String, topicId: String, count: Int) async throws -> [String: Any]? {
        for _ in 0..<60 {
            let items = try await entries(server: server, topicId: topicId)
            if items.count >= count { return items.first }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    @MainActor
    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: try coordinator.appending(path: path))
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "coordinator \(path)")
        return data
    }

    @MainActor
    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: try coordinator.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request).0
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func name(_ state: XCUIApplication.State) -> String {
        switch state {
        case .notRunning: "notRunning"
        case .runningBackgroundSuspended: "backgroundSuspended"
        case .runningBackground: "background"
        case .runningForeground: "foreground"
        default: "unknown"
        }
    }
}
