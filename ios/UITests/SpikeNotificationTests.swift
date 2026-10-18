import XCTest

/// SPIKE (M1, docs/ios/demo/m1/spike-findings.md): a reminder's action logs an entry while the
/// app is not running, on the simulator, against a real backend.
///
/// Driven by `ios/scripts/spike-proof.sh`, which brings up the integration stack, creates the
/// topics, renders their APNs payloads with the server's own code and serves a small coordinator
/// on the host. The test asks the coordinator to push (`GET /push/<case>`: it runs
/// `xcrun simctl push` and answers once it has), then drives SpringBoard: expand the banner, tap
/// the option. It asserts the entry on the server (`GET /api/v1/topics/{id}/entries`) and reports
/// what it saw (`POST /result/<case>`) for the findings.
///
/// Cases (from the coordinator's `/cases`):
/// - `app-registered`: the app registered the category through the registry table before it was
///   killed (CAT's primary path, notifications.md §5.2).
/// - `nse-only`: only the Notification Service Extension registers it, while preparing that
///   notification (§6, the backstop). Whether its actions show is the finding; it isn't asserted.
///
/// Not in the UI plan (SpringBoard automation can stall); its own plan, run by the script.
final class SpikeNotificationTests: XCTestCase {
    struct SpikeCase: Decodable {
        var name: String
        var topicId: String
        var topicName: String
        var optionLabel: String
        var optionValue: String
        var appRegistered: Bool
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
        addUIInterruptionMonitor(withDescription: "notification permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        app.launch()
        let status = app.staticTexts["spike.status"]
        for _ in 0..<30 where !(status.exists && status.label.hasPrefix("spike: ready")) {
            if springboard.alerts.buttons["Allow"].exists { springboard.alerts.buttons["Allow"].tap() }
            app.tap()  // lets the interruption monitor run
            sleep(1)
        }
        XCTAssertTrue(status.label.hasPrefix("spike: ready"), "app setup: \(status.label)")
        attach("app-ready")
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)

        for spikeCase in setup.cases {
            try await run(spikeCase, app: app, server: setup.server)
        }
    }

    @MainActor
    private func run(_ spikeCase: SpikeCase, app: XCUIApplication, server: String) async throws {
        XCUIDevice.shared.press(.home)
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
        banner.press(forDuration: 1.5)  // expands it, with its actions
        let action = springboard.buttons[spikeCase.optionLabel]
        let shown = action.waitForExistence(timeout: 5)
        observed["actionsShown"] = String(shown)
        observed["buttons"] = springboard.buttons.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: ",")
        attach("\(spikeCase.name)-expanded")

        if shown {
            observed["appStateBeforeTap"] = Self.name(app.state)
            action.tap()
            let entry = try await waitForEntry(server: server, topicId: spikeCase.topicId)
            observed["entry"] = entry.map { String(describing: $0) } ?? "none"
            observed["appStateAfterTap"] = Self.name(app.state)
            attach("\(spikeCase.name)-logged")
            if let entry {
                XCTAssertEqual(entry["source"] as? String, "ios.notification")
                let answers = entry["answers"] as? [[String: Any]] ?? []
                XCTAssertTrue(answers.contains { $0["value"] as? String == spikeCase.optionValue }, "\(answers)")
            }
            if spikeCase.appRegistered {
                XCTAssertNotNil(entry, "\(spikeCase.name): the action logged an entry on the server")
            }
        } else {
            XCUIDevice.shared.press(.home)
            if spikeCase.appRegistered {
                XCTFail("\(spikeCase.name): the app-registered category's actions aren't shown")
            }
        }
        _ = try await post("result/\(spikeCase.name)", observed)
        // Leave the app not running for the next case.
        app.terminate()
    }

    /// Polls the server for the topic's entries until one appears (30 s).
    @MainActor
    private func waitForEntry(server: String, topicId: String) async throws -> [String: Any]? {
        let url = try XCTUnwrap(URL(string: "\(server)/api/v1/topics/\(topicId)/entries"))
        for _ in 0..<60 {
            let (data, _) = try await URLSession.shared.data(from: url)
            let page = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let first = (page?["items"] as? [[String: Any]])?.first { return first }
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
