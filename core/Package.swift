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
        // Checks live in an ordinary executable rather than a .testTarget.
        // On macOS both XCTest and Swift Testing ship inside Xcode, not in
        // Command Line Tools, so a real test target cannot compile here.
        // Installing a 30 GB IDE to obtain an assert function is a poor trade;
        // this runs the same checks and exits non-zero on failure. Converting
        // it to XCTest once Xcode is installed is mechanical.
        .executableTarget(
            name: "pantry-tests",
            dependencies: ["PantryCore"]
        ),
    ]
)
