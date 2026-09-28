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
//  TWO matched-geometry pairs run while the panel mounts, both with
//  exactly ONE of the pair present at any moment (MainView stops
//  rendering the pill while the panel is open):
//
//  1. id "conversation-title" — the title TEXT flies from the pill into
//     the header (unchanged since build 161).
//  2. id "bubble" — the WHOLE CARD starts at the pill's capsule frame and
//     inflates into the side panel, and collapses back into it on close.
//     The rounded rect clamps its radius to a capsule while small, so the
//     first frames ARE the name's bubble: the menu literally comes out of
//     it (Gerardo's ask, build 164).
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
        // The menu materializes INSIDE the inflating bubble: nothing is
        // drawn until the glass has started growing out of the pill
        // (0.06 s of head start), and on close it dissolves fast so the
        // card never shows a squeezed list collapsing with it. Attached
        // before the surface chain on purpose — the base/glass belong to
        // the outer layer and stay solid while only this content fades.
        .transition(
            .asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.97, anchor: .topLeading))
                    .animation(.easeOut(duration: 0.26).delay(0.06)),
                removal: .opacity.animation(.easeIn(duration: 0.14))
            )
        )
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
        // THE BUBBLE: the card's frame IS the pill's capsule frame while
        // the panel mounts — matched geometry inflates the glass straight
        // out of the name's bubble (radius clamps to a capsule at pill
        // height) and collapses it back in on close. This is the whole
        // drop animation; the content transition above is only the fade.
        .matchedGeometryEffect(id: "bubble", in: namespace)
        // Measured by SessionsPanelWidthUITests: the cap in MainView is
        // one line and it silently vanished once already (build 164).
        // Explicit container so the identifier lands on ONE element the
        // test can query (same realization issue as the corner panels).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.panel")
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
