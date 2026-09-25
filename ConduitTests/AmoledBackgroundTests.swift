import XCTest
import SwiftUI
@testable import Conduit

/// The AMOLED background contract: pure black when enabled, the usual
/// `#0B0D12` when not, both in the backdrop and in the two dark surfaces
/// (composer and picker sections), and white text keeps AA contrast on either.
final class AmoledBackgroundTests: XCTestCase {

    private func components(_ color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    /// The providers are dynamic; resolve them the way the dark interface does.
    private func darkResolved(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    private func assertComponents(
        _ color: UIColor,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        accuracy: CGFloat = 0.001,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = components(color)
        XCTAssertEqual(value.red, red, accuracy: accuracy, "\(message) — red", file: file, line: line)
        XCTAssertEqual(value.green, green, accuracy: accuracy, "\(message) — green", file: file, line: line)
        XCTAssertEqual(value.blue, blue, accuracy: accuracy, "\(message) — blue", file: file, line: line)
    }

    /// A fresh install shows the normal backdrop: no stored value reads as
    /// off. Order-independent — every test that writes the preference restores
    /// it and drops the cache first.
    func testAbsentStoredValueReadsAsOff() {
        let stored = UserDefaults.standard.object(forKey: AmoledBackground.preferenceKey)
        defer {
            if let stored {
                UserDefaults.standard.set(stored, forKey: AmoledBackground.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AmoledBackground.preferenceKey)
            }
            AmoledBackground.forgetCachedValue()
        }

        UserDefaults.standard.removeObject(forKey: AmoledBackground.preferenceKey)
        AmoledBackground.forgetCachedValue()

        XCTAssertFalse(
            AmoledBackground.isEnabled,
            "with nothing stored the app must start on the usual backdrop, never on pure black"
        )
    }

    func testEnablingGoesPureBlackAndDisablingRestoresTheBackdrop() {
        let original = AmoledBackground.isEnabled
        defer { AmoledBackground.set(original) }

        AmoledBackground.set(true)
        XCTAssertTrue(AmoledBackground.isEnabled)
        XCTAssertEqual(
            UserDefaults.standard.bool(forKey: AmoledBackground.preferenceKey),
            true
        )
        assertComponents(
            darkResolved(AmoledBackground.darkBackdropUIColor),
            red: 0, green: 0, blue: 0,
            "enabled backdrop must be pure black"
        )
        assertComponents(
            darkResolved(AmoledBackground.darkSurfaceUIColor),
            red: 0, green: 0, blue: 0,
            "enabled surfaces must be pure black"
        )

        AmoledBackground.set(false)
        XCTAssertFalse(AmoledBackground.isEnabled)
        assertComponents(
            darkResolved(AmoledBackground.darkBackdropUIColor),
            red: 0.045, green: 0.052, blue: 0.072,
            "disabled backdrop must return to #0B0D12"
        )
        assertComponents(
            darkResolved(AmoledBackground.darkSurfaceUIColor),
            red: 0.072, green: 0.080, blue: 0.106,
            "disabled surfaces must return to #12141B"
        )
    }

    /// The point of the mode: white text at its maximum, and every text role
    /// still comfortably above AA on pure black.
    func testTextKeepsAAContrastOnBothBackdrops() {
        let white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let secondaryOnBlack = UIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        let tertiaryOnBlack = UIColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 1)
        let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let dimBackdrop = UIColor(red: 0.045, green: 0.052, blue: 0.072, alpha: 1)

        XCTAssertGreaterThanOrEqual(AccentPalette.contrast(white, black), 4.5, "white on pure black")
        XCTAssertGreaterThanOrEqual(AccentPalette.contrast(white, dimBackdrop), 4.5, "white on #0B0D12")
        XCTAssertGreaterThanOrEqual(AccentPalette.contrast(secondaryOnBlack, black), 4.5, "secondary text on pure black")
        XCTAssertGreaterThanOrEqual(AccentPalette.contrast(tertiaryOnBlack, black), 4.5, "tertiary text on pure black")
        // Pure black only ever separates surfaces MORE from the backdrop, so
        // the accent contract measured against #0B0D12 stays the strict one.
        XCTAssertGreaterThan(
            AccentPalette.contrast(dimBackdrop, black),
            1.0,
            "the two backdrops are distinct states"
        )
    }

    /// The repaint contract, and the reason build 150 changed nothing:
    /// SwiftUI compares `Color(uiColor:)` by the wrapped object, so the value
    /// the views hold must differ between the two states of the toggle.
    func testColourValueSwiftUISeesChangesWithTheToggle() {
        defer { AmoledBackground.set(false) }

        AmoledBackground.set(false)
        let backdropOff = Color(uiColor: AmoledBackground.darkBackdropUIColor)
        let surfaceOff = Color(uiColor: AmoledBackground.darkSurfaceUIColor)

        AmoledBackground.set(true)
        let backdropOn = Color(uiColor: AmoledBackground.darkBackdropUIColor)
        let surfaceOn = Color(uiColor: AmoledBackground.darkSurfaceUIColor)

        XCTAssertNotEqual(backdropOn, backdropOff, "backdrop value must change with the toggle")
        XCTAssertNotEqual(surfaceOn, surfaceOff, "surface value must change with the toggle")
    }
}
