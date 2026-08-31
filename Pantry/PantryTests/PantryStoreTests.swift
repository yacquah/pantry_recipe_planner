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
