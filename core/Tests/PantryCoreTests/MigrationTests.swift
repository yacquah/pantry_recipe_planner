import Testing
import Foundation
import PantryCore

/// The only checks that touch a database. Everything in the matcher and alert
/// suites is a pure function; migrations are not, because the whole point is
/// what they do to a file that already exists.
@Suite("Migrations — schema versioning")
struct MigrationTests {

    @Test("versions run 1...n with no gaps and no duplicates")
    func versionsAreContiguous() throws {
        let latest = try Migrations.latestVersion()
        #expect(latest >= 1, "at least one migration ships with the app")

        // A gap would mean a migration was written and never committed.
        #expect(try Migrations.all().map(\.version) == Array(1...latest))
    }

    @Test("a fresh database applies every migration and ends at the latest")
    func freshDatabase() throws {
        let latest = try Migrations.latestVersion()
        try withTemporaryDatabase { db in
            #expect(try db.schemaVersion == 0, "a brand new database reads version 0")

            let applied = try db.migrate()
            #expect(applied.count == latest)
            #expect(try db.schemaVersion == latest)

            // Prove the schema is real, not just the version number.
            #expect(try db.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='pantry_event'"
            ).count == 1, "the ledger table exists afterwards")
        }
    }

    /// The property the whole mechanism rests on. Without it, every app launch
    /// would re-run every migration.
    @Test("migrating an up-to-date database is a no-op")
    func reMigratingDoesNothing() throws {
        let latest = try Migrations.latestVersion()
        try withTemporaryDatabase { db in
            try db.migrate()
            #expect(try db.migrate().count == 0)
            #expect(try db.schemaVersion == latest, "and leaves the version untouched")
        }
    }

    /// The bug that made executeScript necessary, pinned so it cannot come
    /// back. run() goes through sqlite3_prepare_v2, which compiles only the
    /// FIRST statement and silently discards the rest — a migration run through
    /// it would create one table and report success.
    @Test("run() stops after one statement; executeScript() does not")
    func multiStatementHandling() throws {
        try withTemporaryDatabase { db in
            try db.migrate()

            func tableExists(_ name: String) throws -> Int {
                Int(try db.query(
                    "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name = ?",
                    [.text(name)]
                ).first?.int("n") ?? 0)
            }

            try db.run("CREATE TABLE probe_a(x); CREATE TABLE probe_b(x);")
            #expect(try tableExists("probe_a") == 1, "run() executes the first statement")
            #expect(try tableExists("probe_b") == 0,
                    "run() silently ignores the rest — the exact bug executeScript fixes")

            try db.executeScript("CREATE TABLE probe_c(x); CREATE TABLE probe_d(x);")
            #expect(try tableExists("probe_c") + tableExists("probe_d") == 2,
                    "executeScript runs every statement in the script")
        }
    }

    /// A database written by a NEWER build must be refused rather than guessed
    /// at — this build cannot know what that version changed.
    @Test("a database newer than the app is refused, not opened")
    func refusesFutureSchema() throws {
        try withTemporaryDatabase { db in
            try db.migrate()
            try db.executeScript("PRAGMA user_version = 9999")
            #expect(throws: (any Error).self) {
                _ = try db.migrate()
            }
        }
    }
}
