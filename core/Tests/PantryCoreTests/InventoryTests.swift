import Testing
import Foundation
import PantryCore

@Suite("Inventory — what is in the kitchen, and how much")
struct InventoryTests {

    /// A lot with a known opening capture and whatever else the test needs.
    private struct Fixture {
        let db: Database
        let productId: Int64

        init(_ db: Database, baseUnit: String? = "g", shelfLifeClass: String = "ambient_stable") throws {
            self.db = db
            try db.migrate()
            productId = try db.run("""
                INSERT INTO product (canonical_name, base_unit, shelf_life_class)
                VALUES ('Test rice', ?, ?)
                """,
                [baseUnit.map { SQLValue.text($0) } ?? .null, .text(shelfLifeClass)])
        }

        /// `shelf_life_state` is a generated column, so 'sealed' is produced by
        /// setting both flags to 0 rather than written directly. A dated lot
        /// also has to carry the kind of date and its precision — the schema
        /// refuses a bare date, because "expires 2026-06-01" without saying
        /// use-by or best-before is exactly the ambiguity ADR 001 forbids.
        @discardableResult
        func lot(expires: String? = nil) throws -> Int64 {
            try db.run("""
                INSERT INTO lot
                    (product_id, acquired_on, is_frozen, is_opened,
                     expires_on, expiry_kind, expires_on_precision)
                VALUES (?, '2026-01-01', 0, 0, ?, ?, ?)
                """,
                [.int(productId),
                 expires.map { SQLValue.text($0) } ?? .null,
                 expires == nil ? .null : .text("best_before"),
                 expires == nil ? .null : .text("day")])
        }

        func event(_ lotId: Int64, _ delta: Double?, _ reason: String,
                   _ at: String, observed: Double? = nil) throws {
            try db.run("""
                INSERT INTO pantry_event
                    (id, lot_id, product_id, delta_base_unit, reason,
                     qty_precision, observed_qty, occurred_at, device_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'test')
                """,
                [.text(UUIDv7.generate()), .int(lotId), .int(productId),
                 delta.map { SQLValue.double($0) } ?? .null, .text(reason),
                 delta == nil ? .null : .text("derived"),
                 observed.map { SQLValue.double($0) } ?? .null, .text(at)])
        }
    }

    @Test("reports what is left against what was captured")
    func remainingFraction() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            let lot = try f.lot()
            try f.event(lot, 1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(lot, -250, "COOK",    "2026-01-05T10:00:00")

            let item = try #require(try Inventory(db: db).all().first)
            #expect(item.balance == 750)
            #expect(item.capturedTotal == 1000)
            #expect(item.remainingFraction == 0.75)
            #expect(item.needsAttention == false)
        }
    }

    /// A recount can legitimately observe more than was captured — the second
    /// bag at the back of the cupboard. Clamping to 1.0 would hide a real
    /// discrepancy the ledger deliberately preserves.
    @Test("a fraction above 1 is reported, not clamped away")
    func moreThanCaptured() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            let lot = try f.lot()
            try f.event(lot, 1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(lot, nil, "ADJUSTMENT", "2026-01-06T10:00:00", observed: 1500)

            let item = try #require(try Inventory(db: db).all().first)
            #expect(item.balance == 1500)
            #expect(item.remainingFraction == 1.5)
        }
    }

    /// Basmati rice, live: a real bag whose size nobody wrote down.
    @Test("an unknown quantity is unknown, not zero, and asks to be resolved")
    func unknownQuantity() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            let lot = try f.lot()
            try f.event(lot, nil, "CAPTURE", "2026-01-01T10:00:00")

            let item = try #require(try Inventory(db: db).all().first)
            #expect(item.balance == nil, "never a zero")
            #expect(item.remainingFraction == nil, "and no fraction can be built from it")
            #expect(item.needsAttention)
            #expect(item.attentionReason == "quantity never recorded")
        }
    }

    /// Rule 4: a balance built partly from events with no amount is a floor,
    /// not a total, and has to say so.
    @Test("a partially unknown balance reports its own exclusions")
    func partialUnknown() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            let lot = try f.lot()
            try f.event(lot, 1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(lot, nil,  "CONSUME", "2026-01-05T10:00:00")

            let item = try #require(try Inventory(db: db).all().first)
            #expect(item.unknownEvents == 1)
            #expect(item.needsAttention)
            #expect(item.attentionReason == "1 change(s) with no amount")
        }
    }

    @Test("the Lipton box case — identity known, unit not")
    func noBaseUnit() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db, baseUnit: nil)
            let lot = try f.lot()
            try f.event(lot, nil, "CAPTURE", "2026-01-01T10:00:00")

            let item = try #require(try Inventory(db: db).all().first)
            #expect(item.baseUnit == nil)
            #expect(item.attentionReason == "no unit recorded",
                    "the missing unit outranks the missing quantity — it is the reason for it")
        }
    }

    /// A known deadline outranks an unknown one, the same ordering FEFO uses.
    @Test("soonest expiry first, undated last")
    func ordering() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db, shelfLifeClass: "stable_until_opened")
            let undated = try f.lot()
            let late    = try f.lot(expires: "2027-01-01")
            let soon    = try f.lot(expires: "2026-06-01")
            for lot in [undated, late, soon] {
                try f.event(lot, 100, "CAPTURE", "2026-01-01T10:00:00")
            }

            let dates = try Inventory(db: db).all().map(\.effectiveDate)
            #expect(dates.prefix(2) == ["2026-06-01", "2027-01-01"])

            // `dates.last` is a double optional — .some(nil) for a lot with no
            // date — so it must be unwrapped one level before being compared,
            // or the check passes on the wrong thing.
            let last = try #require(dates.last, "a third lot should exist")
            #expect(last == nil, "an undated lot sorts last, not first")
        }
    }

    /// A lot with an unknown quantity is not "full". Putting it anywhere on a
    /// scale of fullness would state something nobody knows.
    @Test("running low excludes what it cannot measure, rather than guessing")
    func runningLowExcludesUnknowns() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            let full = try f.lot()
            try f.event(full, 1000, "CAPTURE", "2026-01-01T10:00:00")

            let nearlyGone = try f.lot()
            try f.event(nearlyGone, 1000, "CAPTURE", "2026-01-01T10:00:00")
            try f.event(nearlyGone, -900, "COOK",    "2026-01-05T10:00:00")

            let unmeasurable = try f.lot()
            try f.event(unmeasurable, nil, "CAPTURE", "2026-01-01T10:00:00")

            let low = try Inventory(db: db).runningLow()
            #expect(low.map(\.lotId) == [nearlyGone, full])
            #expect(low.contains { $0.lotId == unmeasurable } == false)

            // It is not lost, only reported somewhere it can be acted on.
            #expect(try Inventory(db: db).needingAttention().map(\.lotId) == [unmeasurable])
        }
    }

    @Test("running low honours its limit")
    func runningLowLimit() throws {
        try withTemporaryDatabase { db in
            let f = try Fixture(db)
            for taken in [100.0, 200, 300, 400, 500, 600] {
                let lot = try f.lot()
                try f.event(lot, 1000, "CAPTURE", "2026-01-01T10:00:00")
                try f.event(lot, -taken, "COOK",  "2026-01-05T10:00:00")
            }
            #expect(try Inventory(db: db).runningLow(limit: 3).count == 3)
        }
    }
}
