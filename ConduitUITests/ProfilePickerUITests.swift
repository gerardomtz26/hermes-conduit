//
//  ProfilePickerUITests.swift
//  ConduitUITests
//
//  Coverage for the profile-selection card (PR #198). The card's visible body
//  selects the profile while its nested controls (choose photo) keep their own
//  actions and must NOT also select — the invariant that decided the card's
//  structure during review.
//
//  Reaching a selectable row needs an active profile plus at least one other
//  discovered profile. A UI test has no transport for `/api/profiles` discovery
//  and the connection-scoped reset clears the persisted known-profile list, so
//  the roster comes from the DEBUG-only `-CONDUIT_UI_TEST_PROFILES` launch
//  argument (see `AppState.uiTestSeededProfiles()`), which seeds through the
//  same `orderedProfiles` a real discovery uses. Any future UI test that needs
//  a multi-profile roster can reuse it through `launchWithSeededProfiles`.
//
//  Both tests seed TWO profiles and act on whichever one is not current, so
//  they do not depend on the active profile a previous run left in the
//  simulator's defaults.
//

import XCTest

final class ProfilePickerUITests: XCTestCase {
    private enum Identity {
        static let connectedDashboard = "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD"
        static let seededProfiles = "-CONDUIT_UI_TEST_PROFILES"
        static let openSidebar = "Open sessions"
        static let workspace = "sidebar.workspace"
        static let pickerTitle = "Profiles"
        static let currentMarker = "Current"
    }

    /// Seeded as a pair so exactly one of them is selectable whatever the
    /// persisted active profile is. `profileDisplayName` uppercases the first
    /// letter, so these are also the display names the UI shows.
    private static let seededProfiles = ["work", "staging"]
    private static let seededDisplayNames = ["Work", "Staging"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Tapping the card body — not the name text and not a control — reaches the
    /// selection path.
    ///
    /// The signal is the switch attempt the app reports. A dismissal alone is
    /// NOT sound here: `select()` dismisses whatever the switch outcome, and a
    /// mutation run showed the picker can also disappear for reasons that have
    /// nothing to do with selection, so a dismissal-only assertion passed with
    /// the card's selection surface removed. Under the connected stub the switch
    /// cannot succeed (no transport), so its attempt surfaces as the reported
    /// failure — the only observable that distinguishes selection from any other
    /// dismissal.
    ///
    /// The active profile is asserted nowhere here: it cannot change without a
    /// transport. Profile discovery and switch bookkeeping are unit-tested in
    /// `ProfileDiscoveryTests` and `YoloProfileSwitchBookkeepingTests`.
    func testTappingTheCardBodyInvokesSelection() throws {
        let app = launchWithSeededProfiles()
        openProfilePicker(app)
        let target = selectableProfileDisplayName(in: app)
        let photoControl = photoControl(for: target, in: app)

        // Control: an empty part of the picker must NOT select, or the signal
        // below would prove nothing about the card.
        let window = app.windows.firstMatch
        tapInWindow(app, at: CGPoint(x: window.frame.midX, y: window.frame.maxY - 40))
        XCTAssertFalse(
            waitForSwitchAttempt(in: app, timeout: 2),
            "An empty area of the picker must not select a profile. Tree:\n\(app.debugDescription)"
        )

        // The probe is the card's trailing accessory column: the row's own
        // select button covers its text column only, so this slot is reached
        // exclusively through the card-sized selection surface behind the row.
        // `x` comes from the current row's marker, which sits in the same slot on
        // every row, and `y` from the selectable row's avatar, so the probe does
        // not depend on the card's reported bounds and lands inside no control.
        let accessorySlot = app.staticTexts[Identity.currentMarker]
        XCTAssertTrue(accessorySlot.waitForExistence(timeout: 5), "No current profile marked. Tree:\n\(app.debugDescription)")
        tapInWindow(app, at: CGPoint(x: accessorySlot.frame.midX, y: photoControl.frame.midY))

        XCTAssertTrue(
            waitForSwitchAttempt(in: app, timeout: 8),
            "Tapping the card body must invoke selection. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            waitForDisappearance(of: app.staticTexts[Identity.pickerTitle], timeout: 5),
            "Selection dismisses the picker. Tree:\n\(app.debugDescription)"
        )
    }

    /// The nested photo control keeps its own action and must not also select the
    /// profile — that would switch and dismiss the picker underneath it.
    func testTappingThePhotoControlDoesNotSelectTheProfile() throws {
        let app = launchWithSeededProfiles()
        openProfilePicker(app)
        let before = app.buttons[Identity.workspace].label
        let target = selectableProfileDisplayName(in: app)

        photoControl(for: target, in: app).tap()

        // Positive control: the nested control's own action ran.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "The photo picker must appear. Tree:\n\(app.debugDescription)")
        cancel.tap()

        // The invariant: nothing selected behind it, so the picker is still
        // presented and the active profile is untouched.
        XCTAssertTrue(
            app.staticTexts[Identity.pickerTitle].waitForExistence(timeout: 5),
            "The profile picker must still be presented. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts[Identity.currentMarker].exists,
            "A current profile must still be marked. Tree:\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.buttons[Identity.workspace].label,
            before,
            "No profile may switch underneath the picker"
        )
    }

    // MARK: - Helpers

    /// Launches the remembered-connected stub with the seeded profile roster.
    /// `profiles` stays optional rather than defaulted to a `Self.` constant: a
    /// covariant `Self` is not allowed in a default-argument expression.
    private func launchWithSeededProfiles(profiles: [String]? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [Identity.connectedDashboard, "https://conduit-ui-test.invalid"]
        app.launchArguments += [Identity.seededProfiles, (profiles ?? Self.seededProfiles).joined(separator: ",")]
        app.launch()
        return app
    }

    private func openProfilePicker(_ app: XCUIApplication) {
        let drawer = app.buttons[Identity.openSidebar]
        XCTAssertTrue(drawer.waitForExistence(timeout: 10), "Main UI did not appear. Tree:\n\(app.debugDescription)")
        drawer.tap()

        let workspace = app.buttons[Identity.workspace]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), "Sidebar did not appear. Tree:\n\(app.debugDescription)")
        workspace.tap()

        XCTAssertTrue(
            app.staticTexts[Identity.pickerTitle].waitForExistence(timeout: 10),
            "Profile picker did not appear. Tree:\n\(app.debugDescription)"
        )
    }

    /// The seeded profile that is not the active one: the card only selects when
    /// the row is selectable, and with two seeds exactly one always is.
    private func selectableProfileDisplayName(in app: XCUIApplication) -> String {
        let active = app.buttons[Identity.workspace].label
        let candidate = Self.seededDisplayNames.first { !active.contains($0) }
        XCTAssertNotNil(candidate, "Expected the header to name the active profile. Saw: \(active)")
        return candidate ?? Self.seededDisplayNames[0]
    }

    /// The nested control that opens the photo picker for a row. Its label is
    /// built from the profile's display name, so it identifies the row without
    /// depending on the row's position.
    private func photoControl(for displayName: String, in app: XCUIApplication) -> XCUIElement {
        let control = app.buttons["Choose photo for \(displayName)"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Photo control for \(displayName) missing. Tree:\n\(app.debugDescription)")
        return control
    }

    /// Taps an absolute point in the app's window — the card's padding has no
    /// element of its own to tap.
    private func tapInWindow(_ app: XCUIApplication, at point: CGPoint) {
        let window = app.windows.firstMatch
        let bounds = window.frame
        XCTAssertTrue(
            point.x > bounds.minX && point.x < bounds.maxX && point.y > bounds.minY && point.y < bounds.maxY,
            "Probe \(point) falls outside the window \(bounds)"
        )
        window
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !element.exists
    }

    /// Whether the app has reported a workspace-switch attempt. Under the
    /// connected stub every attempt fails for lack of a transport, so the
    /// reported failure is the observable that selection ran; the copy asserted
    /// here is only a prefix so a reworded reason does not break the test.
    private func waitForSwitchAttempt(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reported = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Could not switch")
            ).firstMatch
            if reported.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
