import Foundation
import Network
import Synchronization

/// A minimal HTTP/1.1 server on 127.0.0.1 for `URLSessionTransport` tests: one request per
/// connection, answered by `handler` (or never, when it returns nil). Records every request.
final class LoopbackServer: Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        /// Lowercased names.
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let recorded = Mutex<[Request]>([])
    private let held = Mutex<[NWConnection]>([])
    let port: UInt16

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [Request] { recorded.withLock { $0 } }

    init(_ handler: @escaping @Sendable (Request) -> Response?) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = queue
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
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            self?.receive(connection, buffer: Data(), handler: handler)
        }
    }

    deinit {
        listener.cancel()
        for connection in held.withLock({ $0 }) { connection.cancel() }
    }

    private func receive(
        _ connection: NWConnection, buffer: Data, handler: @escaping @Sendable (Request) -> Response?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.recorded.withLock { $0.append(request) }
                guard let response = handler(request) else {
                    self.held.withLock { $0.append(connection) }  // never answered
                    return
                }
                connection.send(
                    content: Self.serialize(response),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer, handler: handler)
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(start[0]), target: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func serialize(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) Status\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }
}

/// gzip (RFC 1952) around `NSData`'s raw DEFLATE, for the content-encoding test.
enum Gzip {
    static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        withUnsafeBytes(of: crc32(data).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
