import Foundation
import GRDB
import QuickrData
import QuickrTestSupport
import Testing

/// `TestFiles.remove` never unlinks a database file that is still open: it waits for the pool to
/// close, then removes the directory.
@Suite(.timeLimit(.minutes(2))) struct TestFilesTests {
    @Test func aDirectoryWithAnOpenPoolGoesOnceThePoolCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quickr-testfiles-\(UUID().uuidString)")
        var pool: DatabasePool? = try StoreDatabase.openPool(at: directory.appending(path: "store.sqlite"))
        _ = try await pool?.read { db in try Int.fetchOne(db, sql: "SELECT 1") }

        TestFiles.remove(directory)
        #expect(FileManager.default.fileExists(atPath: directory.path), "kept while the pool is open")
        _ = try await pool?.read { db in try Int.fetchOne(db, sql: "SELECT 1") }

        pool = nil
        try await eventually("the directory is removed") { !FileManager.default.fileExists(atPath: directory.path) }
    }

    @Test func aDirectoryWithNothingOpenGoesAtOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "quickr-testfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appending(path: "file"))
        TestFiles.remove(directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func onlyPathsInsideTheDirectoryCount() {
        #expect(TestFiles.isInUse("/tmp/a", open: ["/tmp/a/store.sqlite"]))
        #expect(TestFiles.isInUse("/tmp/a", open: ["/tmp/a"]))
        #expect(!TestFiles.isInUse("/tmp/a", open: ["/tmp/ab/store.sqlite", "/tmp/b"]))
    }
}
