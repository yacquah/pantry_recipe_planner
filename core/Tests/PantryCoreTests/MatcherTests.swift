import Testing
import PantryCore

@Suite("Ingredient verdicts — ADR 004")
struct IngredientVerdictTests {

    @Test("same unit on both sides needs no bridge at all")
    func sameUnit() {
        #expect(Matcher.judge(need: 400, needUnit: "g", baseUnit: "g",
                              have: 5275, unknownEvents: 0,
                              gramsEach: nil, bridge: nil).0 == .have)

        #expect(Matcher.judge(need: 6000, needUnit: "g", baseUnit: "g",
                              have: 5275, unknownEvents: 0,
                              gramsEach: nil, bridge: nil).0 == .short)
    }

    /// Basmati rice: the bag size was never recorded. Answering "no" here would
    /// be a confident claim derived from an absence of data.
    @Test("an unknown quantity is not zero, and says why")
    func unknownQuantity() {
        let verdict = Matcher.judge(need: 250, needUnit: "g", baseUnit: "g",
                                    have: nil, unknownEvents: 1,
                                    gramsEach: nil, bridge: nil)
        #expect(verdict.0 == .cannotTell)
        #expect(verdict.1 == "quantity unknown")
    }

    /// One unknown event poisons an otherwise known total rather than being
    /// quietly dropped from the sum (modelling rule 4).
    @Test("a partial unknown is still unknown")
    func partialUnknown() {
        #expect(Matcher.judge(need: 100, needUnit: "g", baseUnit: "g",
                              have: 500, unknownEvents: 1,
                              gramsEach: nil, bridge: nil).0 == .cannotTell)
    }

    /// The Lipton box: identity known, unit unknown (ADR 002).
    @Test("no base unit means no comparison")
    func noBaseUnit() {
        #expect(Matcher.judge(need: 1, needUnit: "count", baseUnit: nil,
                              have: nil, unknownEvents: 1,
                              gramsEach: nil, bridge: nil).0 == .cannotTell)
    }

    @Test("a missing bridge gives no answer, and names what is missing")
    func missingBridge() throws {
        let verdict = Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                                    have: 10, unknownEvents: 0,
                                    gramsEach: nil, bridge: nil)
        #expect(verdict.0 == .cannotTell)
        let reason = try #require(verdict.1, "a refusal must explain itself")
        #expect(reason.contains("no piece weight"))
    }

    /// Aggregating up over the same set that was weighed is lossless: 10 wings
    /// weighed at 992 g rebuilds a total that really did go on the scale. A
    /// printed pack weight is exact for the same reason — no spread to hedge.
    @Test("an exact bridge supports a confident answer",
          arguments: [(99.2, BridgeSource.measured), (85.0, BridgeSource.printed)])
    func exactBridge(gramsEach: Double, bridge: BridgeSource) {
        #expect(Matcher.judge(need: 200, needUnit: "g", baseUnit: "count",
                              have: 10, unknownEvents: 0,
                              gramsEach: gramsEach, bridge: bridge).0 == .have)
    }

    /// A reference average is approximate in BOTH directions. The short case
    /// matters most: a firm "no" from an approximate bridge is the failure that
    /// quietly kills the feature, because you cook something else and the food
    /// rots anyway.
    @Test("a reference average always hedges, and never says no",
          arguments: [(200.0, IngredientStatus.probably), (900.0, IngredientStatus.probablyShort)])
    func referenceHedges(need: Double, expected: IngredientStatus) {
        #expect(Matcher.judge(need: need, needUnit: "g", baseUnit: "count",
                              have: 4, unknownEvents: 0,
                              gramsEach: 150, bridge: .reference).0 == expected)
    }

    /// Knowing ten wings weigh 992 g says nothing certain about any single
    /// wing, so "2 wings" gets a hedge even though the same data answered a
    /// grams question confidently above.
    @Test("dividing down stays approximate even when measured")
    func dividingDown() {
        #expect(Matcher.judge(need: 2, needUnit: "count", baseUnit: "g",
                              have: 992, unknownEvents: 0,
                              gramsEach: 99.2, bridge: .measured).0 == .probably)
    }
}

@Suite("Recipe verdicts")
struct RecipeVerdicts {

    @Test("all confirmed is a yes")
    func allConfirmed() {
        #expect(Matcher.combine([.have, .have]) == .yes)
    }

    @Test("an exact shortfall outranks everything else")
    func shortfallWins() {
        #expect(Matcher.combine([.have, .short, .cannotTell]) == .no)
    }

    @Test("an unknown outranks a hedge")
    func unknownOutranksHedge() {
        #expect(Matcher.combine([.have, .probably, .cannotTell]) == .cannotTell)
    }

    @Test("a probable shortfall is only worth a check")
    func probableShortfall() {
        #expect(Matcher.combine([.have, .probablyShort]) == .probably)
    }
}
