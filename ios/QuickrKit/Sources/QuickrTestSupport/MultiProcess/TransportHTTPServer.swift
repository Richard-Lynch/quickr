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
    public let port: UInt16

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public init(serving transport: any Transport) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "TransportHTTPServer")
        self.listener = listener
        self.queue = queue
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                switch state {
                case .ready where first: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error) where first: continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.connections.withLock { $0[ObjectIdentifier(connection)] = connection }
            connection.start(queue: queue)
            self.receive(connection, buffer: Data(), transport: transport)
        }
    }

    deinit { stop() }

    public func stop() {
        listener.cancel()
        for connection in connections.withLock({ Array($0.values) }) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data, transport: any Transport) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer, base: self.baseURL) {
                Task {
                    do {
                        let response = try await transport.send(request)
                        self.respond(response, on: connection)
                    } catch {
                        self.close(connection)
                    }
                }
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
