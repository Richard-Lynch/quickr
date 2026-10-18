import Foundation
import Network
import QuickrData
import Synchronization

/// Serves any in-process `Transport` (a fake quickR server) over HTTP/1.1 on 127.0.0.1, so child
/// processes reach it with the production `URLSessionTransport`. One request per connection
/// (`Connection: close`). The handler is async: a fake server can hold a request "in the
/// network" until the test opens a gate, which is the multi-process tests' network barrier.
///
/// A handler that throws a `TransportError` closes the connection without an answer (the
/// client sees a lost response).
public final class TransportHTTPServer: Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])
    /// Handler tasks still running (a request held at a gate), cancelled by `stop()`.
    private let handlers = Mutex<[UUID: Task<Void, Never>]>([:])
    public let port: UInt16

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public init(serving transport: any Transport, startupTimeout: Duration = .seconds(10)) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "TransportHTTPServer")
        self.listener = listener
        self.queue = queue
        let startup = Startup()
        let timer = Task {
            try await Task.sleep(for: startupTimeout)
            startup.finish(
                .failure(HelperError(description: "TransportHTTPServer: not ready within \(startupTimeout)")))
        }
        defer { timer.cancel() }
        do {
            port = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    startup.register(continuation)
                    // Only a terminal state finishes startup; `.waiting` and `.setup` keep waiting.
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready: startup.finish(.success(listener.port?.rawValue ?? 0))
                        case .failed(let error): startup.finish(.failure(error))
                        case .cancelled: startup.finish(.failure(HelperError(description: "listener cancelled")))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { $0.cancel() }
                    listener.start(queue: queue)
                }
            } onCancel: {
                // The caller gave up: end startup now and stop the listener.
                startup.finish(.failure(CancellationError()))
                listener.cancel()
            }
        } catch {
            listener.cancel()
            throw error
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.connections.withLock { $0[ObjectIdentifier(connection)] = connection }
            connection.start(queue: queue)
            self.receive(connection, buffer: Data(), transport: transport)
        }
    }

    deinit { cancel() }

    /// Stops listening, closes every connection, cancels the handler tasks and waits for them.
    public func stop() async {
        for handler in cancel() { await handler.value }
    }

    @discardableResult
    private func cancel() -> [Task<Void, Never>] {
        listener.cancel()
        for connection in connections.withLock({ Array($0.values) }) { connection.cancel() }
        let handlers = self.handlers.withLock { Array($0.values) }
        for handler in handlers { handler.cancel() }
        return handlers
    }

    private func receive(_ connection: NWConnection, buffer: Data, transport: any Transport) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer, base: self.baseURL) {
                let id = UUID()
                let handler = Task {
                    do {
                        let response = try await transport.send(request)
                        self.respond(response, on: connection)
                    } catch {
                        self.close(connection)
                    }
                    _ = self.handlers.withLock { $0.removeValue(forKey: id) }
                }
                self.handlers.withLock { $0[id] = handler }
            } else if complete || error != nil {
                self.close(connection)
            } else {
                self.receive(connection, buffer: buffer, transport: transport)
            }
        }
    }

    private func respond(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) Status\r\n"
        var headers = response.headers.all
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        connection.send(
            content: Data((head + "\r\n").utf8) + response.body,
            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        _ = connections.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    private static func parse(_ buffer: Data, base: URL) -> HTTPRequest? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2, let method = HTTPMethod(rawValue: String(start[0])),
            let url = URL(string: base.absoluteString + start[1])
        else { return nil }
        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(
            method: method, url: url, headers: headers, body: length > 0 ? Data(body.prefix(length)) : nil,
            timeout: .seconds(30))
    }
}

/// The listener's first terminal state, or the startup timeout, whichever comes first.
private final class Startup: Sendable {
    private let state = Mutex<
        (continuation: CheckedContinuation<UInt16, any Error>?, result: Result<UInt16, any Error>?)
    >(
        (nil, nil))

    func register(_ continuation: CheckedContinuation<UInt16, any Error>) {
        let result = state.withLock { state -> Result<UInt16, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<UInt16, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<UInt16, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}
