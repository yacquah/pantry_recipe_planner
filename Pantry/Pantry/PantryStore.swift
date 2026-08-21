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
    /// What iOS should have pending. Kept here so the screen can say what the
    /// app will actually do, rather than implying it from a bell icon.
    private(set) var alerts: [ExpiryAlert] = []

    /// What iOS confirms it is actually holding, which is not the same claim.
    /// Scheduling can be refused — permission withheld, the 64-request limit,
    /// a trigger already in the past — and a screen that reports the plan
    /// instead of the fact would promise reminders nobody is going to get.
    private(set) var scheduledCount = 0
    private(set) var notificationsRefused = false
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
        alerts = ExpiryAlerts.plan(for: items)
        errorMessage = nil
        hasLoaded = true

        // Re-synced after every read, because every read follows a change.
        // The plan is the whole intended state, so this both schedules new
        // alerts and retires ones whose lot has been cooked or thrown out.
        Task { await syncNotifications() }
    }

    /// Brings iOS's pending notifications in line with the plan, asking for
    /// permission first if there is now something worth asking about.
    ///
    /// The prompt is deliberately deferred to here rather than fired at
    /// launch: iOS only ever asks once, and a refusal collected before the app
    /// has shown what it is for is a refusal that cannot be revisited.
    private func syncNotifications() async {
        guard !alerts.isEmpty else {
            await ExpiryNotifications.sync([])
            scheduledCount = 0
            return
        }

        switch await ExpiryNotifications.permission() {
        case .notAskedYet:
            guard await ExpiryNotifications.requestPermission() else {
                notificationsRefused = true
                scheduledCount = 0
                return
            }
        case .denied:
            notificationsRefused = true
            scheduledCount = 0
            return
        case .granted:
            break
        }

        notificationsRefused = false
        await ExpiryNotifications.sync(alerts)

        // Read back rather than assume. This is the only number the screen is
        // entitled to call "scheduled".
        scheduledCount = await ExpiryNotifications.pending().count
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
