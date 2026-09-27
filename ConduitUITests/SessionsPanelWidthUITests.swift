//
//  SessionsPanelWidthUITests.swift
//  ConduitUITests
//
//  The sessions panel must open as a SIDE BAR — a card hanging at the
//  leading edge, capped at SessionsPanel.panelWidth (356 pt) — and never
//  as a full-screen card. The cap is ONE .frame(maxWidth:) line in
//  MainView's overlay, and build 164 shipped without it: the overlay
//  proposes the whole screen and the card filled it (reported by Gerardo
//  as "el morph ocupa toda la pantalla"). This test measures the rendered
//  element so that line cannot vanish again without a red test.
//
//  UI tests cannot import the app module, so the numbers are pinned here
//  with their source: panelWidth = 356 (see SessionsPanel.panelWidth).
//

import XCTest

final class SessionsPanelWidthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Opens the panel from the conversation pill and measures the card
    /// once the bubble→card morph settles: it must be the side bar, not
    /// the window.
    func testPanelOpensAsASideBarAndNotFullScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example"
        ]
        app.launch()

        let pill = app.buttons["open.sessions"]
        XCTAssertTrue(
            pill.waitForExistence(timeout: 10),
            "Conversation pill missing — the shell did not appear. Tree:\n\(app.debugDescription)"
        )
        pill.tap()

        let panel = app.otherElements["sessions.panel"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 5),
            "Panel did not open. Tree:\n\(app.debugDescription)"
        )

        // The morph animates the frame from the pill to the card
        // (ConduitMotion.transition ≈ 0.34 s spring): wait until the
        // measured width stops changing instead of a fixed sleep, so a
        // slow CI machine cannot measure mid-flight.
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
        // The side bar: exactly panelWidth (356), hanging 12 from the
        // leading edge. A full-screen card on this iPad (~1210 pt) fails
        // the cap by ~850 pt — that is the build-164 regression.
        XCTAssertGreaterThan(
            frame.width, 200,
            "Panel collapsed below the drawer's content width. Frame: \(frame)"
        )
        XCTAssertLessThanOrEqual(
            frame.width, 360,
            "Panel must be the side bar (356 pt), not the window — the "
                + "MainView cap is missing. Frame: \(frame)"
        )
        XCTAssertLessThanOrEqual(
            frame.minX, 20,
            "Panel must hang at the leading edge. Frame: \(frame)"
        )
    }
}
