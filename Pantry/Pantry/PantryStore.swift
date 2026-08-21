import Foundation
import Observation
import PantryCore

/// Owns the app's database and everything read out of it.
///
/// Deliberately thin. Every rule — the expiry chain, what counts as unknown,
/// what may be said confidently — already lives in PantryCore and is checked
/// there. This exists to open a file, keep results around for SwiftUI, and
/// turn thrown errors into something displayable.
@MainActor
@Observable
final class PantryStore {

    private(set) var items: [ExpiryItem] = []
    private(set) var expiringSoon: ExpiryReport?
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    private var database: Database?

    var isEmpty: Bool { hasLoaded && items.isEmpty }

    /// Application Support, not Documents.
    ///
    /// Documents is user-visible in the Files app and meant for things a
    /// person creates and manages. A database is internal state they should
    /// never have to see, let alone be able to delete by hand.
    static func databaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true                     // does not exist on a fresh install
        )
        return directory.appendingPathComponent("pantry.db")
    }

    /// Opens the database and brings its schema up to date.
    ///
    /// Migrating on every launch is safe precisely because re-running is a
    /// no-op (ADR 009) — so the app never has to decide whether it should.
    func start() {
        do {
            let database = try Database(path: try Self.databaseURL().path)
            try database.migrate()
            self.database = database
            try reload()
        } catch {
            errorMessage = String(describing: error)
            hasLoaded = true
        }
    }

    func reload() throws {
        guard let database else { return }
        let expiry = Expiry(db: database)
        items = try expiry.all()
        expiringSoon = try expiry.upcoming(withinDays: 3)
        errorMessage = nil
        hasLoaded = true
    }

    /// Imports the hand-collected eleven-item pantry. Refuses if anything is
    /// already there, so it cannot double the ledger.
    func importStarterInventory() {
        do {
            guard let database else { return }
            try StarterData.load(into: database)
            try reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
