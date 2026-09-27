//
//  SessionsPanel.swift
//  Conduit
//
//  The sessions panel: a FLOATING SIDE PANEL that drops down out of the
//  conversation's name. Gerardo's design (2026-09-27, second pass): not a
//  full-surface layer — a Liquid Glass card anchored to the leading edge,
//  its top flush with the name's row, growing from that corner with a
//  spring while the conversation stays visible to the right of it.
//
//  The morph is classic matched geometry with exactly ONE of the pair
//  present at any moment: MainView stops rendering the bar's pill while the
//  panel is open, so whichever side exists is the geometry source and the
//  animated flip carries the title's frame from one to the other.
//
//  Geometry twin of the pill: same font, and the paddings are chosen so the
//  text lands exactly where it sat in the bar — panel margin 12 + header 12
//  = 24 leading, 10 top. That is what makes the morph read as one
//  continuous object instead of a jump.
//

import SwiftUI

struct SessionsPanel: View {
    /// One number tunes the card's width — the four drawer tabs need ~70
    /// pt each, and the conversation name sits at x = 24 with the card
    /// hanging 12 from the leading edge. Narrower (≈230) squeezes the tabs.
    static let panelWidth: CGFloat = 320

    let namespace: Namespace.ID
    /// The same string the source pill showed (session title or room name).
    let title: String
    let onRequestSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            SidebarView(onRequestSettings: onRequestSettings, showsBackdrop: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Liquid Glass card: the conversation refracts through the panel
        // instead of being covered by an opaque field — that is what makes
        // it read as floating BESIDE the chat instead of replacing it.
        .conduitGlassSurface(cornerRadius: 26, tint: .conduitAccent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // 12 (card margin) + 12 = 24 leading — the pill's x in the bar —
        // and 10 top, its top padding: the morph has to land in place.
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
