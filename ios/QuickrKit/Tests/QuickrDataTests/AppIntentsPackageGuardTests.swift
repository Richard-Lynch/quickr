import Foundation
import Testing

/// No Swift source under ios/ may declare or include an `AppIntentsPackage`. iOS 26.0's linkd
/// rejects an include of a statically linked package and drops every intent in the bundle (see
/// QuickrData/Intents/QuickrDataIntents.swift). `IntentMetadataTests` catches it in the built
/// bundles; this catches it in source, on the host, before any build.
@Test(.timeLimit(.minutes(5))) func noSourceDeclaresAnAppIntentsPackage() throws {
    let ios = URL(fileURLWithPath: #filePath)  // ios/QuickrKit/Tests/QuickrDataTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let skipped: Set<String> = ["build", ".build", "quickR.xcodeproj"]
    let pattern = try Regex(#"[:,]\s*AppIntentsPackage\b|\bincludedPackages\b"#)
    var offenders: [String] = []
    let files = try #require(FileManager.default.enumerator(at: ios, includingPropertiesForKeys: [.isDirectoryKey]))
    for case let url as URL in files {
        if skipped.contains(url.lastPathComponent) {
            files.skipDescendants()
            continue
        }
        guard url.pathExtension == "swift", url.lastPathComponent != "AppIntentsPackageGuardTests.swift" else {
            continue
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            if code.contains(pattern) { offenders.append("\(url.path):\(number + 1): \(code)") }
        }
    }
    #expect(offenders.isEmpty, "AppIntentsPackage is banned under ios/:\n\(offenders.joined(separator: "\n"))")
    let projectSpec = ios.appendingPathComponent("project.yml").path
    #expect(FileManager.default.fileExists(atPath: projectSpec), "scanned \(ios.path)")
}
