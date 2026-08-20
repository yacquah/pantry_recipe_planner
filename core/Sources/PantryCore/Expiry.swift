import Foundation

public struct ExpiryItem: Sendable {
    public let item: String
    public let effectiveDate: String
    public let isMonthPrecision: Bool
    public let source: String        // label | derived_* | not_applicable | unknown
    public let kind: String?         // use_by | best_before | sell_by
    public let daysLeft: Int
    public let shelfLifeClass: String?

    /// ADR 001: a best-before is a quality date and is never reported as
    /// "expired". Saying so makes people bin good food, which would turn an
    /// app built to reduce waste into a cause of it.
    public var wording: String {
        switch kind {
        case "use_by":      return "USE BY — safety date"
        case "best_before": return daysLeft < 0 ? "past best before, likely fine"
                                                : "approaching best before"
        case "sell_by":     return "sell-by (the shop's date, not yours)"
        default:            return "estimated — no date recorded"
        }
    }

    /// Only safety dates and perishables interrupt anybody. Surfaced and
    /// notified are different things (ADR 001).
    public var shouldPush: Bool {
        kind == "use_by" || shelfLifeClass == "perishable"
    }

    public var displayDate: String {
        isMonthPrecision ? String(effectiveDate.prefix(7)) + " (month only)" : effectiveDate
    }
}

/// Every answer carries its own exclusions (modelling rule 4). A list that
/// silently omits what it could not assess is more dangerous than one that
/// refuses, because a plausible number goes unquestioned.
public struct ExpiryReport: Sendable {
    public let items: [ExpiryItem]
    public let notApplicable: Int
    public let excludedUnknown: Int
    public let lotsTotal: Int
}

public struct Expiry {
    private let db: Database

    public init(db: Database) { self.db = db }

    /// Reads ADR 001's resolution chain out of `v_lot_expiry`.
    ///
    /// The chain itself lives in the view rather than here, so the CLI, the
    /// notification job and FEFO ordering cannot drift apart by each
    /// reimplementing it slightly differently.
    public func upcoming(withinDays days: Int) throws -> ExpiryReport {
        let rows = try db.query("""
            SELECT canonical_name, effective_date, expires_on_precision,
                   expiry_source, expiry_kind, shelf_life_class,
                   CAST(julianday(effective_date) - julianday(date('now')) AS INTEGER) AS days_left
              FROM v_lot_expiry
             WHERE effective_date IS NOT NULL
               AND effective_date <= date('now', '+' || ? || ' days')
             ORDER BY effective_date
            """,
            [.int(Int64(days))]
        )

        let items = rows.compactMap { row -> ExpiryItem? in
            guard let name = row.string("canonical_name"),
                  let date = row.string("effective_date"),
                  let source = row.string("expiry_source") else { return nil }
            return ExpiryItem(
                item: name,
                effectiveDate: date,
                isMonthPrecision: row.string("expires_on_precision") == "month",
                source: source,
                kind: row.string("expiry_kind"),
                daysLeft: Int(row.int("days_left") ?? 0),
                shelfLifeClass: row.string("shelf_life_class")
            )
        }

        let counts = try db.query("""
            SELECT
              (SELECT COUNT(*) FROM v_lot_expiry WHERE expiry_source = 'not_applicable') AS not_applicable,
              (SELECT COUNT(*) FROM v_lot_expiry WHERE expiry_source = 'unknown')        AS unknown,
              (SELECT COUNT(*) FROM lot)                                                 AS total
            """).first

        return ExpiryReport(
            items: items,
            notApplicable: Int(counts?.int("not_applicable") ?? 0),
            excludedUnknown: Int(counts?.int("unknown") ?? 0),
            lotsTotal: Int(counts?.int("total") ?? 0)
        )
    }

    /// Everything the app knows about expiry, for inspection.
    public func all() throws -> [ExpiryItem] {
        let rows = try db.query("""
            SELECT canonical_name, effective_date, expires_on_precision,
                   expiry_source, expiry_kind, shelf_life_class,
                   CAST(COALESCE(julianday(effective_date) - julianday(date('now')), 0) AS INTEGER) AS days_left
              FROM v_lot_expiry
             ORDER BY effective_date IS NULL, effective_date
            """)

        return rows.compactMap { row in
            guard let name = row.string("canonical_name"),
                  let source = row.string("expiry_source") else { return nil }
            return ExpiryItem(
                item: name,
                effectiveDate: row.string("effective_date") ?? "",
                isMonthPrecision: row.string("expires_on_precision") == "month",
                source: source,
                kind: row.string("expiry_kind"),
                daysLeft: Int(row.int("days_left") ?? 0),
                shelfLifeClass: row.string("shelf_life_class")
            )
        }
    }
}
