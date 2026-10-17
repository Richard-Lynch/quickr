// A child process for the multi-process store tests (sync-protocol.md §13, G5; outbox.md §13).
// Tests launch it with a command and a store path; it prints one line of result and exits 0, or
// prints the error to stderr and exits 1. `agent` is the long-running multi-process test agent
// (Agent.swift).
import Foundation
import QuickrCore
import QuickrData

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch arguments.first {
case "version":
    print(QuickrCore.version)
case "migrate":
    // migrate <store path>: open (creating) and migrate a store file.
    guard arguments.count == 2 else { fail("usage: ProcessHelper migrate <store path>") }
    do {
        _ = try StoreDatabase.openPool(at: URL(fileURLWithPath: arguments[1]))
        print("ok")
    } catch {
        fail("migrate failed: \(error)")
    }
case "agent":
    await runAgent(Array(arguments.dropFirst()))
default:
    fail("usage: ProcessHelper version | migrate <store path> | agent --root … --owner … …")
}
