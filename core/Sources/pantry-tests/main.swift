import Foundation
import PantryCore

// A dependency-free check runner.
//
// Neither XCTest nor Swift Testing is available on this machine: on macOS both
// ship inside Xcode rather than Command Line Tools. Rather than install a 30 GB
// IDE to obtain an assert function, this does the same job in about thirty
// lines — runs the checks, prints failures, exits non-zero so a shell or CI can
// tell. Converting to XCTest once Xcode is installed is mechanical: the
// assertions below map one-to-one onto XCTAssertEqual.
//
// Everything checked here is a pure function, so there is no database, no
// fixture and no setup. That is exactly why the verdict rules live in Swift
// rather than in SQL.

// In Swift 6, top-level code runs on the main actor, so these two variables
// are main-actor isolated. Functions declared beside them are NOT isolated by
// default, so each helper has to say it belongs there too — otherwise the
// compiler correctly refuses to let a nonisolated function touch them.
var checksRun = 0
var failures: [String] = []

@MainActor
func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checksRun += 1
    if actual != expected {
        failures.append("\(label)\n        expected: \(expected)\n        actual:   \(actual)")
    }
}

@MainActor
func expectTrue(_ condition: Bool, _ label: String) {
    checksRun += 1
    if !condition { failures.append(label) }
}

@MainActor
func suite(_ name: String, _ body: @MainActor () -> Void) {
    print("\n\(name)")
    let before = failures.count
    body()
    print(failures.count == before ? "  ok" : "  \(failures.count - before) failed")
}

// ---------------------------------------------------------------------------

suite("Ingredient verdicts — ADR 004") {

    // Same unit on both sides: an exact comparison, no bridge involved.
    expect(Matcher.judge(need: 400, needUnit: "g", baseUnit: "g",
                         have: 5275, unknownEvents: 0,
                         gramsEach: nil, bridge: nil).0,
           .have, "same unit, enough")

    expect(Matcher.judge(need: 6000, needUnit: "g", baseUnit: "g",
                         have: 5275, unknownEvents: 0,
                         gramsEach: nil, bridge: nil).0,
           .short, "same unit, short")

    // Basmati rice: the bag size was never recorded. Answering "no" here would
    // be a confident claim derived from an absence of data.
    let unknownQuantity = Matcher.judge(need: 250, needUnit: "g", baseUnit: "g",
                                        have: nil, unknownEvents: 1,
                                        gramsEach: nil, bridge: nil)
    expect(unknownQuantity.0, .cannotTell, "unknown quantity is not zero")
    expect(unknownQuantity.1, "quantity unknown", "and it says why")

    // One unknown event poisons an otherwise known total, rather than being
    // quietly dropped from the sum (modelling rule 4).
    expect(Matcher.judge(need: 100, needUnit: "g", baseUnit: "g",
                         have: 500, unknownEvents: 1,
                         gramsEach: nil, bridge: nil).0,
           .cannotTell, "partial unknown is still unknown")

    // The Lipton box: identity known, unit unknown (ADR 002).
    expect(Matcher.judge(need: 1, needUnit: "count", baseUnit: nil,
                         have: nil, unknownEvents: 1,
                         gramsEach: nil, bridge: nil).0,
           .cannotTell, "no base unit means no comparison")

    // No bridge at all.
    let noBridge = Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                                 have: 10, unknownEvents: 0,
                                 gramsEach: nil, bridge: nil)
    expect(noBridge.0, .cannotTell, "missing bridge gives no answer")
    expectTrue(noBridge.1?.contains("no piece weight") == true,
               "and names the missing piece weight")

    // 10 wings weighed at 992 g. The per-piece average is approximate, but the
    // total it rebuilds is exactly what went on the scale.
    expect(Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                         have: 10, unknownEvents: 0,
                         gramsEach: 99.2, bridge: .measured).0,
           .have, "measured total supports a confident answer")

    // Every Indomie pack really is 85 g; no spread to hedge over.
    expect(Matcher.judge(need: 300, needUnit: "g", baseUnit: "count",
                         have: 10, unknownEvents: 0,
                         gramsEach: 85, bridge: .printed).0,
           .have, "printed weight supports a confident answer")

    // A reference average is approximate in BOTH directions. The second case
    // matters most: a firm "no" from an approximate bridge is the failure that
    // quietly kills the feature, because you cook something else and the food
    // rots anyway.
    expect(Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                         have: 4, unknownEvents: 0,
                         gramsEach: 150, bridge: .reference).0,
           .probably, "reference average hedges when sufficient")

    expect(Matcher.judge(need: 900, needUnit: "g", baseUnit: "count",
                         have: 4, unknownEvents: 0,
                         gramsEach: 150, bridge: .reference).0,
           .probablyShort, "reference average hedges when short, never says no")

    // Knowing ten wings weigh 992 g says nothing certain about any single
    // wing, so "2 wings" gets a hedge even though the same data answered a
    // grams question confidently above.
    expect(Matcher.judge(need: 2, needUnit: "count", baseUnit: "g",
                         have: 992, unknownEvents: 0,
                         gramsEach: 99.2, bridge: .measured).0,
           .probably, "dividing down stays approximate even when measured")
}

suite("Recipe verdicts") {
    expect(Matcher.combine([.have, .have]), .yes, "all confirmed")
    expect(Matcher.combine([.have, .short, .cannotTell]), .no, "exact shortfall outranks all")
    expect(Matcher.combine([.have, .probably, .cannotTell]), .cannotTell, "unknown outranks a hedge")
    expect(Matcher.combine([.have, .probablyShort]), .probably, "probable shortfall is only 'check'")
}

suite("UUIDv7 — ADR 005") {
    let parts = UUIDv7.generate().split(separator: "-").map(\.count)
    expect(parts, [8, 4, 4, 4, 12], "canonical 8-4-4-4-12 shape")

    let hex = Array(UUIDv7.generate().replacingOccurrences(of: "-", with: ""))
    expect(hex[12], "7", "version nibble is 7")
    expectTrue("89ab".contains(hex[16]), "variant bits are 10xx")

    // The reason for version 7 over version 4: ids in an append-only log sort
    // into the order they were written.
    let earlier = UUIDv7.generate(at: .init(timeIntervalSince1970: 1_700_000_000))
    let later   = UUIDv7.generate(at: .init(timeIntervalSince1970: 1_800_000_000))
    expectTrue(earlier < later, "ids sort by creation time")
}

// ---------------------------------------------------------------------------

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("\(checksRun) checks passed")
    exit(0)
} else {
    print("\(checksRun) checks, \(failures.count) FAILED\n")
    for failure in failures { print("  • \(failure)") }
    exit(1)
}
