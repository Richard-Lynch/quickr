import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// `ReadOnlyStores` (the widget's read path): read-only opens that never create, migrate, recover
/// or change anything, and read as "no store" whenever the app has to act first.
@Suite struct ReadOnlyStoresTests {
    /// Every file under the root (path, size, modification time) and the registry's rows.
    static func fingerprint(_ root: URL) throws -> String {
        var out: [String] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in files {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let path = url.path.replacingOccurrences(of: root.path, with: "")
                out.append(
                    "\(path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        let registry = root.appending(path: "registry.sqlite")
        if FileManager.default.fileExists(atPath: registry.path) {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: registry.path, configuration: configuration)
            try queue.read { db in
                out.append("\(try Row.fetchAll(db, sql: "SELECT * FROM server ORDER BY server_id"))")
                out.append("\(try Row.fetchAll(db, sql: "SELECT * FROM active"))")
            }
        }
        return out.sorted().joined(separator: "\n")
    }

    func expectUnchanged(_ root: URL, _ body: () async throws -> Void) async throws {
        let before = try Self.fingerprint(root)
        try await body()
        #expect(try Self.fingerprint(root) == before)
    }

    @Test func aFreshInstallHasNoStoreAndNothingIsCreated() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let stores = ReadOnlyStores(location: StoreLocation(root: dir.url))
        try await expectUnchanged(dir.url) {
            let store = try stores.activeStore()
            let topics = try await ActiveStoreTopicRepository(readOnly: stores).topics()
            #expect(store == nil)
            #expect(topics.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }

    @Test func anActiveServerWithoutItsFileReadsAsNoStore() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let partitions = try StorePartitions.open(at: StoreLocation(root: dir.url), notifier: nil)
        _ = try await partitions.registry.register(serverId: "s", baseURL: "https://q.example", now: Make.t0)
        try await partitions.registry.setActive("s")
        let stores = ReadOnlyStores(location: StoreLocation(root: dir.url))
        try await expectUnchanged(dir.url) {
            let store = try stores.activeStore()
            let topics = try await ActiveStoreTopicRepository(readOnly: stores).topics()
            #expect(store == nil)
            #expect(topics.isEmpty)
        }
    }

    @Test func anInterruptedResetReadsAsNoStoreAndIsLeftForTheApp() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let partitions = try StorePartitions.open(at: StoreLocation(root: dir.url), notifier: nil)
        let store = try await partitions.createStore(serverId: "s", baseURL: "https://q.example")
        try await partitions.registry.setActive("s")
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, topic: Make.topic()) }
        _ = try await partitions.persistResetIntent(store: store, confirmedCount: 0, confirmedMaxSeq: 0)
        let stores = ReadOnlyStores(location: StoreLocation(root: dir.url))
        try await expectUnchanged(dir.url) {
            let store = try stores.activeStore()
            let topics = try await ActiveStoreTopicRepository(readOnly: stores).topics()
            #expect(store == nil)
            #expect(topics.isEmpty)
        }
        // The app's partitions don't read it as a plain store either.
        #expect(try await partitions.openActiveStoreIfExists() == nil)
    }

    @Test func aReadyStoreIsReadWithoutChangingAnything() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let partitions = try StorePartitions.open(at: StoreLocation(root: dir.url), notifier: nil)
        let store = try await partitions.createStore(serverId: "s", baseURL: "https://q.example")
        try await partitions.registry.setActive("s")
        let topic = Make.topic()
        try await store.writer.write { db in _ = try ServerLayer.upsert(db, topic: topic) }
        let stores = ReadOnlyStores(location: StoreLocation(root: dir.url))
        try await expectUnchanged(dir.url) {
            let topics = try await ActiveStoreTopicRepository(readOnly: stores).topics()
            let store = try stores.activeStore()
            #expect(topics.map(\.id) == [topic.id])
            #expect(store?.serverId == "s")
        }
        // Writing through the read-only pool fails.
        let readOnly = try #require(try stores.activeStore())
        #expect(throws: (any Error).self) {
            try readOnly.writer.write { db in try db.execute(sql: "DELETE FROM topic") }
        }
    }
}
