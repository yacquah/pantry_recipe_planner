import Foundation

/// How much is in one lot, and how trustworthy that number is.
public struct LotBalance: Sendable {
    public let lotId: Int64
    public let productId: Int64
    public let productName: String
    public let baseUnit: String?
    public let balance: Double?
    public let unknownEvents: Int
    public let effectiveDate: String?
}

/// One lot's contribution to a planned draw.
public struct Draw: Sendable {
    public let lotId: Int64
    public let productId: Int64
    public let productName: String
    public let amount: Double        // positive: how much leaves the lot
    public let unit: String
    public let precision: String

    public init(
        lotId: Int64, productId: Int64, productName: String,
        amount: Double, unit: String, precision: String
    ) {
        self.lotId = lotId
        self.productId = productId
        self.productName = productName
        self.amount = amount
        self.unit = unit
        self.precision = precision
    }

    /// The same draw with a different amount, and the precision that a
    /// human-supplied number earns.
    ///
    /// ADR 003: a recipe amount is a *default*, not a decision. One tap
    /// accepts it and it stays `derived`; typing a real number makes it
    /// `measured`, because somebody looked. Overwriting the amount without
    /// upgrading the precision would lose the fact that they did.
    public func amended(to newAmount: Double) -> Draw {
        Draw(lotId: lotId, productId: productId, productName: productName,
             amount: newAmount, unit: unit,
             precision: newAmount == amount ? precision : "measured")
    }
}

/// What cooking a recipe would do, before anything is written.
public struct CookPlan: Sendable, Identifiable {
    /// The recipe it plans, which is what identifies it — you cannot be
    /// part-way through cooking the same recipe twice at once.
    public var id: Int64 { recipeId }

    public let recipeId: Int64
    public let recipeName: String
    public let draws: [Draw]
    public let problems: [String]

    public init(recipeId: Int64, recipeName: String, draws: [Draw], problems: [String]) {
        self.recipeId = recipeId
        self.recipeName = recipeName
        self.draws = draws
        self.problems = problems
    }

    public var isSatisfiable: Bool { problems.isEmpty }

    /// The same plan with one lot's amount changed.
    ///
    /// Public so a screen can offer the editable default ADR 003 requires. The
    /// problems are carried over untouched: they describe whether the recipe
    /// can be made at all, and letting an edit clear them would turn "you do
    /// not have this" into "you do" by typing.
    public func amending(lotId: Int64, to amount: Double) -> CookPlan {
        CookPlan(
            recipeId: recipeId,
            recipeName: recipeName,
            draws: draws.map { $0.lotId == lotId ? $0.amended(to: amount) : $0 },
            problems: problems
        )
    }
}

/// The write path: everything that removes food from the ledger.
///
/// Split into plan and execute on purpose. A plan can be shown, checked, and
/// tested without touching the database, which is what makes `--dry-run`
/// trivial rather than a second code path that drifts.
public struct Consumption {
    private let db: Database

    public init(db: Database) { self.db = db }

    public enum Failure: Error, CustomStringConvertible {
        case noSuchLot(Int64)
        case noSuchRecipe(String)
        case notSatisfiable(recipe: String, problems: [String])
        case cannotConvert(product: String, from: String, to: String)

        public var description: String {
            switch self {
            case .noSuchLot(let id):
                return "no lot with id \(id)"
            case .noSuchRecipe(let name):
                return "no recipe called '\(name)'"
            case .notSatisfiable(let recipe, let problems):
                return "cannot cook '\(recipe)':\n  - " + problems.joined(separator: "\n  - ")
            case .cannotConvert(let product, let from, let to):
                return "\(product): no way to convert \(from) into \(to) — no piece weight recorded"
            }
        }
    }

    // MARK: - Reading

    /// Lots holding a product, in FEFO order: first expired, first out.
    ///
    /// Undated lots sort last, because a known deadline outranks an unknown
    /// one (ADR 001). Cooking should burn down the thing that dies soonest.
    public func lots(forProduct productId: Int64) throws -> [LotBalance] {
        try db.query("""
            SELECT b.lot_id, b.product_id, p.canonical_name, p.base_unit,
                   b.balance, b.unknown_events, x.effective_date
              FROM v_lot_balance b
              JOIN product p       ON p.id = b.product_id
              LEFT JOIN v_lot_expiry x ON x.lot_id = b.lot_id
             WHERE b.product_id = ?
             ORDER BY (x.effective_date IS NULL), x.effective_date, b.lot_id
            """, [.int(productId)]
        ).map {
            LotBalance(
                lotId: $0.int("lot_id") ?? 0,
                productId: $0.int("product_id") ?? 0,
                productName: $0.string("canonical_name") ?? "?",
                baseUnit: $0.string("base_unit"),
                balance: $0.double("balance"),
                unknownEvents: Int($0.int("unknown_events") ?? 0),
                effectiveDate: $0.string("effective_date")
            )
        }
    }

    public func balance(ofLot lotId: Int64) throws -> LotBalance {
        let rows = try db.query("""
            SELECT b.lot_id, b.product_id, p.canonical_name, p.base_unit,
                   b.balance, b.unknown_events, NULL AS effective_date
              FROM v_lot_balance b
              JOIN product p ON p.id = b.product_id
             WHERE b.lot_id = ?
            """, [.int(lotId)])

        guard let row = rows.first else { throw Failure.noSuchLot(lotId) }
        return LotBalance(
            lotId: row.int("lot_id") ?? lotId,
            productId: row.int("product_id") ?? 0,
            productName: row.string("canonical_name") ?? "?",
            baseUnit: row.string("base_unit"),
            balance: row.double("balance"),
            unknownEvents: Int(row.int("unknown_events") ?? 0),
            effectiveDate: nil
        )
    }

    // MARK: - Converting a recipe requirement into base units

    /// How much of a product a recipe needs, expressed in that product's own
    /// base unit, plus how well the resulting number is known.
    ///
    /// Pure, so every branch is checkable without a database.
    public static func requirement(
        recipeQuantity: Double,
        recipeUnit: String,
        baseUnit: String,
        gramsEach: Double?
    ) -> (amount: Double, precision: String)? {

        if recipeUnit == baseUnit {
            // Counting is exact; measuring out 400 g of rice from a bag is not.
            return (recipeQuantity, baseUnit == "count" ? "measured" : "derived")
        }

        guard let gramsEach, gramsEach > 0 else { return nil }

        if recipeUnit == "g", baseUnit == "count" {
            // You cannot take 2.016 wings. Round to whole pieces, and never
            // to zero — needing a little still means taking one.
            let pieces = (recipeQuantity / gramsEach).rounded()
            return (max(1, pieces), "derived")
        }

        if recipeUnit == "count", baseUnit == "g" {
            return (recipeQuantity * gramsEach, "derived")
        }

        return nil
    }

    // MARK: - Cooking

    public func planCook(recipeNamed name: String) throws -> CookPlan {
        let recipeRows = try db.query(
            "SELECT id, name FROM recipe WHERE name = ?", [.text(name)])
        guard let recipe = recipeRows.first, let recipeId = recipe.int("id") else {
            throw Failure.noSuchRecipe(name)
        }

        let ingredients = try db.query("""
            SELECT ri.product_id, ri.qty, ri.unit,
                   p.canonical_name, p.base_unit,
                   w.grams_each
              FROM recipe_ingredient ri
              JOIN product p ON p.id = ri.product_id
              LEFT JOIN v_piece_weight w ON w.product_id = ri.product_id
             WHERE ri.recipe_id = ?
             ORDER BY p.canonical_name
            """, [.int(recipeId)])

        var draws: [Draw] = []
        var problems: [String] = []

        for ingredient in ingredients {
            let productId = ingredient.int("product_id") ?? 0
            let productName = ingredient.string("canonical_name") ?? "?"
            let recipeQty = ingredient.double("qty") ?? 0
            let recipeUnit = ingredient.string("unit") ?? "?"

            guard let baseUnit = ingredient.string("base_unit") else {
                problems.append("\(productName): no base unit recorded")
                continue
            }

            guard let need = Consumption.requirement(
                recipeQuantity: recipeQty,
                recipeUnit: recipeUnit,
                baseUnit: baseUnit,
                gramsEach: ingredient.double("grams_each")
            ) else {
                problems.append(
                    "\(productName): needs \(recipeUnit), stored as \(baseUnit), no piece weight")
                continue
            }

            // Draw down the lots in FEFO order until the requirement is met.
            var remaining = need.amount
            for lot in try lots(forProduct: productId) {
                if remaining <= 1e-9 { break }
                guard let available = lot.balance, lot.unknownEvents == 0 else {
                    problems.append("\(productName): lot \(lot.lotId) has an unknown quantity")
                    remaining = .nan          // poison it; cannot plan honestly
                    break
                }
                if available <= 0 { continue }

                let take = min(available, remaining)
                draws.append(Draw(
                    lotId: lot.lotId, productId: productId, productName: productName,
                    amount: take, unit: baseUnit, precision: need.precision))
                remaining -= take
            }

            if remaining.isNaN { continue }
            if remaining > 1e-9 {
                problems.append(String(
                    format: "%@: short by %g %@", productName, remaining, baseUnit))
            }
        }

        return CookPlan(recipeId: recipeId, recipeName: name, draws: draws, problems: problems)
    }

    /// Writes a plan to the ledger. All of it, or none of it.
    @discardableResult
    public func execute(_ plan: CookPlan, force: Bool = false) throws -> [String] {
        guard plan.isSatisfiable || force else {
            throw Failure.notSatisfiable(recipe: plan.recipeName, problems: plan.problems)
        }

        let now = Timestamp.instant()
        var ids: [String] = []

        try db.transaction {
            for draw in plan.draws {
                let id = UUIDv7.generate()
                try db.run("""
                    INSERT INTO pantry_event
                        (id, lot_id, product_id, delta_base_unit, reason,
                         qty_precision, recipe_id, occurred_at, device_id)
                    VALUES (?, ?, ?, ?, 'COOK', ?, ?, ?, 'cli')
                    """,
                    [.text(id), .int(draw.lotId), .int(draw.productId),
                     .double(-draw.amount), .text(draw.precision),
                     .int(plan.recipeId), .text(now)]
                )
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: - The other ways food leaves

    @discardableResult
    public func waste(
        lotId: Int64, quantity: Double, reason: String, precision: String = "estimated"
    ) throws -> String {
        try single(lotId: lotId, delta: -quantity, reason: "WASTE",
                   wasteReason: reason, precision: precision)
    }

    @discardableResult
    public func consume(
        lotId: Int64, quantity: Double, precision: String = "estimated"
    ) throws -> String {
        try single(lotId: lotId, delta: -quantity, reason: "CONSUME",
                   wasteReason: nil, precision: precision)
    }

    /// A recount. Records what was actually observed, and becomes the
    /// checkpoint every later event is measured from (ADR 005).
    @discardableResult
    public func adjust(
        lotId: Int64, observed: Double, precision: String = "estimated"
    ) throws -> String {
        let current = try balance(ofLot: lotId)

        // The delta is the correction needed to reach what the eyes saw. When
        // the previous balance was unknown there is no correction to state —
        // NULL is honest, and the observation stands on its own.
        let delta: SQLValue = current.balance.map { .double(observed - $0) } ?? .null
        let precisionValue: SQLValue = current.balance == nil ? .null : .text(precision)

        let id = UUIDv7.generate()
        try db.run("""
            INSERT INTO pantry_event
                (id, lot_id, product_id, delta_base_unit, reason,
                 qty_precision, observed_qty, occurred_at, device_id)
            VALUES (?, ?, ?, ?, 'ADJUSTMENT', ?, ?, ?, 'cli')
            """,
            [.text(id), .int(lotId), .int(current.productId), delta,
             precisionValue, .double(observed), .text(Timestamp.instant())]
        )
        return id
    }

    private func single(
        lotId: Int64, delta: Double, reason: String,
        wasteReason: String?, precision: String
    ) throws -> String {
        let lot = try balance(ofLot: lotId)
        let id = UUIDv7.generate()
        try db.run("""
            INSERT INTO pantry_event
                (id, lot_id, product_id, delta_base_unit, reason,
                 waste_reason, qty_precision, occurred_at, device_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'cli')
            """,
            [.text(id), .int(lotId), .int(lot.productId), .double(delta),
             .text(reason), wasteReason.map { SQLValue.text($0) } ?? .null,
             .text(precision), .text(Timestamp.instant())]
        )
        return id
    }
}
