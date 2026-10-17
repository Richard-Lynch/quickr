// swift-tools-version: 6.2
// quickR's shared code. Core and Data also build for macOS so `swift test` runs on the
// host; UI is iOS-only (its sources are guarded with `#if os(iOS)`). See docs/ios/PLAN.md §2.
import PackageDescription

let package = Package(
    name: "QuickrKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "QuickrCore", targets: ["QuickrCore"]),
        .library(name: "QuickrData", targets: ["QuickrData"]),
        .library(name: "QuickrUI", targets: ["QuickrUI"]),
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
        .testTarget(name: "QuickrCoreTests", dependencies: ["QuickrCore"]),
        .testTarget(name: "QuickrDataTests", dependencies: ["QuickrData"]),
    ],
    swiftLanguageModes: [.v6]
)
