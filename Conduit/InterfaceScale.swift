//
//  InterfaceScale.swift
//  Conduit
//
//  Whole-interface scale preference: how large the app renders on this
//  device, independent of the system text size.
//
//  Local, device-only presentation setting backed by UserDefaults through
//  @AppStorage — the same contract as ChatTypography and AccentPalette: it
//  is never synchronized to Hermes, a profile, the gateway, or any backend
//  configuration.
//
//  Mechanism: ONE explicit Dynamic Type override applied at the app root
//  (RootView). Every font that resolves a Dynamic Type text style follows
//  it — chrome and transcript alike — because those sizes are read from the
//  environment at render time. `.system` applies NO override, so the
//  default renders exactly as before this preference existed: the device
//  setting rules, byte for byte.
//
//  This is an independent multiplier from the transcript-only
//  ChatTypography preference: text renders as
//
//      system text size × interface scale × chat text scale
//
//  and both are visible in the Settings sheet (the transcript's own size
//  control keeps working on top of this one).
//
//  Known limit, measured: the 31 fixed `.font(.system(size:))` call sites
//  (sidebar labels, micro-captions) do not read Dynamic Type and therefore
//  do not scale. Everything else (485 text-style call sites) does — the
//  SwiftUI ones through the environment, and the UIKit ones through the
//  read side at the bottom of this file (`InterfaceScaleFont`), which is
//  what makes `UIFont.preferredFont(forTextStyle:)` call sites follow the
//  override instead of the app's frozen content size category.
//

import SwiftUI
import UIKit

/// The stepped interface scale. The enum POSITION (raw value) is what
/// persists — the Dynamic Type size each step resolves to lives here so the
/// mapping can be tuned later without migrating stored preferences.
enum InterfaceScale: Int, CaseIterable, Equatable {
    /// No override: the device's own text size rules (the default, and the
    /// exact appearance the app had before this preference existed).
    case system = 0
    /// Explicit sizes, ascending — monotonic by contract so a step up can
    /// never render smaller than the step below it.
    case compact
    case large
    case larger
    case largest

    /// Local, device-only preference key, namespaced like its siblings.
    static let preferenceKey = "conduit.interfaceScale"

    /// Initial/fallback value: existing users keep today's appearance.
    static let defaultScale: InterfaceScale = .system

    /// The Dynamic Type size this step forces, or nil for "no override".
    /// `nil` is what keeps `.system` a strict no-op rather than pinning the
    /// interface to `.large` (which would SHRINK a device set larger).
    var dynamicTypeSizeOverride: DynamicTypeSize? {
        switch self {
        case .system: nil
        case .compact: .medium
        case .large: .xLarge
        case .larger: .xxLarge
        case .largest: .xxxLarge
        }
    }

    /// Human-readable name for the Settings picker.
    var displayName: String {
        switch self {
        case .system: "System"
        case .compact: "Compact"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// Safe resolution of a persisted raw value: missing or out-of-range
    /// falls back to `.system` instead of trapping or clamping.
    static func resolve(rawValue: Int?) -> InterfaceScale {
        guard let rawValue, let scale = InterfaceScale(rawValue: rawValue) else { return .system }
        return scale
    }

    /// Reads the stored preference through UserDefaults (what @AppStorage
    /// uses), so the app and tests agree on one resolution path.
    static func stored(in defaults: UserDefaults = .standard) -> InterfaceScale {
        resolve(rawValue: defaults.object(forKey: preferenceKey) as? Int)
    }
}

extension View {
    /// Applies the interface-scale override when the preference asks for
    /// one. `.system` returns the view untouched — no environment write, no
    /// extra type-level work for users who never change the setting.
    @ViewBuilder
    func conduitInterfaceScale(_ scale: InterfaceScale) -> some View {
        if let size = scale.dynamicTypeSizeOverride {
            dynamicTypeSize(size)
        } else {
            self
        }
    }
}

// MARK: - Read side: environment → UIFont

/// The READ side of the interface scale — the reusable bridge for every
/// call site that needs a UIKit font while SwiftUI paints the subtree.
///
/// Why it exists: `UIFont.preferredFont(forTextStyle:)` resolves against the
/// app's `UIContentSizeCategory`, which the interface scale never writes —
/// the preference writes `.dynamicTypeSize(_:)` at the app root
/// (`conduitInterfaceScale`). SwiftUI's `\.dynamicTypeSize` environment is
/// the value that modifier sets (and, with no modifier, the device's own
/// text size), so reading it here is what makes UIKit-resolved fonts move
/// with the scale, the system text size, and any other `.dynamicTypeSize`
/// override above the call site.
///
/// `\.sizeCategory` is the deprecated alias of the same value — the SDK's
/// `SwiftUICore` interface declares it
/// `deprecated: 100000.0, renamed: "dynamicTypeSize"` — so both resolve to
/// one trait collection; this bridge takes the key the modifier writes
/// directly so it never depends on the alias.
enum InterfaceScaleFont {
    /// The trait collection `UIFont.preferredFont(forTextStyle:compatibleWith:)`
    /// must resolve against for a font to come out at the size SwiftUI is
    /// painting with. `UIContentSizeCategory(_: DynamicTypeSize?)` is the
    /// SDK's own one-to-one mapping (11 sizes ↔ 11 categories), iOS 15+.
    static func traits(for dynamicTypeSize: DynamicTypeSize) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
    }

    /// The environment's Dynamic Type size as a UIKit font: the shared
    /// implementation behind every `font:` argument that used to say
    /// `.preferredFont(forTextStyle:)`. Resolves through
    /// `ChatTypography.preferred`, so the app keeps ONE UIKit-side
    /// resolution point.
    static func preferred(_ style: UIFont.TextStyle, for dynamicTypeSize: DynamicTypeSize) -> UIFont {
        ChatTypography.preferred(style, traits(for: dynamicTypeSize))
    }

    /// Fixed-design (monospaced) chrome font at the size the style has in
    /// the environment: the `.monospacedSystemFont(ofSize:)` call sites that
    /// used to read `pointSize` off an unscaled `UIFont.preferredFont` —
    /// they need the SCALING font's point size, not the app category's.
    static func monospaced(
        _ style: UIFont.TextStyle,
        for dynamicTypeSize: DynamicTypeSize,
        weight: UIFont.Weight = .regular
    ) -> UIFont {
        .monospacedSystemFont(ofSize: preferred(style, for: dynamicTypeSize).pointSize, weight: weight)
    }
}
