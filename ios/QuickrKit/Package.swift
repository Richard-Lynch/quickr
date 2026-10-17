// swift-tools-version: 6.2
// quickR's shared code. Core, Data and TestSupport also build for macOS so `swift test` runs on the
// host; UI is iOS-only (its sources are guarded with `#if os(iOS)`). See docs/ios/PLAN.md §2.
import PackageDescription

let package = Package(
    name: "QuickrKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "QuickrCore", targets: ["QuickrCore"]),
        .library(name: "QuickrData", targets: ["QuickrData"]),
        .library(name: "QuickrUI", targets: ["QuickrUI"]),
        // Test-only: fixtures, fakes and an in-memory store. Never linked into a shipping target.
        .library(name: "QuickrTestSupport", targets: ["QuickrTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(name: "QuickrCore"),
        .target(
            name: "QuickrData",
            dependencies: ["QuickrCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "QuickrUI", dependencies: ["QuickrCore"], resources: [.process("Resources")]),
        .target(
            name: "QuickrTestSupport",
            dependencies: ["QuickrCore", "QuickrData", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Child process for the multi-process store tests (sync-protocol.md §13, G5). Host only.
        .executableTarget(
            name: "ProcessHelper",
            dependencies: ["QuickrData", "QuickrTestSupport", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "QuickrCoreTests", dependencies: ["QuickrCore", "QuickrTestSupport"]),
        // Design-system logic tests (not "QuickrUITests": that would collide with the QuickRUITests
        // UI-test bundle on case-insensitive disks).
        .testTarget(name: "QuickrDesignTests", dependencies: ["QuickrUI"]),
        .testTarget(
            name: "QuickrDataTests",
            dependencies: [
                "QuickrData", "QuickrTestSupport", .product(name: "GRDB", package: "GRDB.swift"),
                // Built for the multi-process tests, which launch it (Tests/QuickrDataTests/MultiProcess).
                "ProcessHelper",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
