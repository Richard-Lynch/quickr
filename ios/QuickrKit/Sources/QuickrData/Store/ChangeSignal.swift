import Foundation
import Synchronization
import notify

/// The cross-process signals (sync-protocol.md §4.1 step 7, §5.6, §8.1). GRDB observation can't
/// see another process's writes, so every writer posts one of these after it commits, and readers
/// re-fetch when one arrives.
public struct ChangeSignalName: RawRepresentable, Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// A store transaction committed.
    public static let dbChanged = ChangeSignalName(rawValue: "com.bahumia.quickr.db-changed")
    /// A registry transaction committed (a store generation or the active server may have changed).
    public static let registryChanged = ChangeSignalName(rawValue: "com.bahumia.quickr.registry-changed")
    /// An extension asks the app's coordinator to run (§5.6).
    public static let syncRequested = ChangeSignalName(rawValue: "com.bahumia.quickr.sync-requested")
}

/// Posts and observes cross-process signals. `DarwinNotifier` in production; tests may record.
public protocol ChangeNotifier: Sendable {
    func post(_ name: ChangeSignalName)
    /// Every post of `name` from any process, this one included, until the stream is dropped.
    func signals(_ name: ChangeSignalName) -> AsyncStream<Void>
}

/// Darwin notifications (`notify(3)`), which reach every process on the device.
public struct DarwinNotifier: ChangeNotifier {
    public init() {}

    public func post(_ name: ChangeSignalName) {
        notify_post(name.rawValue)
    }

    public func signals(_ name: ChangeSignalName) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name.rawValue, &token, DispatchQueue.global(qos: .utility)) { _ in
                continuation.yield()
            }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }
}

/// The re-fetch trigger for UI observations: Darwin `db-changed` from other processes, plus
/// explicit pokes, such as the app becoming active (sync-protocol.md §9).
public final class RefreshSignal: Sendable {
    private let notifier: (any ChangeNotifier)?
    private let names: [ChangeSignalName]
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    public init(notifier: (any ChangeNotifier)?, names: [ChangeSignalName] = [.dbChanged]) {
        self.notifier = notifier
        self.names = names
    }

    /// Re-fetch everywhere now (scenePhase → active).
    public func poke() {
        for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield() }
    }

    /// A new stream of triggers. Each subscriber gets its own.
    public func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        let forwarders = (notifier.map { notifier in names.map { notifier.signals($0) } } ?? []).map { signals in
            Task {
                for await _ in signals { continuation.yield() }
            }
        }
        continuation.onTermination = { [weak self] _ in
            for forwarder in forwarders { forwarder.cancel() }
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }
}
