import Foundation
import GRDB

/// A request context `(store file, layer_gen, epoch)` (sync-protocol.md glossary, §5.5), captured
/// before an online-only request, a refetch or a GET is sent. Its outcome is applied only while
/// the context is still current: after a swap (`layer_gen`) or a reset (another file, `retired`)
/// it is discarded and the next pull brings the result instead (§7 step 5, §11).
public struct RequestContext: Sendable, Hashable {
    public var serverId: String
    public var storeGen: Int
    public var layerGen: Int
    public var epoch: String?

    public init(serverId: String, storeGen: Int, layerGen: Int, epoch: String?) {
        self.serverId = serverId
        self.storeGen = storeGen
        self.layerGen = layerGen
        self.epoch = epoch
    }

    /// The identity a mutation sends as F10 preconditions, and a GET is checked against.
    public var identity: ServerIdentity? { epoch.map { ServerIdentity(serverId: serverId, epoch: $0) } }

    /// Server-layer writes from an online-only response (§5.5 "everything").
    public var conditions: [StoreFence.Condition] { [.notRetired, .layerGen(layerGen), .epoch(epoch)] }
}

extension LocalStore {
    /// Captures the context of a request about to be sent.
    public func requestContext() async throws -> RequestContext {
        guard let state = try await syncState.syncState() else { throw StoreError.notBootstrapped }
        return RequestContext(serverId: serverId, storeGen: storeGen, layerGen: state.layerGen, epoch: state.epoch)
    }

    /// Runs `body` in one `IMMEDIATE` transaction if `context` still holds; otherwise writes
    /// nothing and returns the fence failure. A context from another file is `.retired`.
    public func applyFenced<T: Sendable>(_ context: RequestContext, _ body: @escaping @Sendable (Database) throws -> T)
        async throws -> Result<T, FenceFailure>
    {
        guard context.serverId == serverId, context.storeGen == storeGen else { return .failure(.retired) }
        let clock = leaseClock
        return try await writer.write { db in
            if let failure = try StoreFence.check(db, context.conditions, at: clock.now()) { return .failure(failure) }
            return .success(try body(db))
        }
    }
}
