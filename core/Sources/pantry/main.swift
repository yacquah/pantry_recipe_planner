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
