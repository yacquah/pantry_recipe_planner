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
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PantryCore",
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
