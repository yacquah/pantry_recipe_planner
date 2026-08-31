import Foundation

/// One lot as the pantry screen needs to show it: what it is, how much is
/// left, how far through it you are, and whether any of that is guesswork.
///
/// Deliberately a superset of what one screen needs. Every field is something
/// the database already knows; the alternative is a view that queries three
/// times and stitches the answers together, which is where drift starts.
public struct InventoryItem: Sendable, Identifiable {
    public var id: Int64 { lotId }

    public let lotId: Int64
    public let productId: Int64
    public let name: String
    public let brand: String?
    public let baseUnit: String?

    /// What is left. **NULL means unknown, never zero** (rule 3). Basmati rice
    /// is the live case: a real bag with a real amount nobody wrote down.
    public let balance: Double?

    /// How many events counted toward that balance had no amount. Any number
    /// above zero means `balance` is a floor, not a total — an aggregate
    /// reports its own exclusions (rule 4).
    public let unknownEvents: Int

    /// Everything ever added to this lot, before anything was taken out. The
    /// denominator for "how far through it am I", and NULL for the same reason
    /// `balance` is.
    public let capturedTotal: Double?

    public let effectiveDate: String?
    public let expirySource: String?
    public let shelfLifeClass: String?

    /// How much of the lot is left, 0...1, or NULL when either end of the
    /// division is unknown.
    ///
    /// Not clamped upward by accident: a recount can legitimately observe more
    /// than was captured — you find the second bag at the back of the cupboard
    /// — and reporting 1.0 there would hide a real discrepancy the ledger went
    /// to some trouble to keep.
    public var remainingFraction: Double? {
        guard let balance, let capturedTotal, capturedTotal > 0 else { return nil }
        return balance / capturedTotal
    }

    /// Something about this lot cannot be stated, and a person could fix it.
    ///
    /// This is the "resolution task" ADR 001 separates from an alert: nothing
    /// here is urgent, but each one is a question the app cannot answer about
    /// food that is sitting in the kitchen right now.
    public var needsAttention: Bool {
        balance == nil || unknownEvents > 0 || expirySource == "unknown" || baseUnit == nil
    }

    /// Why it needs attention, in the words a person would use. NULL when it
    /// does not.
    public var attentionReason: String? {
        if baseUnit == nil            { return "no unit recorded" }
        if balance == nil             { return "quantity never recorded" }
        if unknownEvents > 0          { return "\(unknownEvents) change(s) with no amount" }
        if expirySource == "unknown"  { return "no date, and none can be worked out" }
        return nil
    }
}

/// Everything in the kitchen, with quantities.
///
/// The expiry chain answers "what is about to go bad" and the matcher answers
/// "what can I cook". Neither answers "what is actually in here and how much",
/// which is the question a pantry screen opens with.
public struct Inventory {
    private let db: Database

    public init(db: Database) { self.db = db }

    /// Every lot that still exists, soonest-expiring first.
    ///
    /// Undated lots sort last rather than first: a known deadline outranks an
    /// unknown one, the same ordering FEFO uses when drawing from lots.
    public func all() throws -> [InventoryItem] {
        try db.query("""
            SELECT b.lot_id, b.product_id, p.canonical_name, p.brand, p.base_unit,
                   p.shelf_life_class, b.balance, b.unknown_events,
                   x.effective_date, x.expiry_source,
                   (SELECT SUM(e.delta_base_unit)
                      FROM pantry_event e
                     WHERE e.lot_id = b.lot_id
                       AND e.reason = 'CAPTURE') AS captured_total
              FROM v_lot_balance b
              JOIN product p            ON p.id = b.product_id
              LEFT JOIN v_lot_expiry x  ON x.lot_id = b.lot_id
             ORDER BY (x.effective_date IS NULL), x.effective_date, p.canonical_name
            """).map(Self.item)
    }

    /// The lots with a question hanging over them, for the resolution list.
    ///
    /// Filtered in Swift rather than SQL on purpose: `needsAttention` is one
    /// rule with one definition, and duplicating it as a WHERE clause is how
    /// the list and the badge start disagreeing.
    public func needingAttention() throws -> [InventoryItem] {
        try all().filter(\.needsAttention)
    }

    /// What is furthest through, for "running low".
    ///
    /// Lots whose remaining fraction cannot be computed are **excluded rather
    /// than sorted to one end** — a lot with an unknown quantity is not
    /// "full", and putting it anywhere on a scale of fullness would state
    /// something nobody knows. They appear under attention instead.
    public func runningLow(limit: Int = 5) throws -> [InventoryItem] {
        try all()
            .compactMap { item in item.remainingFraction.map { (item, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func item(_ row: Row) -> InventoryItem {
        InventoryItem(
            lotId: row.int("lot_id") ?? 0,
            productId: row.int("product_id") ?? 0,
            name: row.string("canonical_name") ?? "?",
            brand: row.string("brand"),
            baseUnit: row.string("base_unit"),
            balance: row.double("balance"),
            unknownEvents: Int(row.int("unknown_events") ?? 0),
            capturedTotal: row.double("captured_total"),
            effectiveDate: row.string("effective_date"),
            expirySource: row.string("expiry_source"),
            shelfLifeClass: row.string("shelf_life_class")
        )
    }
}
