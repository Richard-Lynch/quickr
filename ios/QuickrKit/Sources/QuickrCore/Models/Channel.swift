/// The channel a write arrived through (`X-QuickR-Channel`, the server's `channel` enum).
public enum Channel: String, Sendable, Hashable, CaseIterable, Codable {
    case ui
    case api
    case mcp
    case ios
}

/// A topic's lifecycle state.
public enum TopicStatus: String, Sendable, Hashable, CaseIterable, Codable {
    case active
    case archived
}
