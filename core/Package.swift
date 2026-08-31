// swift-tools-version: 6.0
//
// Two targets on purpose:
//
//   PantryCore  — all the logic, no printing, no argument parsing
//   pantry      — a thin command-line shell over it
//
// The split matters later. When the iOS app arrives (ADR 008), it imports
// PantryCore unchanged and supplies a different interface. If the logic lived
// in the executable it would all have to be rewritten.

import PackageDescription

let package = Package(
    name: "pantry",
    // iOS is declared because the app imports PantryCore (ADR 008). Without
    // it, SPM treats this as a macOS-only package and an iOS target cannot
    // depend on it. The floor is deliberately low: the library uses only
    // Foundation and SQLite3, so nothing here needs a recent OS — the app
    // target sets its own, higher, minimum for SwiftUI.
    platforms: [.macOS(.v13), .iOS(.v17)],
    // Targets are internal to a package; only PRODUCTS are visible to anything
    // outside it. Without this the iOS app cannot see PantryCore at all — the
    // package resolves, and offers nothing to link against.
    products: [
        .library(name: "PantryCore", targets: ["PantryCore"]),
    ],
    targets: [
        .target(
            name: "PantryCore",
            // The migrations ship INSIDE the library rather than beside it. An
            // app on a phone has to carry the instructions for upgrading its
            // own database; a .sql file sitting in the repo is no use to it.
            resources: [
                .copy("Migrations"),
                // The hand-collected 11-item inventory, so the app can import
                // it on a device where the repository does not exist.
                .copy("StarterData"),
            ],
            // SQLite ships with macOS, so this is the only dependency and it
            // is already on the machine. No package resolution, no network.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "pantry",
            dependencies: ["PantryCore"]
        ),
        // These checks began life as a hand-rolled runner in an executable
        // target, because on macOS both XCTest and Swift Testing ship inside
        // Xcode rather than Command Line Tools, and Xcode was not installed.
        // That constraint is gone. The trade being made by depending on Swift
        // Testing is that `swift test` now needs Xcode present on a Mac, where
        // the old runner needed only the toolchain — worth it for a suite that
        // can no longer mistake "did not run" for "passed".
        .testTarget(
            name: "PantryCoreTests",
            dependencies: ["PantryCore"]
        ),
    ]
)
