import Foundation
import GRDB
import Synchronization

/// `ValueObservation` as an `AsyncSequence` for the UI. GRDB observation sees this process's
/// writes; `refresh` adds the ones it can't see: another process's commits (Darwin `db-changed`)
/// and the app becoming active (`RefreshSignal`). Consecutive equal values are dropped.
public enum StoreObservation {
    public static func values<Value: Sendable & Equatable>(
        in reader: any DatabaseReader, refresh: AsyncStream<Void>? = nil,
        fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let last = Mutex<Value?>(nil)
            let emit: @Sendable (Value) -> Void = { value in
                let changed = last.withLock { last in
                    guard last != value else { return false }
                    last = value
                    return true
                }
                if changed { continuation.yield(value) }
            }
            let observation = ValueObservation.tracking(fetch)
            let observer = Task {
                do {
                    for try await value in observation.values(in: reader) { emit(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let refresher = Task {
                guard let refresh else { return }
                for await _ in refresh {
                    do {
                        emit(try await reader.read(fetch))
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                observer.cancel()
                refresher.cancel()
            }
        }
    }
}
