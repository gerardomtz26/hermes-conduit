//
//  FloatingTopBar.swift
//  Conduit
//
//  The conversation surface's floating bar: conversation identity on the
//  leading side, actions on the trailing side, and an empty but tappable
//  stretch in the middle. MainView hides the system navigation bar and
//  mounts this as the stack's top safe-area inset, so the transcript starts
//  below it and slides under the glass while scrolling.
//
//  The center used to hold a three-destination segment control; Gerardo
//  retired it (2026-09-27): the NAME is the navigation now — tapping it
//  opens the sessions panel, which grows out of the name itself (the pill
//  morphs into the panel's header through a matched geometry effect). The
//  vacant middle keeps the old scroll-to-top gesture: tap the empty space,
//  rise to the top of the conversation.
//

import SwiftUI

/// The three-zone bar: leading identity, tappable empty center, trailing
/// actions. Mounted as a top safe-area inset by `MainView`.
struct FloatingTopBar<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            // The vacant middle: flexible so the identity hugs the left edge
            // and the actions hug the right, and hit-testable across its
            // whole stretch — this is where "scroll to top" lives now.
            CenterScrollZone()
            trailing
        }
        .padding(.horizontal, 12)
        // Gap between the bar and the first row of content: without it the
        // surfaces read as an attached header instead of floating glass.
        .padding(.bottom, 6)
    }
}

/// The empty middle of the bar: invisible, flexible in its slot, and one
/// button over its whole width. Tapping the vacant space scrolls the
/// conversation back to the top — the gesture the conversation-name pill
/// used to own before it became the menu trigger.
private struct CenterScrollZone: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            Haptics.selection()
            appState.requestChatScrollToTop()
        } label: {
            Color.clear
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Scroll to top")
        .accessibilityHint("Returns to the start of this conversation")
    }
}
