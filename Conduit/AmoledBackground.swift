//
//  AmoledBackground.swift
//  Conduit
//
//  True-black (AMOLED) dark background: pure #000000 instead of #0B0D12.
//

import SwiftUI
import UIKit

/// The dark background Gerardo asked for: pure black, the AMOLED look, with
/// white text at its maximum (21:1 — the usual #0B0D12 backdrop already gives
/// 19.4:1, so the win is the true black itself, not a text change: secondary
/// text still measures 7.4:1 and tertiary 5.4:1 on pure black).
///
/// Device-local preference, same lifetime rule as `ChatTextSize`. Only the
/// DARK side of each surface changes; light mode is untouched.
///
/// Going to #000000 does not weaken any contrast rule — surfaces get *more*
/// separated from the backdrop (the Hermes bubble goes from 1.12:1 to
/// 1.21:1), which is why `AccentPalette` keeps measuring against #0B0D12:
/// that is the stricter backdrop of the two.
enum AmoledBackground {
    static let preferenceKey = "conduit.amoledBackground"

    private static let lock = NSLock()
    private static var _enabled: Bool?

    /// Current state, cached like `AccentPalette.current` (colour providers
    /// call this during rendering).
    static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let _enabled { return _enabled }
        let stored = UserDefaults.standard.bool(forKey: preferenceKey)
        _enabled = stored
        return stored
    }

    /// Flips the background live: `MainView` observes `preferenceKey` through
    /// `@AppStorage`, so the whole tree re-renders and every provider below
    /// resolves again. No rebuild, no relaunch.
    static func set(_ enabled: Bool) {
        lock.lock()
        _enabled = enabled
        lock.unlock()
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
    }

    /// Test seam: drop the in-memory cache so the next read goes back to
    /// UserDefaults (tests that assert the fresh-install default need this —
    /// `set` always writes the key, so absence cannot be proven with the
    /// cache warm).
    static func forgetCachedValue() {
        lock.lock()
        _enabled = nil
        lock.unlock()
    }

    /// The two stable objects per state. A `static let` dynamic provider
    /// would keep the SAME object while its output changes, and SwiftUI
    /// compares `Color(uiColor:)` by the wrapped object — the repaint never
    /// happens (that is exactly how build 150 rendered nothing). Two fixed
    /// instances per state give a value that changes when the flag does and
    /// stays identical otherwise.
    private static let blackBackdrop = UIColor.black
    private static let dimBackdrop = UIColor(red: 0.045, green: 0.052, blue: 0.072, alpha: 1)
    private static let blackSurface = UIColor.black
    private static let dimSurface = UIColor(red: 0.072, green: 0.080, blue: 0.106, alpha: 1)

    /// Chat backdrop for the dark scheme (`ConduitBackdrop.base`).
    static var darkBackdropUIColor: UIColor { isEnabled ? blackBackdrop : dimBackdrop }

    /// Composer and picker-section foundation in dark mode. Their strokes
    /// (white at 0.14) keep them visible against a pure black backdrop.
    static var darkSurfaceUIColor: UIColor { isEnabled ? blackSurface : dimSurface }
}
