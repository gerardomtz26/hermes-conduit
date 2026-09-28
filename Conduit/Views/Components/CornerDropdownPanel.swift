//
//  CornerDropdownPanel.swift
//  Conduit
//
//  The shell of the two corner dropdowns — model and context — with the
//  SAME anatomy as the sessions side bar (build 166: Gerardo asked for
//  "el selector de modelo y el porcentaje de contexto… como botones en la
//  esquina superior derecha… un morph en esa esquina con las mismas
//  propiedades que el menú de iniciar conversación"):
//
//  - Near-solid base under Liquid Glass (90%, the legibility lesson of
//    build 163) so the conversation never bleeds through the list.
//  - The bubble→card morph: the card's frame starts at its button's
//    capsule frame and inflates (matched geometry, exactly one of the
//    pair present — the bar's button is not rendered while open).
//  - Content materializes INSIDE the growing bubble: the glass is solid
//    from frame 0 (no flicker) and the list fades 0.06 s later.
//  - Header: the title closes the panel (same gesture that opened it)
//    plus the explicit X.
//
//  What differs from the sessions panel is only placement: MainView pins
//  this card to the TOP TRAILING corner, and height comes from the
//  content — ModelPickerView's ScrollView is greedy (grows to the
//  screen's bottom and scrolls, the dropdown Gerardo picked), while
//  ContextSheet is a plain stack that hugs its content.
//

import SwiftUI

struct CornerDropdownPanel<Content: View>: View {
    let namespace: Namespace.ID
    /// Matched id shared with the bar button this panel inflates from.
    let bubbleID: String
    /// Stable identifier for tests (e.g. "model.panel").
    let panelID: String
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header

            content()
                .frame(maxWidth: .infinity)
        }
        // Two-phase entrance, same numbers as the sessions panel: the
        // glass surface belongs to the outer layer (solid from frame 0,
        // continuous with the button's capsule) and only the content
        // fades/scales in once the bubble has started growing. The
        // removal dissolves fast so a shrinking card never shows a
        // squeezed list.
        .transition(
            .asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.97, anchor: .topTrailing))
                    .animation(.easeOut(duration: 0.26).delay(0.06)),
                removal: .opacity.animation(.easeIn(duration: 0.14))
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // Legibility lesson (build 163): a 90% base under the glass keeps
        // the rim/refraction while the rows stay readable over a chat
        // full of white text.
        .background(Color.conduitBackground.opacity(0.90))
        .conduitGlassSurface(cornerRadius: 26, tint: .conduitAccent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        // THE BUBBLE: the card starts at its button's capsule frame and
        // inflates; on close it collapses back into the button.
        .matchedGeometryEffect(id: bubbleID, in: namespace)
        // Explicit container: without it SwiftUI does not realize the
        // card as an element, the identifier bleeds onto the children
        // (measured in the CornerPanelsUITests failure dump) and
        // app.otherElements["…"] finds nothing. Children stay queryable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(panelID)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // The title closes the panel: the gesture that opened it,
            // reversed, keeps the pair unified (same as the sessions
            // panel's header).
            Button(action: onClose) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Closes this panel")

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .conduitGlassControl(cornerRadius: 18)
            .accessibilityLabel("Close panel")
        }
        // Geometry twin of the button: the card hangs from the bar's
        // trailing corner, so the header lands where the pill sat —
        // 10 top like the source's vertical padding.
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
