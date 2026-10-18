import Foundation
import QuickrData

/// Real Darwin notifications (they cross processes, like production's `DarwinNotifier`), with
/// every name prefixed by a per-test scope, so concurrent test runs on one Mac never hear each
/// other's `db-changed` or `sync-requested`.
public struct ScopedDarwinNotifier: ChangeNotifier {
    public let scope: String
    private let darwin = DarwinNotifier()

    public init(scope: String) { self.scope = scope }

    public func post(_ name: ChangeSignalName) { darwin.post(scoped(name)) }

    public func signals(_ name: ChangeSignalName) -> AsyncStream<Void> { darwin.signals(scoped(name)) }

    private func scoped(_ name: ChangeSignalName) -> ChangeSignalName {
        ChangeSignalName(rawValue: "\(scope).\(name.rawValue)")
    }
}
