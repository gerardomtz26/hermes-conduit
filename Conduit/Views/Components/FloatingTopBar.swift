//
//  FloatingTopBar.swift
//  Conduit
//
//  The conversation surface's floating glass bar. MainView hides the system
//  navigation bar and mounts THIS as the stack's top safe-area inset, so the
//  transcript starts below it and slides under the glass while scrolling —
//  the system-app bar behaviour, with the whole control group compositing
//  as one Liquid Glass capsule instead of the loose pills the navigation
//  bar used to draw (one per item).
//
//  The two halves it hosts — session controls (MainView) and group-room
//  controls (GroupChatTopBarContent) — keep every accessibility label the
//  old toolbar items carried, so UI tests and VoiceOver see the same words.
//

import SwiftUI

/// One floating capsule pinned below the top safe area.
///
/// Mounted as a `safeAreaInset(edge: .top)` of the conversation stack: the
/// inset offers the full width, the spacers inside the control row spread
/// the groups apart, and the glass sits above the content it covers.
/// `ConduitGlassGroup` composites the bar surface with the interactive
/// controls inside it on iOS 26 (they merge into one liquid shape); on
/// earlier systems the container is skipped and the material fallbacks in
/// `Theme.swift` draw the same geometry.
struct FloatingTopBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ConduitGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                content
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .conduitGlassSurface(cornerRadius: 26, tint: .conduitAccent.opacity(0.07))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        // Gap between the bar and the first row of content: without it the
        // capsule reads as an attached header instead of a floating bar.
        .padding(.bottom, 6)
    }
}
