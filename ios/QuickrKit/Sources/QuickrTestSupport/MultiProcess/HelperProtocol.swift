import Foundation

/// One line of the `ProcessHelper agent` protocol: the test writes a command to the child's
/// stdin; the child answers each command with one line on stdout, in completion order. Commands
/// run concurrently in the child, so a test can start a flush that blocks "in the network" and
/// keep talking to the process.
public struct HelperCommand: Codable, Sendable {
    public var id: Int
    public var name: String
    public var args: [String: String]

    public init(id: Int, name: String, args: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.args = args
    }
}

public struct HelperReply: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var result: [String: String]
    public var error: String?

    public init(id: Int, ok: Bool, result: [String: String] = [:], error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}

public struct HelperError: Error, CustomStringConvertible {
    public var description: String

    public init(description: String) { self.description = description }
}
