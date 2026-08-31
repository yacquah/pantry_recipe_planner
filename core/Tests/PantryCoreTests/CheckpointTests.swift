import Testing
import Foundation
import PantryCore

/// ADR 005's checkpoint rule, which was documented for weeks before it was
/// implemented: a recount observes reality, and reality already contains
/// everything that happened before it — whether or not the app had heard.
@Suite("Checkpoint balance — ADR 005")
struct CheckpointTests {

    /// One lot with a ledger, and the two readings the view derives from it.
    private struct Fixture {
        let db: Database
        let lotId: Int64
        let productId: Int64

        init(_ db: Database) throws {
            self.db = db
            try db.migrate()
            productId = try db.run(
                "INSERT INTO product (canonical_name, base_unit) VALUES ('Test rice','g')")
            lotId = try db.run(
                "INSERT INTO lot (product_id, acquired_on) VALUES (?, '2026-01-01')",
                [.int(productId)])
        }

        func event(_ delta: Double?, _ reason: String, _ at: String, observed: Double? = nil) throws {
            try db.run("""
                INSERT INTO pantry_event
                    (id, lot_id, product_id, delta_base_unit, reason,
                     qty_precision, observed_qty, occurred_at, device_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'check')
                """,
                [.text(UUIDv7.generate()), .int(lotId), .int(productId),
                 delta.map { SQLValue.double($0) } ?? .null, .text(reason),
                 delta == nil ? .null : .text("derived"),
                 observed.map { SQLValue.double($0) } ?? .null, .text(at)])
        }

        /// The balance, and how many events the checkpoint superseded.
        func balance() throws -> (Double?, Int) {
            let row = try db.query(
                "SELECT balance, superseded_events FROM v_lot_balance WHERE lot_id = ?",
                [.int(lotId)]).first
            return (row?.double("balance"), Int(row?.int("superseded_events") ?? 0))
        }
    }

    @Test("with no recount, the balance is the whole ledger")
    func plainLedger() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            try f.event(1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(-200, "COOK",    "2026-01-05T10:00:00")
            #expect(try f.balance().0 == 800)
        }
    }

    /// Note that 500 is NOT 800 minus anything — the point is that the ledger
    /// had drifted and the eyes win.
    @Test("a recount replaces the balance outright and supersedes what came before")
    func recountIsACheckpoint() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            try f.event(1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(-200, "COOK",    "2026-01-05T10:00:00")
            try f.event(-300, "ADJUSTMENT", "2026-01-10T10:00:00", observed: 500)

            let after = try f.balance()
            #expect(after.0 == 500)
            #expect(after.1 == 2, "supersedes the two events before it, not itself")
        }
    }

    @Test("later events are counted from the checkpoint")
    func laterEventsCount() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            try f.event(1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(-200, "COOK",    "2026-01-05T10:00:00")
            try f.event(-300, "ADJUSTMENT", "2026-01-10T10:00:00", observed: 500)
            try f.event(-100, "COOK",    "2026-01-12T10:00:00")
            #expect(try f.balance().0 == 400)
        }
    }

    /// A late-arriving event from BEFORE the checkpoint must not move the
    /// balance — the recount already accounted for it (ADR 005, offline sync).
    @Test("an event older than the checkpoint is retained, not counted")
    func lateArrivalIsSuperseded() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            try f.event(1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(-200, "COOK",    "2026-01-05T10:00:00")
            try f.event(-300, "ADJUSTMENT", "2026-01-10T10:00:00", observed: 500)
            try f.event(-100, "COOK",    "2026-01-12T10:00:00")

            try f.event(-999, "CONSUME", "2026-01-06T10:00:00")
            let after = try f.balance()
            #expect(after.0 == 400)
            #expect(after.1 == 3, "reported as superseded rather than dropped silently")
        }
    }
}
