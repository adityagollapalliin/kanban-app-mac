// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalBoard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalBoardCore", targets: ["LocalBoardCore"]),
        .library(name: "LocalBoardStore", targets: ["LocalBoardStore"]),
        .library(name: "LocalBoardUI", targets: ["LocalBoardUI"]),
        .executable(name: "localboard", targets: ["localboard"]),
        .executable(name: "LocalBoardApp", targets: ["LocalBoardApp"]),
    ],
    targets: [
        // Pure domain logic. No AppKit, no SwiftUI, no file I/O of its own.
        .target(name: "LocalBoardCore"),

        // SQLite persistence: connection, migrations, repositories, change feed.
        .target(name: "LocalBoardStore", dependencies: ["LocalBoardCore"]),

        // SwiftUI views and @Observable view models.
        .target(name: "LocalBoardUI", dependencies: ["LocalBoardCore", "LocalBoardStore"]),

        // The app entry point. Shared verbatim with the Xcode app target, which
        // compiles this same file; the bundle, Info.plist and entitlements live
        // in the Xcode project (or are assembled by Scripts/bundle-spm.sh).
        .executableTarget(
            name: "LocalBoardApp",
            dependencies: ["LocalBoardUI"],
            path: "App",
            exclude: ["Info.plist", "LocalBoard.entitlements", "Assets.xcassets"],
            sources: ["main.swift"]
        ),

        // The `localboard` CLI shim. Talks to the same SQLite file directly.
        .executableTarget(name: "localboard", dependencies: ["LocalBoardCore", "LocalBoardStore"]),

        .testTarget(name: "LocalBoardCoreTests", dependencies: ["LocalBoardCore"]),
        .testTarget(name: "LocalBoardStoreTests", dependencies: ["LocalBoardStore", "LocalBoardCore"]),
    ]
)
