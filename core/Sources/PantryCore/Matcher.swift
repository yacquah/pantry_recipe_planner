import Foundation

/// Where a count-to-mass conversion came from. This decides whether an answer
/// may be stated confidently — not how comfortable the margin looks (ADR 004).
public enum BridgeSource: String, Sendable {
    /// Weighed on this lot. The per-piece figure is an average, but the total
    /// it reconstructs is exact, because the total is what went on the scale.
    case measured
    /// Printed on the packaging with no spread (min == max). Exact both ways.
    case printed
    /// A reference average for the food in general. Genuinely approximate.
    case reference

    /// Aggregating up over the same set that was weighed is lossless.
    /// Dividing down to a single piece is not — see `judge`.
    var isExactWhenAggregating: Bool {
        self == .measured || self == .printed
    }
}

public enum IngredientStatus: String, Sendable {
    case have
    case short
    case probably
    case probablyShort
    case cannotTell
}

public struct IngredientCheck: Sendable {
    public let ingredient: String
    public let needQty: Double
    public let needUnit: String
    public let haveQty: Double?
    public let status: IngredientStatus
    /// Present only when something could not be determined.
    public let reason: String?
}

public enum Verdict: String, Sendable {
    case yes = "YES"
    case no = "NO"
    case probably = "PROBABLY - CHECK"
    case cannotTell = "CANNOT TELL"
}

public struct RecipeMatch: Sendable {
    public let recipe: String
    public let verdict: Verdict
    public let decidedBy: String
    public let ingredients: [IngredientCheck]

    public var excluded: Int {
        ingredients.filter { $0.status == .cannotTell }.count
    }
}

/// Answers "what can I cook tonight without a store run?"
///
/// Note the division of labour, which differs from the expiry chain on
/// purpose. The expiry chain lives in a SQL view because three consumers —
/// the list, the notification job, FEFO ordering — must agree exactly, and a
/// view is the only way to guarantee they cannot drift.
///
/// The verdict rules below have one consumer and encode policy that will
/// change as ADR 004 is refined, so they live in Swift where they can be
/// unit-tested as pure functions with no database in the way. SQL fetches
/// facts; Swift decides what they mean.
public struct Matcher {
    private let db: Database

    public init(db: Database) { self.db = db }

    // MARK: - The policy, as a pure function

    /// Decides one ingredient. No I/O, so every branch is directly testable.
    ///
    /// Public because it is the readable statement of ADR 004's policy: any
    /// caller that needs to explain *why* a recipe got its verdict — the
    /// checks, and eventually the app's UI — should ask this rather than
    /// reimplement it.
    public static func judge(
        need: Double,
        needUnit: String,
        baseUnit: String?,
        have: Double?,
        unknownEvents: Int,
        gramsEach: Double?,
        bridge: BridgeSource?
    ) -> (IngredientStatus, String?) {

        // The quantity itself is unknown — no comparison is possible, and
        // treating NULL as zero here would produce a confident "no" from an
        // absence of data.
        guard let have, unknownEvents == 0 else {
            return (.cannotTell, "quantity unknown")
        }
        guard let baseUnit else {
            return (.cannotTell, "no base unit recorded")
        }

        // Same unit on both sides: exact, no bridge involved.
        if needUnit == baseUnit {
            return have >= need ? (.have, nil) : (.short, nil)
        }

        guard let gramsEach, let bridge else {
            return (.cannotTell, "needs \(needUnit), stored as \(baseUnit), no piece weight")
        }

        // Counting up into grams. Exact when the total was measured or printed.
        if needUnit == "g", baseUnit == "count" {
            let total = have * gramsEach
            if bridge.isExactWhenAggregating {
                return total >= need ? (.have, nil) : (.short, nil)
            }
            return total >= need ? (.probably, nil) : (.probablyShort, nil)
        }

        // Dividing grams down into pieces. Always approximate, even from a
        // measured average: knowing ten wings weigh 992 g says nothing certain
        // about any individual wing.
        if needUnit == "count", baseUnit == "g" {
            let pieces = have / gramsEach
            return pieces >= need ? (.probably, nil) : (.probablyShort, nil)
        }

        return (.cannotTell, "cannot convert \(baseUnit) to \(needUnit)")
    }

    /// Combines ingredient statuses into one answer for the recipe.
    ///
    /// A firm "no" requires an exact comparison. An approximate bridge may
    /// only ever produce "probably — check", in either direction: a false no
    /// quietly kills the feature, because you cook something else and the food
    /// rots anyway.
    public static func combine(_ statuses: [IngredientStatus]) -> Verdict {
        if statuses.contains(.short)      { return .no }
        if statuses.contains(.cannotTell) { return .cannotTell }
        if statuses.contains(where: { $0 == .probably || $0 == .probablyShort }) {
            return .probably
        }
        return .yes
    }

    // MARK: - Fetching the facts

    public func cookTonight() throws -> [RecipeMatch] {
        let rows = try db.query("""
            -- Balance and bridge both come from views now, not from sums and
            -- CASE expressions written here. Before, this summed the ledger
            -- directly and would have ignored a recount entirely: ADR 005 says
            -- an ADJUSTMENT is a checkpoint that supersedes earlier events, and
            -- a caller doing its own SUM cannot know that. Any consumer that
            -- reimplements a shared rule eventually disagrees with the others.
            WITH on_hand AS (
              SELECT product_id,
                     SUM(balance)        AS qty,
                     SUM(unknown_events) AS unknown_events
                FROM v_lot_balance
               GROUP BY product_id
            )
            SELECT r.name AS recipe, p.canonical_name AS ingredient,
                   ri.qty AS need_qty, ri.unit AS need_unit, p.base_unit,
                   oh.qty AS have_qty,
                   COALESCE(oh.unknown_events, 0) AS unknown_events,
                   w.grams_each,
                   w.source AS bridge_source
              FROM recipe_ingredient ri
              JOIN recipe  r ON r.id = ri.recipe_id
              JOIN product p ON p.id = ri.product_id
              LEFT JOIN on_hand oh ON oh.product_id = ri.product_id
              LEFT JOIN v_piece_weight w ON w.product_id = ri.product_id
             ORDER BY r.name, p.canonical_name
            """)

        var byRecipe: [String: [IngredientCheck]] = [:]
        var order: [String] = []

        for row in rows {
            guard let recipe = row.string("recipe"),
                  let ingredient = row.string("ingredient"),
                  let needQty = row.double("need_qty"),
                  let needUnit = row.string("need_unit") else { continue }

            let (status, reason) = Matcher.judge(
                need: needQty,
                needUnit: needUnit,
                baseUnit: row.string("base_unit"),
                have: row.double("have_qty"),
                unknownEvents: Int(row.int("unknown_events") ?? 0),
                gramsEach: row.double("grams_each"),
                bridge: row.string("bridge_source").flatMap(BridgeSource.init(rawValue:))
            )

            if byRecipe[recipe] == nil { order.append(recipe) }
            byRecipe[recipe, default: []].append(
                IngredientCheck(
                    ingredient: ingredient,
                    needQty: needQty,
                    needUnit: needUnit,
                    haveQty: row.double("have_qty"),
                    status: status,
                    reason: reason
                )
            )
        }

        return order.map { recipe in
            let checks = byRecipe[recipe] ?? []
            let verdict = Matcher.combine(checks.map(\.status))

            // Never just a verdict: name the ingredient that decided it.
            let decidedBy: String
            if let blocker = checks.first(where: { $0.status == .short }) {
                decidedBy = "\(blocker.ingredient) (short)"
            } else if let unknown = checks.first(where: { $0.status == .cannotTell }) {
                decidedBy = "\(unknown.ingredient) (\(unknown.reason ?? "unknown"))"
            } else if let hedged = checks.first(where: {
                $0.status == .probably || $0.status == .probablyShort
            }) {
                decidedBy = "\(hedged.ingredient) (via an approximate piece weight)"
            } else {
                decidedBy = "all ingredients confirmed"
            }

            return RecipeMatch(
                recipe: recipe,
                verdict: verdict,
                decidedBy: decidedBy,
                ingredients: checks
            )
        }
        .sorted { lhs, rhs in
            func rank(_ verdict: Verdict) -> Int {
                switch verdict {
                case .yes: return 0
                case .probably: return 1
                case .cannotTell: return 2
                case .no: return 3
                }
            }
            return rank(lhs.verdict) == rank(rhs.verdict)
                ? lhs.recipe < rhs.recipe
                : rank(lhs.verdict) < rank(rhs.verdict)
        }
    }
}
