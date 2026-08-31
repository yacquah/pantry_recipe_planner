import XCTest

/// The things only a running app can prove: that the three tabs exist, that
/// they switch, and that each one puts its own screen on the display.
///
/// Deliberately shallow. What each screen *says* is decided in PantryCore and
/// checked there in milliseconds; driving the simulator to re-check a rule
/// would be the slowest possible way to learn something already known. These
/// check the wiring, which nothing else can.
final class PantryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTheThreeTabsExist() throws {
        let app = XCUIApplication()
        app.launch()

        for tab in ["Pantry", "Cook", "Add"] {
            XCTAssertTrue(
                app.tabBars.buttons[tab].waitForExistence(timeout: 5),
                "the \(tab) tab should be reachable"
            )
        }
    }

    @MainActor
    func testEachTabShowsItsOwnScreen() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Pantry"].waitForExistence(timeout: 5),
                      "the app opens on the pantry")

        app.tabBars.buttons["Cook"].tap()
        XCTAssertTrue(app.navigationBars["Cook tonight"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Pantry"].tap()
        XCTAssertTrue(app.navigationBars["Pantry"].waitForExistence(timeout: 5),
                      "and going back returns to it")
    }

    /// Manual entry has to be reachable and dismissable. It is the only way to
    /// put food in from the phone, so a sheet that cannot be opened or closed
    /// is a broken app however correct the engine underneath is.
    @MainActor
    func testManualCaptureOpensAndCloses() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Add"].tap()
        app.buttons["Enter by hand"].tap()

        XCTAssertTrue(app.navigationBars["Enter by hand"].waitForExistence(timeout: 5))

        // Save stays disabled until there is a name, because identity is the
        // one thing a capture cannot go without (ADR 002).
        XCTAssertFalse(app.buttons["Save"].isEnabled,
                       "an unnamed item cannot be saved")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add"].waitForExistence(timeout: 5))
    }
}
