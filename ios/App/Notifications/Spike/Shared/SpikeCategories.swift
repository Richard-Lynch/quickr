#if DEBUG
import Foundation
import GRDB
import QuickrCore
import QuickrData
import UserNotifications

// SPIKE (M1, docs/ios/demo/m1/spike-findings.md): just enough of notifications.md §4–§5 to prove,
// on the simulator, that a category registered from the registry table carries its actions to a
// notification, from the app or from the Notification Service Extension. Compiled into the app
// and the NSE, DEBUG only. CAT replaces this: it renders categories locally from topics and owns
// the §4.3 hash and §4.4 fmt (here the category id comes from the server's payload).
enum SpikeCategories {
    /// The registry's `notification_category` row for a reminder: its id is the payload's
    /// `aps.category` (computed by the server, B7), its actions rendered from `quick_log`.
    struct CategoryRow: Sendable, Hashable {
        var id: String
        var serverId: String
        var topicId: String
        var actions: [NotificationActionSpec]
    }

    /// The §4.1 actions of an **enum** descriptor: one `log` action per option, titled with its
    /// label, identified `q1|{server_id}|{topic_id}|{version}|{key}|o|{value}` (§4.2). Number
    /// descriptors need the §4.4 `fmt` (CAT's) and "More…" needs an `open` action kind the C1
    /// contract doesn't have yet: the spike leaves both out (nil).
    static func actions(for info: QuickrNotificationInfo) -> [NotificationActionSpec]? {
        guard let topicId = info.topicId, let version = info.version, case .choice(let choice) = info.quickLog,
            choice.totalOptions == choice.options.count
        else { return nil }
        return choice.options.map { option in
            NotificationActionSpec(
                id: ["q1", info.serverId, topicId, String(version), choice.key, "o", option.value].joined(
                    separator: "|"),
                title: option.label, kind: .log)
        }
    }

    /// The row for a payload (`aps.category` and `quickr`), when the spike can render it.
    static func row(userInfo: [AnyHashable: Any]) -> CategoryRow? {
        guard let info = info(userInfo: userInfo), let topicId = info.topicId,
            let category = (userInfo["aps"] as? [String: Any])?["category"] as? String,
            let actions = actions(for: info)
        else { return nil }
        return CategoryRow(id: category, serverId: info.serverId, topicId: topicId, actions: actions)
    }

    static func info(userInfo: [AnyHashable: Any]) -> QuickrNotificationInfo? {
        guard let quickr = userInfo["quickr"], JSONSerialization.isValidJSONObject(quickr),
            let data = try? JSONSerialization.data(withJSONObject: quickr)
        else { return nil }
        return try? JSONDecoder().decode(QuickrNotificationInfo.self, from: data)
    }

    // MARK: - §5.2 registration, §5.3 reconciliation

    /// `register(newRows)`: one `IMMEDIATE` registry transaction inserts the rows, reads the whole
    /// table and replaces the app's category set with it (`setNotificationCategories` is
    /// synchronous; nothing is awaited inside the transaction). Returns the registered ids.
    @discardableResult
    static func register(_ rows: [CategoryRow], registry: Registry, wall: Date = Date()) async throws -> [String] {
        try await registry.writer.writeWithoutTransaction { db in
            var ids: [String] = []
            try db.inTransaction(.immediate) {
                for row in rows {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO notification_category (id, server_id, topic_id, actions_json, created_at)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            row.id, row.serverId, row.topicId, try encode(row.actions), wall.timeIntervalSince1970,
                        ])
                }
                var categories = Set<UNNotificationCategory>()
                for stored in try GRDB.Row.fetchAll(db, sql: "SELECT id, actions_json FROM notification_category") {
                    let id: String = stored["id"]
                    let actions = try decode(stored["actions_json"])
                    categories.insert(category(id: id, actions: actions))
                    ids.append(id)
                }
                UNUserNotificationCenter.current().setNotificationCategories(categories)
                return .commit
            }
            return ids.sorted()
        }
    }

    /// `reconcile()`: re-registers the union when the system has lost any of the table's ids.
    static func reconcile(registry: Registry) async throws -> Bool {
        let registered = Set(await UNUserNotificationCenter.current().notificationCategories().map(\.identifier))
        let ids = Set(
            try await registry.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM notification_category")
            })
        guard !ids.isSubset(of: registered) else { return false }
        try await register([], registry: registry)
        return true
    }

    static func category(id: String, actions: [NotificationActionSpec]) -> UNNotificationCategory {
        let built: [UNNotificationAction] = actions.map { action in
            switch action.kind {
            case .log:
                // No .foreground: logging runs in the background (§4.1).
                UNNotificationAction(identifier: action.id, title: action.title, options: [])
            case .input(let buttonTitle, let placeholder):
                UNTextInputNotificationAction(
                    identifier: action.id, title: action.title, options: [], textInputButtonTitle: buttonTitle,
                    textInputPlaceholder: placeholder)
            case .open:
                // "More…": the one action that opens the app (§4.1).
                UNNotificationAction(identifier: action.id, title: action.title, options: [.foreground])
            }
        }
        return UNNotificationCategory(identifier: id, actions: built, intentIdentifiers: [], options: [])
    }

    // `actions_json`: the rendered descriptor, `[{kind, identifier, title}]`.
    private struct StoredAction: Codable {
        var kind: String
        var identifier: String
        var title: String
    }

    private static func encode(_ actions: [NotificationActionSpec]) throws -> String {
        let stored = actions.map { action -> StoredAction in
            if case .input = action.kind {
                return StoredAction(kind: "input", identifier: action.id, title: action.title)
            }
            return StoredAction(kind: "log", identifier: action.id, title: action.title)
        }
        return String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
    }

    private static func decode(_ json: String) throws -> [NotificationActionSpec] {
        try JSONDecoder().decode([StoredAction].self, from: Data(json.utf8)).map { stored in
            NotificationActionSpec(
                id: stored.identifier, title: stored.title,
                kind: stored.kind == "input"
                    ? .input(buttonTitle: "Log", placeholder: "Value") : stored.kind == "open" ? .open : .log)
        }
    }
}

/// The spike's opt-in: a marker file in the App Group (`Library/quickr/spike-enabled`). The app
/// creates it when launched with `-spikeServer`; `spike-proof.sh` removes it when it finishes.
/// A file, not a launch argument, because a notification action launches the app in the
/// background with no arguments, and the NSE never gets any: both check it. Without it the spike
/// does nothing, in every process, even in Debug builds.
enum SpikeGate {
    static var marker: URL? { SpikeLog.location?.root.appending(path: "spike-enabled") }

    static var isEnabled: Bool { marker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    static func enable() {
        guard let marker else { return }
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
}

/// Where the spike's shared files live, and its event log: one JSON line per event, from any
/// process, for the findings (handler launch state, timings, NSE runs).
enum SpikeLog {
    static let appGroup = "group.com.bahumia.quickr"

    static var location: StoreLocation? { try? StoreLocation.appGroup(appGroup) }

    static func append(_ event: String, _ fields: [String: String] = [:]) {
        guard let root = location?.root else { return }
        var record = fields
        record["event"] = event
        record["at"] = Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        record["process"] = ProcessInfo.processInfo.processName
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        line.append(UInt8(ascii: "\n"))
        let url = root.appending(path: "spike-log.jsonl")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}

#endif
