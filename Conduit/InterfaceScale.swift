//
//  InterfaceScale.swift
//  Conduit
//
//  Read side of Dynamic Type for the UIKit call sites: the bridge that
//  makes `UIFont.preferredFont(forTextStyle:)` follow SwiftUI's
//  `\.dynamicTypeSize` environment instead of the app's frozen content
//  size category.
//
//  The app has NO interface-scale selector of its own: Gerardo's vote
//  (2026-09-26) was "Quitar los dos y que mande el slider de iOS: la app
//  queda con un solo mando". The iOS text-size slider (Ajustes del iPad →
//  Texto más grande) is the single control, and it reaches the whole tree
//  as the environment's `\.dynamicTypeSize` — which is exactly the value
//  the read side below resolves against. Any other `.dynamicTypeSize(_)`
//  written above a subtree (a test, a fixture) is honoured for the same
//  reason: the bridge reads the environment where the subtree is mounted,
//  never a stored preference.
//
//  Why a bridge is needed at all: SwiftUI paints with the environment,
//  while UIKit resolves fonts against a `UIContentSizeCategory` the
//  environment never writes. Without this, `UIFont.preferredFont` call
//  sites (clarify card, selection chrome, composer paste preview) would
//  ignore the system slider and any environment override.
//
//  Known limit, measured: the fixed `.font(.system(size:))` call sites
//  (sidebar labels, micro-captions) do not read Dynamic Type and therefore
//  do not scale. Everything else (485 text-style call sites) does — the
//  SwiftUI ones through the environment, and the UIKit ones through
//  `InterfaceScaleFont` below.
//

import SwiftUI
import UIKit

// MARK: - Read side: environment → UIFont

/// The READ side of Dynamic Type — the reusable bridge for every call
/// site that needs a UIKit font while SwiftUI paints the subtree.
///
/// Why it exists: `UIFont.preferredFont(forTextStyle:)` resolves against
/// the app's `UIContentSizeCategory`, which the environment never writes.
/// SwiftUI's `\.dynamicTypeSize` is the value the tree actually renders
/// with (the device's own text size when nothing overrides it), so
/// reading it here is what makes UIKit-resolved fonts move with the
/// system slider, with the accessibility sizes, and with any other
/// `.dynamicTypeSize` override above the call site.
///
/// `\.sizeCategory` is the deprecated alias of the same value — the SDK's
/// `SwiftUICore` interface declares it
/// `deprecated: 100000.0, renamed: "dynamicTypeSize"` — so both resolve to
/// one trait collection; this bridge takes the current key directly so it
/// never depends on the alias.
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
    /// the environment: the `.monospacedSystemFont(ofSize:)` call sites
    /// that used to read `pointSize` off an unscaled `UIFont.preferredFont`
    /// — they need the SCALING font's point size, not the app category's.
    static func monospaced(
        _ style: UIFont.TextStyle,
        for dynamicTypeSize: DynamicTypeSize,
        weight: UIFont.Weight = .regular
    ) -> UIFont {
        .monospacedSystemFont(ofSize: preferred(style, for: dynamicTypeSize).pointSize, weight: weight)
    }
}
