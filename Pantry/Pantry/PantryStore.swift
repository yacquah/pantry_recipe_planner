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

    /// Everything on hand with quantities, and the two cuts of it the pantry
    /// screen shows. Kept as three stored properties rather than computed on
    /// demand because each is a database read, and a SwiftUI body can run many
    /// times per frame.
    private(set) var stock: [InventoryItem] = []
    private(set) var runningLow: [InventoryItem] = []
    private(set) var needsAttention: [InventoryItem] = []

    /// What can be cooked tonight, four-state verdicts intact.
    private(set) var recipes: [RecipeMatch] = []
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

    /// Where this store's database lives, or nil to use the real one.
    ///
    /// Injectable for one reason: without it every test runs against the
    /// user's actual pantry in Application Support. A test that can only be
    /// written by first destroying real data does not get written.
    private let location: URL?

    /// Whether to talk to iOS's notification centre at all.
    ///
    /// Off in tests. Scheduling asks for permission the first time there is
    /// something to schedule, and a test that trips a system permission alert
    /// is a test that hangs on CI — while a store whose data cannot be
    /// exercised without one is a store nobody writes tests for.
    private let schedulesNotifications: Bool

    init(databaseURL: URL? = nil, schedulesNotifications: Bool = true) {
        self.location = databaseURL
        self.schedulesNotifications = schedulesNotifications
    }

    /// Application Support, not Documents.
    ///
    /// Documents is user-visible in the Files app and meant for things a
    /// person creates and manages. A database is internal state they should
    /// never have to see, let alone be able to delete by hand.
    static func defaultDatabaseURL() throws -> URL {
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
            let url = try location ?? Self.defaultDatabaseURL()
            let database = try Database(path: url.path)
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

        let inventory = Inventory(db: database)
        stock = try inventory.all()
        runningLow = try inventory.runningLow(limit: 3)
        needsAttention = try inventory.needingAttention()
        recipes = try Matcher(db: database).cookTonight()
        errorMessage = nil
        hasLoaded = true

        // Re-synced after every read, because every read follows a change.
        // The plan is the whole intended state, so this both schedules new
        // alerts and retires ones whose lot has been cooked or thrown out.
        if schedulesNotifications {
            Task { await syncNotifications() }
        }
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

    /// Records one hand-entered item.
    ///
    /// The raw text lands in `raw_capture` unedited and the normalised rows are
    /// derived from it, so a bad guess here is always recoverable — the thing
    /// the user actually typed is never overwritten (ADR 008).
    func capture(_ request: CaptureRequest) {
        do {
            guard let database else { return }
            _ = try Capture(db: database).record(request)
            try reload()
        } catch {
            errorMessage = String(describing: error)
        }
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
