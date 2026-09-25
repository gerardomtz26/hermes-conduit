import XCTest
@testable import Conduit

/// The colour contract behind the accent picker: every palette the app offers
/// must stay readable on the app's OWN surfaces, computed from the same values
/// the UI renders with (no numbers are duplicated between code and test).
///
/// Rules, and why each exists:
/// - bubble text is WHITE → both bubble stops ≥ 4.5:1 against white. The old
///   amber measured 2.08:1 here, which is why Gerardo's messages were hard to
///   read.
/// - the dark accent is used as TEXT on the dark backdrop → ≥ 4.5:1 there.
/// - white icons sit ON the accent → ≥ 3:1 (WCAG non-text contrast).
/// - the light accent backs white text and reads on the light backdrop →
///   ≥ 4.5:1 against white AND against the light backdrop.
final class AccentPaletteTests: XCTestCase {

    func testEveryPaletteMeetsTheContrastContract() {
        for palette in AccentPalette.allCases {
            let m = palette.measurement
            XCTAssertGreaterThanOrEqual(
                m.bubbleTopOverWhite, 4.5,
                "\(palette.rawValue): user bubble top stop must carry white text"
            )
            XCTAssertGreaterThanOrEqual(
                m.bubbleBottomOverWhite, 4.5,
                "\(palette.rawValue): user bubble bottom stop must carry white text"
            )
            XCTAssertGreaterThanOrEqual(
                m.accentDarkOnDarkBackdrop, 4.5,
                "\(palette.rawValue): accent must read as text on the dark backdrop"
            )
            XCTAssertGreaterThanOrEqual(
                m.whiteIconOnAccentDark, 3.0,
                "\(palette.rawValue): white icons on the accent need 3:1"
            )
            XCTAssertGreaterThanOrEqual(
                m.accentLightOverWhite, 4.5,
                "\(palette.rawValue): light-mode accent must carry white text"
            )
            XCTAssertGreaterThanOrEqual(
                m.accentLightOnLightBackdrop, 4.5,
                "\(palette.rawValue): accent must read as text on the light backdrop"
            )
        }
    }

    /// Your bubble must stay recognisable against Hermes' bubble (`#171A21`
    /// in ChatView), or "which of these is mine" stops working.
    func testBubbleStaysDistinguishableFromTheOtherBubble() {
        let otherBubble = AccentPalette.uiColor("#171A21")
        for palette in AccentPalette.allCases {
            let top = AccentPalette.contrast(AccentPalette.uiColor(palette.bubbleTopHex), otherBubble)
            let bottom = AccentPalette.contrast(AccentPalette.uiColor(palette.bubbleBottomHex), otherBubble)
            XCTAssertGreaterThanOrEqual(top, 1.5, "\(palette.rawValue): bubble top vs Hermes' bubble")
            XCTAssertGreaterThanOrEqual(bottom, 1.5, "\(palette.rawValue): bubble bottom vs Hermes' bubble")
        }
    }

    func testDefaultPaletteIsBlue() {
        XCTAssertEqual(AccentPalette.defaultPalette, .azul)
        XCTAssertEqual(AccentPalette.fromStored(nil), .azul)
    }

    func testUnknownStoredValueFallsBackToTheDefault() {
        XCTAssertEqual(AccentPalette.fromStored("no-existe"), .azul)
        XCTAssertEqual(AccentPalette.fromStored(""), .azul)
        XCTAssertEqual(AccentPalette.fromStored("gris"), .gris)
    }

    /// `select` is what the picker calls: it must be visible to the colour
    /// providers immediately (no relaunch), and the preference must survive
    /// as a raw value another process could read.
    func testSelectAppliesImmediatelyAndPersists() {
        let original = AccentPalette.current
        defer { AccentPalette.select(original) }

        AccentPalette.select(.gris)
        XCTAssertEqual(AccentPalette.current, .gris)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AccentPalette.preferenceKey),
            AccentPalette.gris.rawValue
        )
        XCTAssertEqual(AccentPalette.current.accentDarkHex, "#8E95A1")
    }
}
