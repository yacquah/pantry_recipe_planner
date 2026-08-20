import Foundation

/// Everything a capture can carry. Almost all of it is optional, because
/// ADR 002 makes identity the only hard requirement — an item whose unit,
/// class and quantity are all unknown must still be recordable, or the app
/// cannot represent "a Lipton box".
public struct CaptureRequest: Sendable {
    public var verbatim: String
    public var name: String
    public var brand: String?
    public var baseUnit: String?         // g | ml | count
    public var shelfLifeClass: String?   // ambient_stable | stable_until_opened | perishable
    public var quantity: Double?
    public var precision: String?        // measured | derived | estimated
    public var expiresOn: String?        // YYYY-MM-DD
    public var expiryKind: String?       // use_by | best_before | sell_by
    public var expiryPrecision: String?  // day | month
    public var containerType: String?
    public var deviceId: String

    public init(
        verbatim: String,
        name: String,
        brand: String? = nil,
        baseUnit: String? = nil,
        shelfLifeClass: String? = nil,
        quantity: Double? = nil,
        precision: String? = nil,
        expiresOn: String? = nil,
        expiryKind: String? = nil,
        expiryPrecision: String? = nil,
        containerType: String? = nil,
        deviceId: String = "cli"
    ) {
        self.verbatim = verbatim
        self.name = name
        self.brand = brand
        self.baseUnit = baseUnit
        self.shelfLifeClass = shelfLifeClass
        self.quantity = quantity
        self.precision = precision
        self.expiresOn = expiresOn
        self.expiryKind = expiryKind
        self.expiryPrecision = expiryPrecision
        self.containerType = containerType
        self.deviceId = deviceId
    }
}

public struct CaptureResult: Sendable {
    public let rawId: String
    public let productId: Int64
    public let lotId: Int64
    public let eventId: String
    public let reusedProduct: Bool
}

/// The write path: untrusted input in, canonical rows out.
public struct Capture {
    private let db: Database

    public init(db: Database) { self.db = db }

    public enum Invalid: Error, CustomStringConvertible {
        case quantityWithoutUnit
        case expiryWithoutKind

        public var description: String {
            switch self {
            case .quantityWithoutUnit:
                return "a quantity needs a base unit — 500 of what?"
            case .expiryWithoutKind:
                return "a date needs its kind (use_by / best_before / sell_by): " +
                       "a safety date and a quality date imply opposite behaviour"
            }
        }
    }

    /// Records a capture and normalises it, all or nothing.
    ///
    /// The order matters and mirrors the architecture: the untrusted row lands
    /// first and is never edited afterwards, then normalisation derives the
    /// canonical rows, then the raw row is stamped with what it became.
    @discardableResult
    public func record(_ request: CaptureRequest) throws -> CaptureResult {
        // Fail before writing anything, not halfway through.
        if request.quantity != nil && request.baseUnit == nil {
            throw Invalid.quantityWithoutUnit
        }
        if request.expiresOn != nil && request.expiryKind == nil {
            throw Invalid.expiryWithoutKind
        }

        let now = Timestamp.instant()
        let today = Timestamp.day()
        let rawId = UUIDv7.generate()
        let eventId = UUIDv7.generate()

        return try db.transaction {
            // 1. The untrusted row. Everything the user typed, unmodified.
            //    A BEFORE UPDATE trigger in the schema will refuse any later
            //    attempt to change these fields.
            try db.run("""
                INSERT INTO raw_capture
                    (id, captured_at, device_id, source, verbatim, payload, lookup_status)
                VALUES (?, ?, ?, 'manual', ?, json_object('entered_via','cli'), 'not_applicable')
                """,
                [.text(rawId), .text(now), .text(request.deviceId), .text(request.verbatim)]
            )

            // 2. Normalisation — find the product, or create it.
            let existing = try db.query("""
                SELECT id FROM product
                 WHERE canonical_name = ? AND COALESCE(brand,'') = COALESCE(?,'')
                """,
                [.text(request.name), request.brand.map { SQLValue.text($0) } ?? .null]
            )

            let productId: Int64
            let reused: Bool
            if let found = existing.first?.int("id") {
                productId = found
                reused = true
            } else {
                // needs_review is set when the unit or the class is unknown:
                // the row is usable, and it is also visibly incomplete.
                let incomplete = request.baseUnit == nil || request.shelfLifeClass == nil
                productId = try db.run("""
                    INSERT INTO product
                        (canonical_name, brand, base_unit, shelf_life_class, needs_review)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(request.name),
                        request.brand.map { SQLValue.text($0) } ?? .null,
                        request.baseUnit.map { SQLValue.text($0) } ?? .null,
                        request.shelfLifeClass.map { SQLValue.text($0) } ?? .null,
                        .int(incomplete ? 1 : 0),
                    ]
                )
                reused = false
            }

            // 3. The lot. Note what is absent: no quantity column. Quantity is
            //    the sum of the ledger (ADR 003), so it cannot be written here
            //    even by accident.
            let lotId = try db.run("""
                INSERT INTO lot
                    (product_id, acquired_on, expires_on, expiry_kind,
                     expires_on_precision, is_opened, is_frozen, container_type, needs_review)
                VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)
                """,
                [
                    .int(productId),
                    .text(today),
                    request.expiresOn.map { SQLValue.text($0) } ?? .null,
                    request.expiryKind.map { SQLValue.text($0) } ?? .null,
                    request.expiresOn == nil
                        ? .null
                        : .text(request.expiryPrecision ?? "day"),
                    request.containerType.map { SQLValue.text($0) } ?? .null,
                    .int(request.quantity == nil ? 1 : 0),
                ]
            )

            // 4. The opening entry in the ledger. A NULL delta is legal and
            //    means the amount is unknown; precision travels with it, since
            //    precision describes a number and there may not be one.
            try db.run("""
                INSERT INTO pantry_event
                    (id, lot_id, product_id, delta_base_unit, reason,
                     qty_precision, occurred_at, device_id)
                VALUES (?, ?, ?, ?, 'CAPTURE', ?, ?, ?)
                """,
                [
                    .text(eventId),
                    .int(lotId),
                    .int(productId),
                    request.quantity.map { SQLValue.double($0) } ?? .null,
                    request.quantity == nil
                        ? .null
                        : .text(request.precision ?? "estimated"),
                    .text(now),
                    .text(request.deviceId),
                ]
            )

            // 5. Stamp the raw row with what it became. This is an UPDATE, and
            //    it is allowed: it records what the system DID with the
            //    capture, not what was captured.
            try db.run("""
                UPDATE raw_capture
                   SET product_id = ?, lot_id = ?, normalised_at = ?
                 WHERE id = ?
                """,
                [.int(productId), .int(lotId), .text(now), .text(rawId)]
            )

            return CaptureResult(
                rawId: rawId,
                productId: productId,
                lotId: lotId,
                eventId: eventId,
                reusedProduct: reused
            )
        }
    }
}
