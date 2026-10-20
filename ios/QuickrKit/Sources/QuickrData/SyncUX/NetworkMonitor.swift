import Foundation
import Network

/// Whether the device has a usable network path, as a stream: the current state first, then
/// every change. The app's is `NWNetworkMonitor`; tests use `FakeNetworkMonitor`.
public protocol NetworkMonitoring: Sendable {
    func updates() -> AsyncStream<Bool>
}

/// `NWPathMonitor`: one monitor per stream, cancelled when the stream ends.
public struct NWNetworkMonitor: NetworkMonitoring {
    public init() {}

    public func updates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "quickr.network-monitor"))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }
}
