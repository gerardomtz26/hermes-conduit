//
//  Theme.swift
//  Conduit
//
//  Color palette and Liquid Glass styling.
//

import SwiftUI
import UIKit

extension ShapeStyle where Self == Color {
    // Primary accent — blue (replaces the amber/gold that Gerardo disliked and
    // that could not carry the user bubble's white text).
    static var conduitAccent: Color { .conduitAdaptiveAccent }
    static var conduitAccentSoft: Color { .conduitAdaptiveAccentSoft }
    /// Fill of the user's own message bubble. Deliberately NOT the accent: the
    /// accent has to stay light enough to read as text on the dark backdrop
    /// (WCAG AA needs ≥4.5:1 there), while the bubble carries WHITE text and so
    /// must stay dark (≤ ~0.18 luminance) — one colour cannot do both, which is
    /// exactly why the old gold bubble failed at 2.08:1. Same values in light
    /// and dark: white text needs its 4.5:1 in both.
    static var conduitUserBubbleTop: Color { .conduitUserBubbleTopColor }
    static var conduitUserBubbleBottom: Color { .conduitUserBubbleBottomColor }
    static var conduitAura: Color { Color(red: 0.38, green: 0.58, blue: 0.98) }
    // Text colors (adapt to light/dark via system colors)
    static var conduitText: Color { Color.primary }
    static var conduitTextSecondary: Color { Color.secondary }
    static var conduitTextTertiary: Color { Color(red: 0.5, green: 0.5, blue: 0.55) }
    // Backgrounds
    static var conduitBackground: Color { Color(.systemBackground) }
    static var conduitSurface: Color { Color(.secondarySystemBackground) }
}

extension Color {
    // Aliases for non-ShapeStyle usage (e.g., UIColor extraction)
    static var conduitAccentColor: Color { .conduitAdaptiveAccent }
    static let conduitBackgroundColor = Color(.systemBackground)
    static let conduitSurfaceColor = Color(.secondarySystemBackground)

    // Live: the provider reads `AccentPalette.current`, so a picker change in
    // Settings repaints every surface that uses the accent without a rebuild.
    static let conduitAdaptiveAccent = Color(uiColor: UIColor { traits in
        AccentPalette.current.accentUIColor.resolvedColor(with: traits)
    })

    static let conduitAdaptiveAccentSoft = Color(uiColor: UIColor { traits in
        AccentPalette.current.accentSoftUIColor.resolvedColor(with: traits)
    })

    // User-bubble fill, driven by the selected palette (#2C56C4 → #1E3F94 on
    // the default one: white text at 6.49:1 → 9.57:1).
    static let conduitUserBubbleTopColor = Color(uiColor: UIColor { traits in
        AccentPalette.current.bubbleTopUIColor.resolvedColor(with: traits)
    })
    static let conduitUserBubbleBottomColor = Color(uiColor: UIColor { traits in
        AccentPalette.current.bubbleBottomUIColor.resolvedColor(with: traits)
    })
}

// MARK: - App identity

/// Uses the real app artwork where Conduit identity matters. The full artwork
/// remains recognizable at this size; compact functional controls should use
/// semantic system symbols instead.
struct ConduitAppIconArtwork: View {
    let assetName: String
    let size: CGFloat

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.conduitAccent.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.18), radius: size * 0.10, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

// MARK: - Motion

enum ConduitMotion {
    static let response = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let transition = Animation.spring(response: 0.46, dampingFraction: 0.84)
    static let settle = Animation.easeOut(duration: 0.22)
}

// MARK: - Living canvas

/// A deliberately quiet background field. It gives native glass something
/// meaningful to refract without competing with conversation content.
struct ConduitBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasDrifted = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                base

                Circle()
                    .fill(Color.conduitAccent.opacity(colorScheme == .dark ? 0.20 : 0.055))
                    .frame(width: proxy.size.width * 0.92)
                    .blur(radius: 72)
                    .offset(
                        x: hasDrifted ? proxy.size.width * 0.30 : -proxy.size.width * 0.18,
                        y: hasDrifted ? -proxy.size.height * 0.34 : -proxy.size.height * 0.24
                    )

                Circle()
                    .fill(Color.conduitAura.opacity(colorScheme == .dark ? 0.14 : 0.055))
                    .frame(width: proxy.size.width * 0.84)
                    .blur(radius: 84)
                    .offset(
                        x: hasDrifted ? -proxy.size.width * 0.32 : proxy.size.width * 0.26,
                        y: hasDrifted ? proxy.size.height * 0.36 : proxy.size.height * 0.28
                    )

                LinearGradient(
                    colors: [Color.black.opacity(colorScheme == .dark ? 0.18 : 0), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) {
                hasDrifted = true
            }
        }
    }

    private var base: Color {
        colorScheme == .dark
            // Pure black when AMOLED background is on, #0B0D12 otherwise.
            ? Color(uiColor: AmoledBackground.darkBackdropUIColor)
            : Color(red: 0.94, green: 0.95, blue: 0.98)
    }
}

/// Keeps adjacent glass controls composited as a group on iOS 26 while
/// retaining the same layout on earlier OS versions.
struct ConduitGlassGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Liquid Glass compatibility

extension View {
    /// Uses the native iOS 26 glass compositor when it is available. The
    /// fallback intentionally stays material-based rather than attempting to
    /// imitate glass with custom blur stacks.
    ///
    /// Both branches of both helpers in this section — this one and
    /// `conduitGlassControl` — must keep the same corner radius and the same
    /// covered area, so the two OS paths render the same card geometry. A
    /// branch that drew a smaller surface would render a clipped card on that
    /// path. The fallback cannot be exercised by any simulator runtime this
    /// project has available (iOS 26.5 only, locally and in CI), which is why
    /// this note stands in for a test of it: verify by inspection when changing
    /// either branch.
    @ViewBuilder
    func conduitGlassSurface(
        cornerRadius: CGFloat,
        tint: Color = .clear,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func conduitGlassControl(
        cornerRadius: CGFloat = 18,
        tint: Color = .clear,
        prominent: Bool = false,
        interactive: Bool = true
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(
                    .regular.tint(prominent ? tint.opacity(0.88) : tint).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                self.glassEffect(
                    .regular.tint(prominent ? tint.opacity(0.88) : tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
            }
        } else {
            self
                .background(
                    prominent ? tint.opacity(0.92) : Color.conduitSurface.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func conduitGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.plain)
        }
    }
}
