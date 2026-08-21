import Foundation
import PantryCore

// A dependency-free check runner.
//
// Neither XCTest nor Swift Testing is available on this machine: on macOS both
// ship inside Xcode rather than Command Line Tools. Rather than install a 30 GB
// IDE to obtain an assert function, this does the same job in about thirty
// lines — runs the checks, prints failures, exits non-zero so a shell or CI can
// tell. Converting to XCTest once Xcode is installed is mechanical: the
// assertions below map one-to-one onto XCTAssertEqual.
//
// Everything checked here is a pure function, so there is no database, no
// fixture and no setup. That is exactly why the verdict rules live in Swift
// rather than in SQL.

// In Swift 6, top-level code runs on the main actor, so these two variables
// are main-actor isolated. Functions declared beside them are NOT isolated by
// default, so each helper has to say it belongs there too — otherwise the
// compiler correctly refuses to let a nonisolated function touch them.
var checksRun = 0
var failures: [String] = []

@MainActor
func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checksRun += 1
    if actual != expected {
        failures.append("\(label)\n        expected: \(expected)\n        actual:   \(actual)")
    }
}

@MainActor
func expectTrue(_ condition: Bool, _ label: String) {
    checksRun += 1
    if !condition { failures.append(label) }
}

@MainActor
func suite(_ name: String, _ body: @MainActor () -> Void) {
    print("\n\(name)")
    let before = failures.count
    body()
    print(failures.count == before ? "  ok" : "  \(failures.count - before) failed")
}

// ---------------------------------------------------------------------------

suite("Ingredient verdicts — ADR 004") {

    // Same unit on both sides: an exact comparison, no bridge involved.
    expect(Matcher.judge(need: 400, needUnit: "g", baseUnit: "g",
                         have: 5275, unknownEvents: 0,
                         gramsEach: nil, bridge: nil).0,
           .have, "same unit, enough")

    expect(Matcher.judge(need: 6000, needUnit: "g", baseUnit: "g",
                         have: 5275, unknownEvents: 0,
                         gramsEach: nil, bridge: nil).0,
           .short, "same unit, short")

    // Basmati rice: the bag size was never recorded. Answering "no" here would
    // be a confident claim derived from an absence of data.
    let unknownQuantity = Matcher.judge(need: 250, needUnit: "g", baseUnit: "g",
                                        have: nil, unknownEvents: 1,
                                        gramsEach: nil, bridge: nil)
    expect(unknownQuantity.0, .cannotTell, "unknown quantity is not zero")
    expect(unknownQuantity.1, "quantity unknown", "and it says why")

    // One unknown event poisons an otherwise known total, rather than being
    // quietly dropped from the sum (modelling rule 4).
    expect(Matcher.judge(need: 100, needUnit: "g", baseUnit: "g",
                         have: 500, unknownEvents: 1,
                         gramsEach: nil, bridge: nil).0,
           .cannotTell, "partial unknown is still unknown")

    // The Lipton box: identity known, unit unknown (ADR 002).
    expect(Matcher.judge(need: 1, needUnit: "count", baseUnit: nil,
                         have: nil, unknownEvents: 1,
                         gramsEach: nil, bridge: nil).0,
           .cannotTell, "no base unit means no comparison")

    // No bridge at all.
    let noBridge = Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                                 have: 10, unknownEvents: 0,
                                 gramsEach: nil, bridge: nil)
    expect(noBridge.0, .cannotTell, "missing bridge gives no answer")
    expectTrue(noBridge.1?.contains("no piece weight") == true,
               "and names the missing piece weight")

    // 10 wings weighed at 992 g. The per-piece average is approximate, but the
    // total it rebuilds is exactly what went on the scale.
    expect(Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                         have: 10, unknownEvents: 0,
                         gramsEach: 99.2, bridge: .measured).0,
           .have, "measured total supports a confident answer")

    // Every Indomie pack really is 85 g; no spread to hedge over.
    expect(Matcher.judge(need: 300, needUnit: "g", baseUnit: "count",
                         have: 10, unknownEvents: 0,
                         gramsEach: 85, bridge: .printed).0,
           .have, "printed weight supports a confident answer")

    // A reference average is approximate in BOTH directions. The second case
    // matters most: a firm "no" from an approximate bridge is the failure that
    // quietly kills the feature, because you cook something else and the food
    // rots anyway.
    expect(Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                         have: 4, unknownEvents: 0,
                         gramsEach: 150, bridge: .reference).0,
           .probably, "reference average hedges when sufficient")

    expect(Matcher.judge(need: 900, needUnit: "g", baseUnit: "count",
                         have: 4, unknownEvents: 0,
                         gramsEach: 150, bridge: .reference).0,
           .probablyShort, "reference average hedges when short, never says no")

    // Knowing ten wings weigh 992 g says nothing certain about any single
    // wing, so "2 wings" gets a hedge even though the same data answered a
    // grams question confidently above.
    expect(Matcher.judge(need: 2, needUnit: "count", baseUnit: "g",
                         have: 992, unknownEvents: 0,
                         gramsEach: 99.2, bridge: .measured).0,
           .probably, "dividing down stays approximate even when measured")
}

suite("Recipe verdicts") {
    expect(Matcher.combine([.have, .have]), .yes, "all confirmed")
    expect(Matcher.combine([.have, .short, .cannotTell]), .no, "exact shortfall outranks all")
    expect(Matcher.combine([.have, .probably, .cannotTell]), .cannotTell, "unknown outranks a hedge")
    expect(Matcher.combine([.have, .probablyShort]), .probably, "probable shortfall is only 'check'")
}

suite("UUIDv7 — ADR 005") {
    let parts = UUIDv7.generate().split(separator: "-").map(\.count)
    expect(parts, [8, 4, 4, 4, 12], "canonical 8-4-4-4-12 shape")

    let hex = Array(UUIDv7.generate().replacingOccurrences(of: "-", with: ""))
    expect(hex[12], "7", "version nibble is 7")
    expectTrue("89ab".contains(hex[16]), "variant bits are 10xx")

    // The reason for version 7 over version 4: ids in an append-only log sort
    // into the order they were written.
    let earlier = UUIDv7.generate(at: .init(timeIntervalSince1970: 1_700_000_000))
    let later   = UUIDv7.generate(at: .init(timeIntervalSince1970: 1_800_000_000))
    expectTrue(earlier < later, "ids sort by creation time")
}

// These are the only checks that touch a database. Everything above is a pure
// function; migrations are not, because the whole point is what they do to a
// file that already exists. Each run uses a throwaway path and deletes it.
suite("Migrations — schema versioning") {
    let path = NSTemporaryDirectory() + "pantry-check-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        let latest = try Migrations.latestVersion()
        expectTrue(latest >= 1, "at least one migration ships with the app")

        if latest >= 1 {
            // Numbered from 1, ascending, no duplicates and no gaps. A gap
            // would mean a migration was written and never committed.
            expect(try Migrations.all().map(\.version), Array(1...latest),
                   "versions run 1...\(latest) with no gaps or duplicates")
        }

        let db = try Database(path: path)
        expect(try db.schemaVersion, 0, "a brand new database reads version 0")

        let applied = try db.migrate()
        expect(applied.count, latest, "a fresh database applies every migration")
        expect(try db.schemaVersion, latest, "and ends at the latest version")

        // The property the whole mechanism rests on: running it again does
        // nothing. Without this, every app launch would re-run every migration.
        expect(try db.migrate().count, 0, "migrating an up-to-date database is a no-op")
        expect(try db.schemaVersion, latest, "and leaves the version untouched")

        // Prove the schema is real, not just the version number.
        expect(try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='pantry_event'"
        ).count, 1, "the ledger table exists afterwards")

        // The bug that made executeScript necessary, pinned so it cannot come
        // back. run() goes through sqlite3_prepare_v2, which compiles only the
        // FIRST statement and silently discards the rest — a migration run
        // through it would create one table and report success.
        func tableExists(_ name: String) throws -> Int {
            Int(try db.query(
                "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name = ?",
                [.text(name)]
            ).first?.int("n") ?? 0)
        }

        try db.run("CREATE TABLE probe_a(x); CREATE TABLE probe_b(x);")
        expect(try tableExists("probe_a"), 1, "run() executes the first statement")
        expect(try tableExists("probe_b"), 0,
               "run() silently ignores the rest — the exact bug executeScript fixes")

        try db.executeScript("CREATE TABLE probe_c(x); CREATE TABLE probe_d(x);")
        expect(try tableExists("probe_c") + tableExists("probe_d"), 2,
               "executeScript runs every statement in the script")

        // A database written by a NEWER build must be refused rather than
        // guessed at — this build cannot know what that version changed.
        try db.executeScript("PRAGMA user_version = 9999")
        var refused = false
        do { _ = try db.migrate() } catch { refused = true }
        expectTrue(refused, "a database newer than the app is refused, not opened")

    } catch {
        checksRun += 1
        failures.append("Migrations suite threw unexpectedly: \(error)")
    }
}

// ---------------------------------------------------------------------------

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("\(checksRun) checks passed")
    exit(0)
} else {
    print("\(checksRun) checks, \(failures.count) FAILED\n")
    for failure in failures { print("  • \(failure)") }
    exit(1)
}
