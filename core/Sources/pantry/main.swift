import Foundation
import PantryCore

// A deliberately small shell: parse arguments, call PantryCore, print. No
// business logic lives in this file, so the iOS app can replace it entirely.

let usage = """
pantry — a thin slice of the pantry planner

USAGE
  pantry migrate [--db PATH]      create or upgrade the database
  pantry list    [--days N] [--all] [--db PATH]
  pantry cook    [--why] [--db PATH]
  pantry capture "verbatim text" --name NAME [options]

FOOD LEAVING THE LEDGER
  pantry cook "Recipe name" [--dry-run] [--force]
  pantry waste   --lot N --qty N --reason expired|spoiled|freezer_burn|disliked|accident
  pantry eat     --lot N --qty N
  pantry recount --lot N --observed N       records what you actually saw

CAPTURE OPTIONS
  --name NAME          required — the only thing a capture cannot go without
  --brand BRAND
  --unit g|ml|count    omit when genuinely unknown
  --class ambient_stable|stable_until_opened|perishable
  --qty N              needs --unit
  --precision measured|derived|estimated   (default: estimated)
  --expires YYYY-MM-DD needs --kind
  --kind use_by|best_before|sell_by
  --date-precision day|month               (default: day)
  --container bag|box|bottle|can|loose

  --db PATH            default: /tmp/pantry.db

EXAMPLES
  pantry list --days 30
  pantry capture "half a bag of red lentils" --name "Red lentils" \\
      --unit g --qty 250 --class ambient_stable --precision estimated
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// --- argument parsing -------------------------------------------------------
var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
arguments = Array(arguments.dropFirst())

var flags: [String: String] = [:]
var positional: [String] = []
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if argument.hasPrefix("--") {
        let key = String(argument.dropFirst(2))
        if index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") {
            flags[key] = arguments[index + 1]
            index += 2
        } else {
            flags[key] = "true"          // a bare flag, e.g. --all
            index += 1
        }
    } else {
        positional.append(argument)
        index += 1
    }
}

let databasePath = flags["db"] ?? "/tmp/pantry.db"

do {
    let db = try Database(path: databasePath)

    // Every command except `migrate` refuses to touch a database whose shape
    // it does not recognise. Reading an out-of-date schema tends to produce
    // wrong answers rather than errors, which is the worse failure.
    if command != "migrate" {
        let current = try db.schemaVersion
        let latest = try Migrations.latestVersion()
        if current < latest {
            fail("""
                database is at schema version \(current); this build expects \(latest).
                       run:  pantry migrate --db \(databasePath)
                """)
        }
    }

    switch command {

    case "migrate":
        let before = try db.schemaVersion
        let applied = try db.migrate()
        if applied.isEmpty {
            print("already at schema version \(before) — nothing to do")
        } else {
            print("migrating \(databasePath)")
            for migration in applied {
                print("  applied \(String(format: "%03d", migration.version))  \(migration.name)")
            }
            print("now at schema version \(try db.schemaVersion)")
        }

    case "list":
        let expiry = Expiry(db: db)

        if flags["all"] != nil {
            print("Everything the app knows about expiry\n")
            print("ITEM                             ACTS BY               SOURCE           NOTIFY")
            print(String(repeating: "-", count: 84))
            for item in try expiry.all() {
                let date = item.effectiveDate.isEmpty ? "—" : item.displayDate
                print(item.item.padded(32)
                    + date.padded(22)
                    + item.source.padded(17)
                    + (item.shouldPush ? "push" : "list only"))
            }
            break
        }

        let days = Int(flags["days"] ?? "3") ?? 3
        let report = try expiry.upcoming(withinDays: days)

        if report.items.isEmpty {
            print("Nothing expiring in the next \(days) day(s).")
        } else {
            print("Expiring within \(days) day(s):\n")
            for item in report.items {
                let when = item.daysLeft < 0
                    ? "\(-item.daysLeft)d ago"
                    : "in \(item.daysLeft)d"
                print("  \(item.item.padded(32))\(item.displayDate.padded(20))\(when.padded(10))\(item.wording)")
            }
        }

        // Rule 4: the answer reports what it could not assess.
        print("""

        \(report.lotsTotal) lots — \(report.notApplicable) not applicable, \
        \(report.excludedUnknown) could not be assessed
        """)

    // `cook` with a recipe name actually cooks it. Without one it answers the
    // question instead. Same verb, because they are the same act at different
    // stages of making up your mind.
    case "cook" where !positional.isEmpty:
        let name = positional[0]
        let consumption = Consumption(db: db)
        let plan = try consumption.planCook(recipeNamed: name)

        print("\(plan.recipeName)\n")
        for draw in plan.draws {
            print("  \(draw.productName.padded(30))"
                + String(format: "-%g %@", draw.amount, draw.unit).padded(14)
                + "lot \(draw.lotId)".padded(8)
                + "(\(draw.precision))")
        }
        for problem in plan.problems { print("  ! \(problem)") }

        if flags["dry-run"] != nil {
            print("\ndry run — nothing written")
            break
        }
        if !plan.isSatisfiable && flags["force"] == nil {
            fail("not satisfiable. Fix the above, or pass --force to record it anyway.")
        }

        let written = try consumption.execute(plan, force: flags["force"] != nil)
        print("\n\(written.count) COOK event(s) written")

    // What is actually in the kitchen and how much. The expiry chain answers
    // what is going off and the matcher answers what can be cooked; neither
    // answers this, which is the question a pantry screen opens with.
    case "inventory":
        let inventory = Inventory(db: db)
        let items = try inventory.all()

        print("ITEM                             LEFT          OF CAPTURED   ACTS BY")
        print(String(repeating: "-", count: 84))
        for item in items {
            let left = item.balance.map { qty in
                String(format: "%g %@", qty, item.baseUnit ?? "")
            } ?? "unknown"
            let fraction = item.remainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            print(item.name.padded(33)
                + left.padded(14)
                + fraction.padded(14)
                + (item.effectiveDate ?? "—"))
        }

        let attention = try inventory.needingAttention()
        if !attention.isEmpty {
            print("\nNeeds attention — \(attention.count) lot(s) the app cannot fully describe")
            for item in attention {
                print("  \(item.name.padded(33))\(item.attentionReason ?? "")")
            }
        }

        // Rule 4: the answer states what it left out of the measurable list.
        let measurable = items.filter { $0.remainingFraction != nil }.count
        print("\n\(items.count) lots — \(measurable) can be measured, "
            + "\(items.count - measurable) cannot")

    // What the phone should have pending. The phone is the only thing that can
    // actually post a notification, but the decision about which ones exist is
    // a rule, and rules are inspectable from here like every other one.
    case "alerts":
        let plan = ExpiryAlerts.plan(for: try Expiry(db: db).all())

        if plan.isEmpty {
            print("Nothing to notify about.")
        } else {
            print("\(plan.count) alert(s) would be pending\n")
            print("FIRES              LEAD   ITEM                             SAYS")
            print(String(repeating: "-", count: 96))
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH:mm"
            for alert in plan {
                print(stamp.string(from: alert.fireAt).padded(19)
                    + "\(alert.leadDays)d".padded(7)
                    + alert.item.padded(33)
                    + alert.body)
            }
        }

        // Rule 4 again: say what was considered and passed over, or the empty
        // case reads as "nothing expires" rather than "nothing may interrupt".
        let considered = try Expiry(db: db).all()
        let silent = considered.filter { !$0.shouldPush }.count
        print("\n\(considered.count) lots — \(silent) may never notify (ADR 001), "
            + "\(considered.count - silent - plan.count) eligible but not due")

    case "seed":
        try StarterData.load(into: db, force: flags["force"] != nil)
        let count = try db.query("SELECT COUNT(*) AS n FROM product").first?.int("n") ?? 0
        print("starter inventory imported — \(count) products")

    case "waste":
        guard let lot = flags["lot"].flatMap(Int64.init),
              let qty = flags["qty"].flatMap(Double.init),
              let why = flags["reason"] else {
            fail("usage: pantry waste --lot N --qty N --reason expired|spoiled|freezer_burn|disliked|accident")
        }
        let id = try Consumption(db: db).waste(
            lotId: lot, quantity: qty, reason: why,
            precision: flags["precision"] ?? "estimated")
        print("WASTE recorded (\(why))  event \(id)")

    case "eat":
        guard let lot = flags["lot"].flatMap(Int64.init),
              let qty = flags["qty"].flatMap(Double.init) else {
            fail("usage: pantry eat --lot N --qty N")
        }
        let id = try Consumption(db: db).consume(
            lotId: lot, quantity: qty,
            precision: flags["precision"] ?? "estimated")
        print("CONSUME recorded  event \(id)")

    case "recount":
        guard let lot = flags["lot"].flatMap(Int64.init),
              let observed = flags["observed"].flatMap(Double.init) else {
            fail("usage: pantry recount --lot N --observed N")
        }
        let consumption = Consumption(db: db)
        let before = try consumption.balance(ofLot: lot)
        let id = try consumption.adjust(
            lotId: lot, observed: observed,
            precision: flags["precision"] ?? "estimated")
        let previous = before.balance.map { String(format: "%g", $0) } ?? "unknown"
        print("""
            recount of \(before.productName)
              ledger said  \(previous)
              you observed \(observed)
            ADJUSTMENT recorded — this is now the checkpoint.  event \(id)
            """)

    case "cook":
        let matches = try Matcher(db: db).cookTonight()
        guard !matches.isEmpty else {
            print("No recipes recorded yet.")
            break
        }

        print("What can I cook tonight?\n")
        for match in matches {
            print("  \(match.verdict.rawValue.padded(20))\(match.recipe)")
            print("  \(String(repeating: " ", count: 20))\(match.decidedBy)")

            // --why shows the working: what each ingredient needed, what is on
            // hand, and how the comparison was reached.
            if flags["why"] != nil {
                for check in match.ingredients {
                    let have = check.haveQty.map { String(format: "%g", $0) } ?? "unknown"
                    let need = String(format: "%g", check.needQty)
                    print("  \(String(repeating: " ", count: 20))"
                        + "· \(check.ingredient.padded(28))"
                        + "need \(need) \(check.needUnit), have \(have)"
                        + "  [\(check.status.rawValue)]")
                }
            }
            print("")
        }

        let unresolved = matches.reduce(0) { $0 + $1.excluded }
        print("\(matches.count) recipes — \(unresolved) ingredient(s) could not be assessed")

    case "capture":
        guard let name = flags["name"] else {
            fail("--name is required (ADR 002: identity is the one thing a capture cannot omit)")
        }
        let verbatim = positional.first ?? name

        let request = CaptureRequest(
            verbatim: verbatim,
            name: name,
            brand: flags["brand"],
            baseUnit: flags["unit"],
            shelfLifeClass: flags["class"],
            quantity: flags["qty"].flatMap(Double.init),
            precision: flags["precision"],
            expiresOn: flags["expires"],
            expiryKind: flags["kind"],
            expiryPrecision: flags["date-precision"],
            containerType: flags["container"],
            deviceId: "cli"
        )

        let result = try Capture(db: db).record(request)
        print("captured  \"\(verbatim)\"")
        print("  raw      \(result.rawId)")
        print("  product  \(result.productId)\(result.reusedProduct ? " (existing)" : " (new)")")
        print("  lot      \(result.lotId)")
        print("  event    \(result.eventId)")
        if flags["qty"] == nil {
            print("  note     no quantity recorded — stored as NULL, not zero")
        }

    default:
        print(usage)
        exit(1)
    }
} catch {
    fail("\(error)")
}

// --- small helpers ----------------------------------------------------------
extension String {
    /// Pads to a fixed width for column output. Long values are left intact
    /// rather than truncated: a clipped product name is a wrong product name.
    func padded(_ width: Int) -> String {
        count >= width ? self + "  " : self + String(repeating: " ", count: width - count)
    }
}
