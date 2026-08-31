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

    /// Launches with the starter inventory present, whichever state the
    /// simulator's container was left in by an earlier test.
    @MainActor
    private func launchWithData() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let importButton = app.buttons["Import starter inventory"]
        if importButton.waitForExistence(timeout: 3) {
            importButton.tap()
        }
        return app
    }

    /// Scrolls until a named row is actually on screen.
    ///
    /// `waitForExistence` is satisfied by an element that exists off the
    /// bottom of a list, and swiping one of those does nothing at all — which
    /// looks exactly like a broken swipe gesture.
    @MainActor
    private func row(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells.containing(.staticText, identifier: label).firstMatch
        for _ in 0..<10 where !(cell.exists && cell.isHittable) {
            app.swipeUp()
        }
        return cell
    }

    /// Eating, binning and recounting are the gestures that close the loop —
    /// without them food goes into the ledger and never comes out. They live
    /// on a swipe, so a swipe that stops working breaks the app's purpose
    /// while every screen still renders perfectly.
    @MainActor
    func testSwipingALotOffersTheLedgerActions() throws {
        let app = launchWithData()

        let honey = row("Honey", in: app)
        XCTAssertTrue(honey.exists, "the pantry should list Honey")
        honey.swipeLeft()

        XCTAssertTrue(app.buttons["Ate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Threw out"].exists)
        XCTAssertTrue(app.buttons["Recount"].exists)
    }

    @MainActor
    func testRecordingThatSomethingWasEaten() throws {
        let app = launchWithData()

        let honey = row("Honey", in: app)
        XCTAssertTrue(honey.exists)
        honey.swipeLeft()
        XCTAssertTrue(app.buttons["Ate"].waitForExistence(timeout: 5))
        app.buttons["Ate"].tap()

        XCTAssertTrue(app.navigationBars["Ate some"].waitForExistence(timeout: 5))

        // Nothing can be saved until there is a number: an amount is the one
        // thing this event cannot be recorded without.
        XCTAssertFalse(app.buttons["Save"].isEnabled)

        app.textFields["Amount"].tap()
        app.textFields["Amount"].typeText("20")
        XCTAssertTrue(app.buttons["Save"].isEnabled)

        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Pantry"].waitForExistence(timeout: 5),
                      "the sheet closes and returns to the pantry")
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
