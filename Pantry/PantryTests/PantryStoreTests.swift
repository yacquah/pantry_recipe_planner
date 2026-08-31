import Testing
import Foundation
import PantryCore
@testable import Pantry

/// What the app's own layer does, as opposed to what PantryCore decides.
///
/// The rules are checked in the package, without a simulator. These check the
/// thin part on top: that the store opens a database, migrates it, turns
/// results into the shape the screens read, and never blocks a capture.
@MainActor
@Suite("PantryStore")
struct PantryStoreTests {

    /// A store pointed at a throwaway file, with notifications off.
    ///
    /// Both matter. Without the injected path this runs against the real
    /// pantry in Application Support; with notifications on, the first
    /// scheduled alert trips a system permission alert and the test hangs.
    private func withStore(_ body: (PantryStore) throws -> Void) rethrows {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-test-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = PantryStore(databaseURL: url, schedulesNotifications: false)
        store.start()
        try body(store)
    }

    @Test("a fresh install migrates cleanly and reports itself empty")
    func freshInstall() {
        withStore { store in
            #expect(store.errorMessage == nil, "migration should not fail on a new file")
            #expect(store.isEmpty)
            #expect(store.stock.isEmpty)
            #expect(store.recipes.isEmpty)
        }
    }

    @Test("importing the starter inventory fills every screen's data")
    func starterImport() {
        withStore { store in
            store.importStarterInventory()

            #expect(store.errorMessage == nil)
            #expect(store.isEmpty == false)
            #expect(store.stock.count == 11, "the eleven hand-collected items")
            #expect(store.recipes.count == 4)
            #expect(store.alerts.count == 1, "only the frozen wings may interrupt anyone")
        }
    }

    /// The two rows the whole schema was designed around: a box nobody can
    /// identify, and a bag whose size was never written down.
    @Test("the two unanswerable rows surface as questions, not as zeroes")
    func needsAttention() {
        withStore { store in
            store.importStarterInventory()

            let names = Set(store.needsAttention.map(\.name))
            #expect(names.contains("UNRESOLVED - Lipton box"))
            #expect(names.contains("Basmati rice"))
            #expect(store.needsAttention.count == 2)

            // And none of them are pretending to be empty.
            #expect(store.needsAttention.allSatisfy { $0.balance == nil })
        }
    }

    /// A well-stocked kitchen has nothing running out. The section should be
    /// empty rather than showing whatever happens to be lowest.
    @Test("nothing is running low in a freshly imported pantry")
    func nothingRunningLow() {
        withStore { store in
            store.importStarterInventory()
            #expect(store.runningLow.isEmpty)
        }
    }

    /// ADR 002: identity matters most, quantity can always be improved later,
    /// and capture is never blocked.
    @Test("an item with nothing but a name still lands")
    func captureIsNeverBlocked() {
        withStore { store in
            store.capture(CaptureRequest(verbatim: "some lentils", name: "Red lentils"))

            #expect(store.errorMessage == nil)
            let lentils = store.stock.first { $0.name == "Red lentils" }
            let found = try? #require(lentils)
            #expect(found?.balance == nil, "no quantity was given, so none is invented")
            #expect(found?.needsAttention == true, "it asks to be completed later")
        }
    }

    @Test("a fully specified capture lands with its quantity intact")
    func captureWithQuantity() throws {
        try withStore { store in
            store.capture(CaptureRequest(
                verbatim: "2.5 kg jasmine rice",
                name: "Jasmine rice",
                baseUnit: "g",
                shelfLifeClass: "ambient_stable",
                quantity: 2500,
                precision: "measured"
            ))

            #expect(store.errorMessage == nil)
            let rice = try #require(store.stock.first { $0.name == "Jasmine rice" })
            #expect(rice.balance == 2500)
            #expect(rice.baseUnit == "g")
            #expect(rice.needsAttention == false)
        }
    }

    // MARK: - Food leaving

    @Test("eating from a lot takes it off the balance")
    func eating() throws {
        try withStore { store in
            store.importStarterInventory()
            let before = try #require(store.stock.first { $0.name == "Jasmine rice" })
            let had = try #require(before.balance)

            store.eat(lot: before.lotId, quantity: 275, precision: "measured")

            #expect(store.errorMessage == nil)
            let after = try #require(store.stock.first { $0.lotId == before.lotId })
            #expect(after.balance == had - 275)
        }
    }

    @Test("throwing something out records the cause, not just the loss")
    func wasting() throws {
        try withStore { store in
            store.importStarterInventory()
            let before = try #require(store.stock.first { $0.name == "Tomato paste" })
            let had = try #require(before.balance)

            store.waste(lot: before.lotId, quantity: 60,
                        reason: "spoiled", precision: "estimated")

            #expect(store.errorMessage == nil)
            let after = try #require(store.stock.first { $0.lotId == before.lotId })
            #expect(after.balance == had - 60)
        }
    }

    /// ADR 005: a recount is a checkpoint, not another delta. The number you
    /// can see replaces the running total outright.
    @Test("a recount replaces the balance rather than adjusting it")
    func recounting() throws {
        try withStore { store in
            store.importStarterInventory()
            let before = try #require(store.stock.first { $0.name == "Honey" })
            #expect(before.balance == 340)

            store.recount(lot: before.lotId, observed: 120, precision: "measured")

            let after = try #require(store.stock.first { $0.lotId == before.lotId })
            #expect(after.balance == 120, "what the eyes saw, not 340 minus anything")
        }
    }

    /// The whole point of the consumption UI: quantities can now go down, so
    /// "running low" is reachable instead of theoretical.
    @Test("eating enough makes something show as running low")
    func runningLowBecomesReachable() throws {
        try withStore { store in
            store.importStarterInventory()
            #expect(store.runningLow.isEmpty, "a freshly imported pantry is full")

            let rice = try #require(store.stock.first { $0.name == "Jasmine rice" })
            let had = try #require(rice.balance)
            store.eat(lot: rice.lotId, quantity: had * 0.8, precision: "estimated")

            #expect(store.runningLow.contains { $0.lotId == rice.lotId },
                    "a fifth of a bag left is running low")
        }
    }

    @Test("cooking a recipe draws from every lot it needs")
    func cooking() throws {
        try withStore { store in
            store.importStarterInventory()
            let plan = try #require(store.plan(forRecipe: "Jollof-ish rice"))
            #expect(plan.isSatisfiable)
            #expect(plan.draws.count == 2)

            let before = Dictionary(
                uniqueKeysWithValues: store.stock.map { ($0.lotId, $0.balance) })

            store.cook(plan)
            #expect(store.errorMessage == nil)

            for draw in plan.draws {
                let had = try #require(before[draw.lotId] ?? nil)
                let now = try #require(store.stock.first { $0.lotId == draw.lotId }?.balance)
                #expect(now == had - draw.amount, "\(draw.productName) came off the shelf")
            }
        }
    }

    /// ADR 003: the recipe's amount is a default, not a decision. A number
    /// somebody typed is worth more than one the recipe assumed, and the
    /// precision has to say so.
    @Test("an edited cook amount is written, and recorded as measured")
    func editedCookAmount() throws {
        try withStore { store in
            store.importStarterInventory()
            let plan = try #require(store.plan(forRecipe: "Jollof-ish rice"))
            let draw = try #require(plan.draws.first { $0.unit == "g" })
            let had = try #require(store.stock.first { $0.lotId == draw.lotId }?.balance)

            let amended = plan.amending(lotId: draw.lotId, to: draw.amount + 100)
            let edited = try #require(amended.draws.first { $0.lotId == draw.lotId })
            #expect(edited.amount == draw.amount + 100)
            #expect(edited.precision == "measured", "somebody looked, so it is not derived")

            store.cook(amended)
            let now = try #require(store.stock.first { $0.lotId == draw.lotId }?.balance)
            #expect(now == had - (draw.amount + 100))
        }
    }

    /// Editing an amount must not talk the app out of a problem it found.
    @Test("amending a plan leaves its problems intact")
    func amendingKeepsProblems() throws {
        try withStore { store in
            store.importStarterInventory()
            let plan = try #require(store.plan(forRecipe: "Basmati side"))
            #expect(plan.isSatisfiable == false, "the basmati quantity is unknown")

            let amended = plan.amending(lotId: plan.draws.first?.lotId ?? 0, to: 1)
            #expect(amended.isSatisfiable == false, "typing a number does not create rice")
        }
    }

    @Test("importing twice is refused rather than doubling the ledger")
    func doubleImportRefused() {
        withStore { store in
            store.importStarterInventory()
            store.importStarterInventory()

            #expect(store.stock.count == 11, "still eleven, not twenty-two")
            #expect(store.errorMessage != nil, "and it says why rather than failing silently")
        }
    }
}
