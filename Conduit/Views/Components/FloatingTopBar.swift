//
//  FloatingTopBar.swift
//  Conduit
//
//  The conversation surface's floating bar, laid out like WhatsApp's top
//  bar: chat identity on the leading side, a segmented glass control in the
//  middle to switch destinations (chats / kanban / subagents), and the
//  action pill on the trailing side. MainView hides the system navigation
//  bar and mounts this as the stack's top safe-area inset, so the transcript
//  starts below it and slides under the glass while scrolling.
//
//  The three zones are three separate glass surfaces — not one wide capsule
//  — because that is the reference layout: identity and actions hug their
//  edges while the segment control floats alone in the middle. Each outer
//  zone is width-flexible so the control stays centered no matter how long
//  the session title is, but the frame only LAYS the pill out: it does not
//  extend the pill's tap target, so the empty strip still belongs to the
//  content beneath.
//

import SwiftUI

/// Destinations reachable from the floating bar's segment control. The icons
/// match `SidebarTab`'s where they overlap so the drawer and the bar speak
/// the same visual language.
enum TopBarSection: String, CaseIterable {
    case chats
    case kanban
    case agents

    var icon: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .kanban: return "rectangle.3.group"
        case .agents: return "person.2"
        }
    }

    /// `chats` keeps the literal "Open sessions": the connection and
    /// profile-picker UI tests address that button by this exact string.
    var accessibilityLabel: String {
        switch self {
        case .chats: return "Open sessions"
        case .kanban: return "Open Kanban"
        case .agents: return "Open delegate agents"
        }
    }
}

/// The three-zone bar: leading identity, centered segment control, trailing
/// actions. Mounted as a top safe-area inset by `MainView`.
struct FloatingTopBar<Leading: View, Center: View, Trailing: View>: View {
    let leading: Leading
    let center: Center
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            center.fixedSize()
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        // Gap between the bar and the first row of content: without it the
        // surfaces read as an attached header instead of floating glass.
        .padding(.bottom, 6)
    }
}

/// WhatsApp-style segment control: one glass capsule holding the three
/// destinations, with the active one marked by a tinted glass blob that
/// morphs between segments inside the shared `GlassEffectContainer` (iOS 26).
/// Tapping the active destination closes it again.
struct TopBarSegmentedControl: View {
    let active: TopBarSection
    /// Live count of delegate agents whose status is active: > 0 drops an
    /// accent dot on the agents segment so "subagents running" is visible
    /// without opening the sheet (same source `DelegateAgentsSheet` reads).
    let runningAgentCount: Int
    let onSelect: (TopBarSection) -> Void
    @Namespace private var selectionNamespace

    var body: some View {
        ConduitGlassGroup(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(TopBarSection.allCases, id: \.self) { section in
                    Button {
                        Haptics.selection()
                        onSelect(section)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: section.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 46, height: 40)
                                .foregroundStyle(active == section ? Color.primary : Color.secondary)

                            if section == .agents && runningAgentCount > 0 {
                                Circle()
                                    .fill(Color.conduitAccent)
                                    .frame(width: 9, height: 9)
                                    .overlay {
                                        Circle().strokeBorder(
                                            Color(.systemBackground).opacity(0.6),
                                            lineWidth: 1.5
                                        )
                                    }
                                    .offset(x: 5, y: -3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .background {
                        if active == section {
                            // Same geometry on both paths (the section rule
                            // in Theme.swift): native morphing glass on iOS
                            // 26, a tinted fill of the same radius before.
                            if #available(iOS 26.0, *) {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(.clear)
                                    .glassEffect(
                                        .regular.tint(.conduitAccent.opacity(0.18)),
                                        in: .rect(cornerRadius: 17)
                                    )
                                    .glassEffectID("top-bar-section", in: selectionNamespace)
                            } else {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(Color.conduitAccent.opacity(0.14))
                            }
                        }
                    }
                    .accessibilityLabel(section.accessibilityLabel)
                    .accessibilityAddTraits(active == section ? [.isSelected] : [])
                    .accessibilityValue(
                        section == .agents && runningAgentCount > 0
                            ? AppLocalization.string("\(runningAgentCount) working now")
                            : ""
                    )
                }
            }
            .padding(4)
            .conduitGlassSurface(cornerRadius: 19, tint: .conduitAccent.opacity(0.05))
        }
    }
}
