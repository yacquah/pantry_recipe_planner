import Foundation

/// The hand-collected starting inventory — eleven real items, captured from a
/// notebook on 2026-08-02.
///
/// Not test fixtures and not invented sample data: it is the actual pantry the
/// whole schema was designed against, including the rows that make it awkward
/// (a Lipton box nobody can identify, a bag of basmati whose size was never
/// recorded). Loading it gives a new database something true to show.
///
/// Bundled with the library for the same reason the migrations are: an app in
/// a sandbox cannot read the repository it was built from.
public enum StarterData {

    public enum Failure: Error, CustomStringConvertible {
        case notBundled
        case alreadyPopulated(products: Int)

        public var description: String {
            switch self {
            case .notBundled:
                return "starter inventory is missing from the package bundle"
            case .alreadyPopulated(let count):
                return "database already holds \(count) product(s) — refusing to import on top"
            }
        }
    }

    /// Imports the starter inventory into an empty database.
    ///
    /// Refuses if anything is already there. Importing on top would duplicate
    /// products and, worse, append a second set of CAPTURE events — silently
    /// doubling quantities in a ledger where the sums are the truth.
    public static func load(into db: Database, force: Bool = false) throws {
        if !force {
            let existing = try db.query("SELECT COUNT(*) AS n FROM product")
                .first?.int("n") ?? 0
            if existing > 0 {
                throw Failure.alreadyPopulated(products: Int(existing))
            }
        }

        guard let url = Bundle.module.url(
            forResource: "starter_pantry", withExtension: "sql", subdirectory: "StarterData"
        ) else {
            throw Failure.notBundled
        }

        // One transaction: eleven products, their lots, the opening ledger
        // entries, the raw captures and the recipes either all arrive or none
        // do. A half-imported pantry would be worse than an empty one.
        let sql = try String(contentsOf: url, encoding: .utf8)
        try db.transaction {
            try db.executeScript(sql)
        }
    }
}
