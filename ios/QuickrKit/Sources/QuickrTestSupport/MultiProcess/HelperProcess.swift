// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import Synchronization

/// A `ProcessHelper agent` child: send commands, read replies, and SIGSTOP, SIGCONT or SIGKILL
/// it. Waiting is always on a reply line or a process exit (pipe barriers), never on a timer;
/// a `timeout` only turns a hang into a test failure.
public final class HelperProcess: @unchecked Sendable {
    fileprivate struct State {
        var nextId = 1
        var buffer = Data()
        var waiters: [Int: CheckedContinuation<HelperReply, any Error>] = [:]
        var replies: [Int: HelperReply] = [:]
        var exited = false
        var stderr = Data()
    }

    public let name: String
    private let process: Process
    private let stdin: FileHandle
    private let box = StateBox()

    public var pid: Int32 { process.processIdentifier }

    /// Launches `ProcessHelper agent` with `arguments` (`--root`, `--owner`, … as the agent reads
    /// them).
    public init(name: String, arguments: [String]) throws {
        self.name = name
        let process = Process()
        process.executableURL = try Self.executable()
        process.arguments = ["agent"] + arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.process = process
        stdin = input.fileHandleForWriting
        let box = box
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let ready = box.state.withLock { state -> [(CheckedContinuation<HelperReply, any Error>, HelperReply)] in
                state.buffer.append(data)
                var ready: [(CheckedContinuation<HelperReply, any Error>, HelperReply)] = []
                while let newline = state.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(state.buffer[..<newline])
                    state.buffer.removeSubrange(...newline)
                    guard let reply = try? JSONDecoder().decode(HelperReply.self, from: line) else { continue }
                    if let waiter = state.waiters.removeValue(forKey: reply.id) {
                        ready.append((waiter, reply))
                    } else {
                        state.replies[reply.id] = reply
                    }
                }
                return ready
            }
            for (waiter, reply) in ready { waiter.resume(returning: reply) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            box.state.withLock { $0.stderr.append(data) }
        }
        process.terminationHandler = { _ in
            let waiters = box.state.withLock { state -> [CheckedContinuation<HelperReply, any Error>] in
                state.exited = true
                defer { state.waiters = [:] }
                return Array(state.waiters.values)
            }
            for waiter in waiters { waiter.resume(throwing: HelperError(description: "\(name) exited")) }
        }
        try process.run()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// The child's stderr so far (for failure messages).
    public var stderr: String { box.stderr }

    public var isRunning: Bool { process.isRunning }

    /// Sends a command without waiting; `reply(_:)` waits for its answer.
    @discardableResult
    public func start(_ name: String, _ args: [String: String] = [:]) throws -> Int {
        let id = box.state.withLock { state in
            defer { state.nextId += 1 }
            return state.nextId
        }
        var line = try JSONEncoder().encode(HelperCommand(id: id, name: name, args: args))
        line.append(UInt8(ascii: "\n"))
        try stdin.write(contentsOf: line)
        return id
    }

    /// Waits for the reply to command `id`.
    public func reply(_ id: Int, timeout: Duration = .seconds(30)) async throws -> HelperReply {
        let name = self.name
        let box = box
        return try await withThrowingTaskGroup(of: HelperReply.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let action: Result<HelperReply, any Error>? = box.state.withLock { state in
                        if let reply = state.replies.removeValue(forKey: id) { return .success(reply) }
                        if state.exited { return .failure(HelperError(description: "\(name) exited")) }
                        state.waiters[id] = continuation
                        return nil
                    }
                    if let action { continuation.resume(with: action) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HelperError(description: "\(name): no reply to #\(id) within \(timeout); stderr: \(box.stderr)")
            }
            let reply = try await group.next()!
            group.cancelAll()
            return reply
        }
    }

    /// Sends a command and waits for its reply; throws if the child reports an error.
    @discardableResult
    public func run(_ name: String, _ args: [String: String] = [:], timeout: Duration = .seconds(30)) async throws
        -> [String: String]
    {
        let reply = try await reply(try start(name, args), timeout: timeout)
        guard reply.ok else { throw HelperError(description: "\(self.name) \(name): \(reply.error ?? "failed")") }
        return reply.result
    }

    /// SIGSTOP: the process is frozen mid-flight; it can't renew a lease or read a response.
    public func suspend() { kill(process.processIdentifier, SIGSTOP) }

    /// SIGCONT.
    public func resume() { kill(process.processIdentifier, SIGCONT) }

    /// SIGKILL, then waits for the exit: the process dies holding whatever it held.
    public func killNow() async {
        kill(process.processIdentifier, SIGKILL)
        await waitForExit()
    }

    /// Closes stdin (the agent exits when it reads EOF) and waits for the exit.
    public func finish() async {
        try? stdin.close()
        await waitForExit()
    }

    public func waitForExit() async {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// `ProcessHelper` next to the test bundle (SwiftPM puts both in the build directory), or
    /// `$QUICKR_PROCESS_HELPER`.
    public static func executable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["QUICKR_PROCESS_HELPER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // This code is linked into the test bundle: its bundle sits in the products directory.
        let bundles = [Bundle(for: HelperProcess.self)] + Bundle.allBundles
        for bundle in bundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appending(path: "ProcessHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = directory.appending(path: "ProcessHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw HelperError(
            description: "ProcessHelper not found next to \(Bundle(for: HelperProcess.self).bundlePath) "
                + "(build it, or set QUICKR_PROCESS_HELPER)")
    }
}

private final class StateBox: Sendable {
    let state = Mutex(HelperProcess.State())

    var stderr: String { String(decoding: state.withLock { $0.stderr }, as: UTF8.self) }
}
#endif
