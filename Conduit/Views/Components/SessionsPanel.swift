//
//  SessionsPanel.swift
//  Conduit
//
//  The sessions panel: the conversations menu presented as a full-surface
//  overlay that grows OUT OF the conversation's name. Gerardo asked for
//  this explicitly (2026-09-27): never a card dropped in the middle of the
//  screen — tapping the name makes the panel appear as if it were unified
//  with it, the title pill morphing into the panel's header.
//
//  The morph is classic matched geometry with exactly ONE of the pair
//  present at any moment: MainView stops rendering the bar's pill while the
//  panel is open, so whichever side exists is the geometry source and the
//  animated flip carries the title's frame from one to the other.
//
//  Geometry twin of the pill: same font, and the header's paddings are
//  chosen so the text lands exactly where it sat in the bar —
//  12 (bar) + 12 (pill) = 24 leading, 10 top. That is what makes the
//  morph read as one continuous object instead of a jump.
//

import SwiftUI

struct SessionsPanel: View {
    @EnvironmentObject private var appState: AppState
    let namespace: Namespace.ID
    /// The same string the source pill showed (session title or room name).
    let title: String
    let onRequestSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // One field for the whole panel: header and drawer share it, and
            // it covers the floating bar underneath (the panel sits above
            // the whole navigation stack).
            ConduitBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                SidebarView(
                    onRequestSettings: onRequestSettings,
                    onClose: onClose,
                    showsBackdrop: false
                )
            }
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // The name itself closes the panel: the gesture that opened it,
            // reversed, keeps the pair unified.
            Button(action: onClose) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .matchedGeometryEffect(id: "conversation-title", in: namespace)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Closes the conversations menu")

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .conduitGlassControl(cornerRadius: 18)
            // Same words the drawer's own close control always carried.
            .accessibilityLabel("Close sessions")
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
