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
    /// One number tunes the card's width: the four drawer tabs carry
    /// SPANISH labels ("Sesiones" ≈ 62 pt + icon) and need ~88 pt each at
    /// 356 — narrower and they wrap to two lines (seen on Gerardo's iPad
    /// at 320, build 162). The name sits at x = 24, card hangs 12.
    static let panelWidth: CGFloat = 356

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
        // Near-solid base UNDER the glass: the conversation behind is busy
        // white text, and pure glass let it bleed through the empty upper
        // area of the card (measured on Gerardo's iPad, build 162 — the
        // complaint was legibility). 90% keeps the glass rim and the
        // refraction at the edges while the list stays readable; this is
        // the number to tune if it still feels see-through (or too flat).
        .background(Color.conduitBackground.opacity(0.90))
        // Liquid Glass card: the conversation still refracts at the edges —
        // that is what keeps it floating BESIDE the chat, not replacing it.
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
