//
//  CornerPanelsUITests.swift
//  ConduitUITests
//
//  The model selector and the context ring live in the bar's TRAILING
//  CORNER (moved out of the composer row, build 166) and each opens its
//  content as a dropdown that morphs out of the button: a glass card
//  anchored to the top-right corner, same anatomy as the sessions side
//  bar. These measurements pin the two invariants that could rot
//  silently:
//
//  1. The panel sits in the RIGHT half at the side bar's width (356) —
//     not centered, not full screen (the build-164 class of regression).
//  2. The source button is NOT rendered while its panel is open and
//     comes back when it closes — exactly one of the matched pair, the
//     same contract that once lost a line without a red test.
//
//  UI tests cannot import the app module, so the numbers are pinned
//  here with their source: SessionsPanel.panelWidth = 356.
//

import XCTest

final class CornerPanelsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testModelPanelDropsFromItsCornerButtonAndRestoresIt() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example"
        ]
        app.launch()

        // Both corner buttons exist before the panel opens.
        let pill = app.buttons["open.model"]
        XCTAssertTrue(
            pill.waitForExistence(timeout: 10),
            "Model pill missing — the shell did not appear. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["open.context"].exists, "Context ring missing next to the model pill.")

        pill.tap()

        let panel = app.otherElements["model.panel"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 5),
            "Model panel did not open. Tree:\n\(app.debugDescription)"
        )

        // The source hides while its panel is open (matched pair): poll,
        // because the removal rides the same 0.34 s spring.
        let goneDeadline = Date().addingTimeInterval(3)
        while Date() < goneDeadline, pill.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTAssertFalse(pill.exists, "The model pill must not render while its panel is open.")

        // Let the bubble→card morph settle, then measure (poll, no fixed
        // sleep — same approach as SessionsPanelWidthUITests).
        var lastWidth: CGFloat = -1
        var unchangedPasses = 0
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, unchangedPasses < 3 {
            let width = panel.frame.width
            unchangedPasses = abs(width - lastWidth) < 1 ? unchangedPasses + 1 : 0
            lastWidth = width
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        let frame = panel.frame
        XCTAssertGreaterThan(
            frame.width, 200,
            "Panel collapsed below the content's width. Frame: \(frame)"
        )
        XCTAssertLessThanOrEqual(
            frame.width, 360,
            "Panel must be the 356-pt dropdown, not the window. Frame: \(frame)"
        )
        XCTAssertGreaterThan(
            frame.minX, 400,
            "Panel must hang from the TRAILING corner (right half), not the middle. Frame: \(frame)"
        )

        // Close via the header X: the pair completes — the pill returns.
        let close = app.buttons["Close panel"]
        XCTAssertTrue(
            close.waitForExistence(timeout: 5),
            "Close control missing. Tree:\n\(app.debugDescription)"
        )
        close.tap()
        XCTAssertTrue(
            pill.waitForExistence(timeout: 5),
            "The model pill must return when its panel closes."
        )
    }
}
