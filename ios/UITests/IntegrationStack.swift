import XCTest

/// This worktree's integration stack, from the test runner: the backend's API (direct, so a
/// fault rule never hides what the server has) and the fault proxy's control API.
@MainActor
struct Stack {
    struct Topic {
        let id: String
        let slug: String
        let name: String
    }

    /// What the app talks to: the proxy.
    let baseURL: String
    let directURL: URL
    let controlURL: URL

    static func fromEnvironment() throws -> Stack {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["QUICKR_IT_BASE_URL"], let direct = env["QUICKR_IT_DIRECT_URL"].flatMap(URL.init),
            let control = env["QUICKR_IT_PROXY_CONTROL_URL"].flatMap(URL.init)
        else {
            if env["QUICKR_IT_REQUIRED"] == "1" {
                throw NSError(
                    domain: "EndToEnd", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "QUICKR_IT_REQUIRED=1 but the stack's URLs are missing"])
            }
            throw XCTSkip("No integration stack (run make ios-uitest-e2e)")
        }
        return Stack(baseURL: base, directURL: direct, controlURL: control)
    }

    /// The app on a clean slate, connected to the stack (through the proxy); `url` opens once
    /// the root is up, as a link would.
    func launch(open url: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-QuickrUITest", "-QuickrServer", baseURL]
        if let url { app.launchArguments += ["-QuickrOpen", url] }
        app.launch()
        return app
    }

    static func int(
        _ key: String, _ label: String, max: Int, unit: String? = nil, required: Bool = true
    ) -> [String: Any] {
        var question: [String: Any] = ["key": key, "label": label, "type": "int", "min": 0, "max": max]
        question["unit"] = unit
        question["required"] = required
        return question
    }

    static func double(_ key: String, _ label: String, max: Int, unit: String? = nil, required: Bool = true)
        -> [String: Any]
    {
        var question = int(key, label, max: max, unit: unit, required: required)
        question["type"] = "double"
        return question
    }

    static func choice(_ key: String, _ label: String, _ options: KeyValuePairs<String, String>) -> [String: Any] {
        ["key": key, "label": label, "type": "enum", "options": options.map { ["value": $0.key, "label": $0.value] }]
    }

    /// A topic with a unique name (the stack lives for the whole run).
    func createTopic(_ name: String, questions: [[String: Any]]) async throws -> Topic {
        let unique = "\(name) \(UUID().uuidString.prefix(4))"
        let object = try await call(directURL, "POST", "/api/v1/topics", ["name": unique, "questions": questions])
        return Topic(id: try string(object, "id"), slug: try string(object, "slug"), name: unique)
    }

    func createEntry(_ topic: Topic, answers: [String: Any]) async throws {
        let body: [String: Any] = [
            "id": UUID().uuidString.lowercased(), "answers": answers,
            "captured_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
        ]
        _ = try await call(directURL, "POST", "/api/v1/topics/\(topic.id)/entries", body)
    }

    func entries(_ topic: Topic) async throws -> [[String: Any]] {
        let object = try await call(directURL, "GET", "/api/v1/topics/\(topic.id)/entries")
        guard let items = (object as? [String: Any])?["items"] as? [[String: Any]] ?? object as? [[String: Any]] else {
            throw failure("entries: unexpected reply \(object)")
        }
        return items
    }

    /// One answer's value from an entry (`answers` is a list of `{key, type, value}`).
    static func answer(_ entry: [String: Any], _ key: String) -> Any? {
        (entry["answers"] as? [[String: Any]])?.first { $0["key"] as? String == key }?["value"]
    }

    /// Archives and deletes every topic, so each test (and its screenshots) shows only its own
    /// topics, not those of earlier tests or the harness's smoke check.
    func removeAllTopics() async throws {
        let page = try await call(directURL, "GET", "/api/v1/topics?status=all&limit=200")
        let items = (page as? [String: Any])?["items"] as? [[String: Any]] ?? []
        for id in items.compactMap({ $0["id"] as? String }) {
            if items.first(where: { $0["id"] as? String == id })?["status"] as? String != "archived" {
                _ = try await call(directURL, "POST", "/api/v1/topics/\(id)/archive")
            }
            _ = try await call(directURL, "DELETE", "/api/v1/topics/\(id)")
        }
    }

    func resetProxy() async throws { _ = try await call(controlURL, "POST", "/reset") }

    /// Every request through the proxy fails as if the network were down.
    func goOffline() async throws {
        _ = try await call(controlURL, "POST", "/rules", ["action": "drop_request", "path": "*", "sticky": true])
    }

    func goOnline() async throws { _ = try await call(controlURL, "DELETE", "/rules") }

    /// Polls every 0.25 s until `check` returns a value; fails after `timeout`.
    func eventually<T>(_ what: String, timeout: TimeInterval = 15, _ check: () async throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try await check() { return value }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw failure("timed out: \(what)")
    }

    private func call(_ base: URL, _ method: String, _ path: String, _ body: Any? = nil) async throws -> Any {
        guard let url = URL(string: base.absoluteString + path) else { throw failure("bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw failure("\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))")
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    private func string(_ object: Any, _ key: String) throws -> String {
        guard let value = (object as? [String: Any])?[key] as? String else { throw failure("no \(key) in \(object)") }
        return value
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "EndToEnd", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension XCUIElement {
    /// Replaces a text field's contents: the cursor goes to the end, the old text is deleted.
    func replaceText(_ text: String) {
        coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    func waitForLabel(prefix: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
