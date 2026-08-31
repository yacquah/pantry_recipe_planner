import Foundation
import PantryCore

/// A throwaway database on a path nobody else will use, deleted afterwards.
///
/// Tests run in parallel under Swift Testing, so a fixed filename would have
/// two suites writing to one file and failing in ways that depend on timing.
/// The UUID is not decoration.
func withTemporaryDatabase<T>(_ body: (Database) throws -> T) throws -> T {
    let path = NSTemporaryDirectory() + "pantry-test-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try body(try Database(path: path))
}
