//
//  AccentPalette.swift
//  Conduit
//
//  The selectable accent palettes: one accent (dark + light) plus the fill of
//  the user's own message bubble. They travel together because they are bound
//  by opposite rules — see the contrast contract below.
//

import SwiftUI
import UIKit

/// One user-selectable palette. Device-local preference (`@AppStorage`), the
/// same lifetime rule as `ChatTextSize`: never part of the Hermes profile.
///
/// **Contrast contract** (WCAG AA, and the reason the old amber failed):
/// - bubble text is WHITE, so both bubble stops need ≥ 4.5:1 against white;
/// - the dark accent is used as *text* on the dark backdrop, so ≥ 4.5:1 there;
/// - white icons sit ON the accent, so ≥ 3:1 against it;
/// - the light accent backs white text (≥ 4.5:1) and reads as text on the
///   light backdrop (≥ 4.5:1).
/// One colour cannot satisfy "light enough to read on dark" and "dark enough
/// for white text" at once, which is exactly why the accent and the bubble are
/// separate fields here. `AccentPaletteTests` enforces every rule for every
/// palette in `allCases`, computed from these same values.
enum AccentPalette: String, CaseIterable, Identifiable {
    case azul, teal, violeta, coral, gris

    /// UserDefaults key. `@AppStorage` in `MainView` reads it too, so a change
    /// re-renders the whole tree and the live colour providers resolve anew.
    static let preferenceKey = "conduit.accentPalette"
    static let defaultPalette: AccentPalette = .azul

    var id: String { rawValue }

    var title: String {
        switch self {
        case .azul: return AppLocalization.string("Blue")
        case .teal: return AppLocalization.string("Teal")
        case .violeta: return AppLocalization.string("Violet")
        case .coral: return AppLocalization.string("Coral")
        case .gris: return AppLocalization.string("Gray")
        }
    }

    // MARK: Palette values (sRGB hex)

    /// Accent, dark interface (also the text/tint colour on the dark backdrop).
    var accentDarkHex: String {
        switch self {
        case .azul: return "#4B84F0"
        case .teal: return "#189E84"
        case .violeta: return "#9D80F2"
        case .coral: return "#E1533A"
        case .gris: return "#8E95A1"
        }
    }

    /// Accent, light interface (backs white text, so it stays dark).
    var accentLightHex: String {
        switch self {
        case .azul: return "#2C56C4"
        case .teal: return "#0F7A66"
        case .violeta: return "#6A45C9"
        case .coral: return "#B94429"
        case .gris: return "#5A616B"
        }
    }

    /// Decorative soft accent (sweeps, glows) — no contrast duty.
    var accentSoftDarkHex: String {
        switch self {
        case .azul: return "#A3C4FB"
        case .teal: return "#6FD3BC"
        case .violeta: return "#C3B0FB"
        case .coral: return "#F6A08D"
        case .gris: return "#C3C8D1"
        }
    }

    var accentSoftLightHex: String {
        switch self {
        case .azul: return "#5E86E8"
        case .teal: return "#2A9C84"
        case .violeta: return "#7E5FDC"
        case .coral: return "#C9553D"
        case .gris: return "#6E757E"
        }
    }

    /// User-bubble fill, top-leading → bottom-trailing. Same in both
    /// interfaces: white text needs its 4.5:1 in both.
    var bubbleTopHex: String {
        switch self {
        case .azul: return "#2C56C4"
        case .teal: return "#12806B"
        case .violeta: return "#6A45C9"
        case .coral: return "#C9482E"
        case .gris: return "#565C68"
        }
    }

    var bubbleBottomHex: String {
        switch self {
        case .azul: return "#1E3F94"
        case .teal: return "#0B5C4E"
        case .violeta: return "#4E32A0"
        case .coral: return "#9B3722"
        case .gris: return "#3E434D"
        }
    }

    // MARK: Selection (device-local)

    private static let lock = NSLock()
    private static var _current: AccentPalette?

    /// The palette in force. Reads the stored preference once and keeps it in
    /// memory: colour providers call this during rendering, often per frame.
    static var current: AccentPalette {
        lock.lock()
        defer { lock.unlock() }
        if let _current { return _current }
        let stored = fromStored(UserDefaults.standard.string(forKey: preferenceKey))
        _current = stored
        return stored
    }

    /// A stored raw value that this build does not recognise (older app, typo,
    /// migrated preference) resolves to the default instead of going dark.
    static func fromStored(_ raw: String?) -> AccentPalette {
        raw.flatMap(AccentPalette.init) ?? defaultPalette
    }

    /// Applies a palette immediately (memory + UserDefaults). The `@AppStorage`
    /// observation in `MainView` re-renders the tree, so the change is visible
    /// on the spot — no rebuild, no relaunch.
    static func select(_ palette: AccentPalette) {
        lock.lock()
        _current = palette
        lock.unlock()
        UserDefaults.standard.set(palette.rawValue, forKey: preferenceKey)
    }

    // MARK: Colours handed to SwiftUI

    /// Dynamic accent: resolves per interface style against the live palette.
    /// One set of UIColors per palette, built exactly once. SwiftUI compares a
    /// `Color(uiColor:)` by the object it wraps: a colour that has to CHANGE
    /// must become a *different* object when the setting changes, and stay the
    /// *same* object otherwise or every render churns. A `static let` dynamic
    /// provider fails both halves — the object never changes even though its
    /// output does — which is why the first AMOLED toggle rendered nothing
    /// (measured 2026-09-24). Cache per palette and the contract holds.
    struct PaletteColors {
        let accent: UIColor
        let accentSoft: UIColor
        let bubbleTop: UIColor
        let bubbleBottom: UIColor
        /// The same `Color` struct on every render. Building a fresh
        /// `Color(uiColor:)` per access mints a value SwiftUI may treat as
        /// changed on every pass — extra attribute work in the middle of a
        /// scrolling transcript, which is where stutter shows up. Built once
        /// per palette: identical while the selection stands, different when
        /// it changes, which is the repaint contract the tests pin.
        let accentColor: Color
        let accentSoftColor: Color
        let bubbleTopColor: Color
        let bubbleBottomColor: Color
    }

    private static let colorsLock = NSLock()
    private static var colorsCache: [AccentPalette: PaletteColors] = [:]

    var colors: PaletteColors {
        AccentPalette.colorsLock.lock()
        defer { AccentPalette.colorsLock.unlock() }
        if let cached = AccentPalette.colorsCache[self] { return cached }
        // Dynamic: the two accents adapt dark/light within one palette.
        let accent = UIColor { traits in
            Self.uiColor(traits.userInterfaceStyle == .dark ? accentDarkHex : accentLightHex)
        }
        let accentSoft = UIColor { traits in
            Self.uiColor(traits.userInterfaceStyle == .dark ? accentSoftDarkHex : accentSoftLightHex)
        }
        let bubbleTop = Self.uiColor(bubbleTopHex)
        let bubbleBottom = Self.uiColor(bubbleBottomHex)
        let built = PaletteColors(
            accent: accent,
            accentSoft: accentSoft,
            bubbleTop: bubbleTop,
            bubbleBottom: bubbleBottom,
            accentColor: Color(uiColor: accent),
            accentSoftColor: Color(uiColor: accentSoft),
            bubbleTopColor: Color(uiColor: bubbleTop),
            bubbleBottomColor: Color(uiColor: bubbleBottom)
        )
        AccentPalette.colorsCache[self] = built
        return built
    }

    var accentUIColor: UIColor { colors.accent }
    var accentSoftUIColor: UIColor { colors.accentSoft }
    var bubbleTopUIColor: UIColor { colors.bubbleTop }
    var bubbleBottomUIColor: UIColor { colors.bubbleBottom }

    static func uiColor(_ hex: String) -> UIColor {
        let digits = hex.dropFirst()
        guard hex.hasPrefix("#"), digits.count == 6,
              let value = UInt32(digits, radix: 16) else { return .clear }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: Measurement — the single source of truth for the UI and the tests

    /// Contrasts this palette is required to meet, computed from the app's own
    /// surfaces (backdrop hexes come from `ConduitBackdrop`).
    struct Measurement {
        let bubbleTopOverWhite: Double
        let bubbleBottomOverWhite: Double
        let accentDarkOnDarkBackdrop: Double
        let whiteIconOnAccentDark: Double
        let accentLightOverWhite: Double
        let accentLightOnLightBackdrop: Double
    }

    var measurement: Measurement {
        Measurement(
            bubbleTopOverWhite: Self.contrast(Self.uiColor(bubbleTopHex), Self.white),
            bubbleBottomOverWhite: Self.contrast(Self.uiColor(bubbleBottomHex), Self.white),
            accentDarkOnDarkBackdrop: Self.contrast(Self.uiColor(accentDarkHex), Self.darkBackdrop),
            whiteIconOnAccentDark: Self.contrast(Self.white, Self.uiColor(accentDarkHex)),
            accentLightOverWhite: Self.contrast(Self.uiColor(accentLightHex), Self.white),
            accentLightOnLightBackdrop: Self.contrast(Self.uiColor(accentLightHex), Self.lightBackdrop)
        )
    }

    private static let white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    /// `ConduitBackdrop.base`, dark / light.
    private static let darkBackdrop = UIColor(red: 0.045, green: 0.052, blue: 0.072, alpha: 1)
    private static let lightBackdrop = UIColor(red: 0.94, green: 0.95, blue: 0.98, alpha: 1)

    /// WCAG 2.1 contrast ratio between two sRGB colours.
    static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func relativeLuminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
