import Foundation

/// One numbered, immutable step in the database's history.
///
/// Migrations are the ledger idea applied to the schema itself: you never
/// overwrite the shape of the database, you append a change, and the current
/// shape is whatever replaying them in order produces. Same reasoning as
/// ADR 003 — the history is the truth, the current state is derived.
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String
}

public enum Migrations {

    public enum Failure: Error, CustomStringConvertible {
        case bundleMissing
        case unnumbered(String)
        case duplicate(Int)
        case databaseIsNewerThanApp(database: Int, app: Int)

        public var description: String {
            switch self {
            case .bundleMissing:
                return "no migrations found in the package bundle"
            case .unnumbered(let file):
                return "migration '\(file)' does not start with a version number"
            case .duplicate(let version):
                return "two migrations claim version \(version)"
            case .databaseIsNewerThanApp(let database, let app):
                return """
                    this database is at schema version \(database) but this build \
                    only knows about \(app). It was written by a newer version of \
                    the app; opening it now risks corrupting data.
                    """
            }
        }
    }

    /// Every migration the app carries, in ascending order.
    ///
    /// Loaded from the package's resource bundle rather than from disk, so the
    /// same code path works in a command-line tool and inside an app sandbox
    /// on a phone, where the repository does not exist.
    public static func all() throws -> [Migration] {
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "sql", subdirectory: "Migrations"
        ), !urls.isEmpty else {
            throw Failure.bundleMissing
        }

        var migrations: [Migration] = []
        var seen: Set<Int> = []

        for url in urls {
            let file = url.deletingPathExtension().lastPathComponent  // 001_initial_schema
            let digits = file.prefix { $0.isNumber }
            guard let version = Int(digits), version > 0 else {
                throw Failure.unnumbered(file)
            }
            guard seen.insert(version).inserted else {
                throw Failure.duplicate(version)
            }
            migrations.append(
                Migration(
                    version: version,
                    name: String(file.dropFirst(digits.count)).drop(while: { $0 == "_" }).description,
                    sql: try String(contentsOf: url, encoding: .utf8)
                )
            )
        }

        return migrations.sorted { $0.version < $1.version }
    }

    /// The version a fully migrated database ends up at.
    public static func latestVersion() throws -> Int {
        try all().last?.version ?? 0
    }
}

extension Database {

    /// SQLite keeps a spare integer in every database file for exactly this.
    /// A brand new file reads 0, which is why migrations are numbered from 1.
    public var schemaVersion: Int {
        get throws {
            let rows = try query("PRAGMA user_version")
            return Int(rows.first?.int("user_version") ?? 0)
        }
    }

    /// Brings the database up to date and returns whatever it actually ran.
    ///
    /// Applies only migrations newer than the version already recorded, so a
    /// fresh install runs all of them, a partially upgraded one runs the
    /// remainder, and an up-to-date one runs nothing and returns [].
    @discardableResult
    public func migrate() throws -> [Migration] {
        let available = try Migrations.all()
        let latest = available.last?.version ?? 0
        let current = try schemaVersion

        // A database written by a newer build of the app. Refusing loudly is
        // the only safe move: this build cannot know what that version changed,
        // and guessing means corrupting data the user cannot get back.
        guard current <= latest else {
            throw Migrations.Failure.databaseIsNewerThanApp(database: current, app: latest)
        }

        var applied: [Migration] = []
        for migration in available where migration.version > current {
            // The schema change and the version bump go in ONE transaction. If
            // a migration fails halfway, both roll back together — otherwise
            // the database could end up half-changed while claiming to be a
            // version it is not, which is unrecoverable without a backup.
            try transaction {
                try executeScript(migration.sql)
                // PRAGMA takes no bound parameters, so this is interpolated.
                // Safe: the value is an Int read from our own filenames.
                try executeScript("PRAGMA user_version = \(migration.version)")
            }
            applied.append(migration)
        }
        return applied
    }
}
