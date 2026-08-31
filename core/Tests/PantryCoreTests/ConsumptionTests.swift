import Testing
import Foundation
import PantryCore

@Suite("UUIDv7 — ADR 005")
struct UUIDv7Tests {

    @Test("has the canonical 8-4-4-4-12 shape")
    func shape() {
        #expect(UUIDv7.generate().split(separator: "-").map(\.count) == [8, 4, 4, 4, 12])
    }

    @Test("carries the version and variant bits of a v7 uuid")
    func versionBits() {
        let hex = Array(UUIDv7.generate().replacingOccurrences(of: "-", with: ""))
        #expect(hex[12] == "7", "version nibble is 7")
        #expect("89ab".contains(hex[16]), "variant bits are 10xx")
    }

    /// The reason for version 7 over version 4: ids in an append-only log sort
    /// into the order they were written.
    @Test("ids sort by creation time")
    func sortable() {
        let earlier = UUIDv7.generate(at: .init(timeIntervalSince1970: 1_700_000_000))
        let later   = UUIDv7.generate(at: .init(timeIntervalSince1970: 1_800_000_000))
        #expect(earlier < later)
    }
}

/// Pure, so no database. What a recipe asks for, translated into the unit the
/// product is actually stored in, plus how well the result is known.
@Suite("Recipe requirement → base units — ADR 004")
struct RequirementTests {

    /// Counting is exact; measuring 400 g out of a bag is not, so the two carry
    /// different precision even though neither crosses a bridge.
    @Test("same unit passes the amount through, but not the confidence")
    func sameUnit() throws {
        let rice = try #require(Consumption.requirement(
            recipeQuantity: 400, recipeUnit: "g", baseUnit: "g", gramsEach: nil))
        #expect(rice.amount == 400)
        #expect(rice.precision == "derived", "measuring out of a bag is derived, not measured")

        let packs = try #require(Consumption.requirement(
            recipeQuantity: 2, recipeUnit: "count", baseUnit: "count", gramsEach: nil))
        #expect(packs.precision == "measured", "counting is exact")
    }

    @Test("grams convert to whole pieces, not fractions")
    func gramsToPieces() throws {
        let wings = try #require(Consumption.requirement(
            recipeQuantity: 200, recipeUnit: "g", baseUnit: "count", gramsEach: 99.2))
        #expect(wings.amount == 2)
    }

    /// Rounding to zero would remove nothing from the ledger while the food had
    /// in fact been used.
    @Test("a small requirement still takes one whole piece")
    func neverRoundsToZero() throws {
        let crumb = try #require(Consumption.requirement(
            recipeQuantity: 10, recipeUnit: "g", baseUnit: "count", gramsEach: 99.2))
        #expect(crumb.amount == 1)
    }

    @Test("pieces convert up into grams")
    func piecesToGrams() throws {
        let sliced = try #require(Consumption.requirement(
            recipeQuantity: 3, recipeUnit: "count", baseUnit: "g", gramsEach: 50))
        #expect(sliced.amount == 150)
    }

    @Test("an unbridgeable requirement is refused rather than guessed")
    func refusals() {
        #expect(Consumption.requirement(
            recipeQuantity: 200, recipeUnit: "g", baseUnit: "count", gramsEach: nil) == nil,
            "no piece weight means no requirement")
        #expect(Consumption.requirement(
            recipeQuantity: 1, recipeUnit: "ml", baseUnit: "count", gramsEach: 50) == nil,
            "ml into count is refused — density is not the same as piece weight")
    }
}
