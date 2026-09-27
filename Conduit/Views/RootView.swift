//
//  RootView.swift
//  Conduit
//
//  Root container — handles auth state and scene phase changes.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isPrimaryWindow = false

    var body: some View {
        ZStack {
            // A cold launch that could not reach the server yet still shows
            // the app shell over the read-only saved copy (#99).
            if appState.showLogin
                || (appState.connection == nil && appState.offlineChatPresentation == nil) {
                LoginView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }

            if let bridge = appState.dashboardTicketBridge {
                DashboardTicketBridgeView(bridge: bridge)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showLogin)
        .onChange(of: scenePhase) { _, newPhase in
            // Only the primary window drives the process-wide lifecycle: a
            // transient duplicate window's .background must never suspend a
            // conversation the primary window still presents.
            if isPrimaryWindow {
                appState.handleScenePhase(newPhase)
            }
        }
        .onAppear {
            guard !isPrimaryWindow else { return }
            // Multi-scene support exists for the CarPlay scene; a SECOND
            // foreground Conduit window is not a supported surface and
            // closes itself (the primary window releases its claim on close).
            if ConduitWindowClaimKeeper.claimPrimaryWindow() {
                isPrimaryWindow = true
            } else {
                // Environment-scoped dismissal: close THIS duplicate window
                // only. ID-scoped dismissal targets the WindowGroup and
                // would take the primary window down with it.
                dismissWindow()
            }
        }
        .onDisappear {
            if isPrimaryWindow {
                ConduitWindowClaimKeeper.releaseClaim()
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    /// Exists only to re-render this subtree when the accent palette changes,
    /// so every live colour provider resolves against the new palette. The
    /// value itself is read through `AccentPalette.current`.
    @AppStorage(AccentPalette.preferenceKey) private var accentPaletteRaw = AccentPalette.defaultPalette.rawValue
    @State private var settingsPresentation: SettingsSnapshot?
    /// Shared by the conversation-name pill and the sessions panel's
    /// header: the panel grows out of the name through this match.
    @Namespace private var sessionsMorph

    var body: some View {
        chatNavigationContent
        .sheet(isPresented: $appState.showModelPicker) {
            ModelPickerView()
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showContextSheet) {
            ContextSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showWorkspaceSheet) {
            WorkspaceBrowserSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGatewaySheet) {
            GatewayDiagnosticsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showAgentsSheet) {
            DelegateAgentsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showKanbanSheet) {
            KanbanView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showVoiceSheet, onDismiss: appState.closeVoiceConversation) {
            VoiceConversationSheet(
                controller: appState.voiceConversationController,
                profile: appState.activeProfile,
                onClose: appState.closeVoiceConversation,
                shouldAutoListen: { appState.consumeVoiceSheetAutoListen() }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $settingsPresentation, onDismiss: {
            appState.isSettingsSheetPresented = false
            Task { await appState.refreshVoiceCapabilities() }
        }) { snapshot in
            SettingsView(
                snapshot: snapshot,
                saveTheme: { appState.themePreference = $0 },
                persistBusyInputMode: { mode in await appState.setBusyInputMode(mode) },
                persistChatResumeBehavior: { appState.setChatResumeBehavior($0) },
                persistChatReturnSurface: { appState.setChatReturnSurface($0) },
                loadProfileSettings: { keys in await appState.loadProfileSettings(keys: keys) },
                persistProfileSetting: { key, value in await appState.setProfileSetting(key, value: value) },
                loadProfileConfigOptions: { await appState.loadProfileConfigOptions() },
                loadProfileModelDefaults: { await appState.loadProfileModelDefaults() },
                persistProfileMainModel: { provider, model, reasoning in
                    await appState.setProfileMainModel(provider: provider, model: model, reasoning: reasoning)
                },
                saveDefaultProfileName: { appState.saveDefaultProfileName($0) },
                reconnect: {
                    await appState.reconnect()
                    return appState.isConnected
                },
                disconnect: { appState.disconnect() }
            )
                .presentationDetents([.large])
        }
        .task(id: voiceCapabilityRefreshKey) {
            await appState.refreshVoiceCapabilities()
        }
        // Cold launch: MainView first becoming the authenticated surface is
        // the qualifying return. The hook fires once per process (re-login
        // cycles rely on the scene-phase path instead), then any pending
        // request — including one from scene activation — is consumed.
        .task {
            appState.requestPreferredReturnSurfaceForColdLaunch()
            presentPreferredReturnSurfaceIfNeeded()
        }
        .onChange(of: appState.preferredReturnSurfaceRequest) { _, _ in
            presentPreferredReturnSurfaceIfNeeded()
        }
    }

    /// The conversation shell: always full screen, with the sessions drawer
    /// presented over it — the persistent iPad column was retired (Gerardo,
    /// 2026-09-26: conversation first, navigation through the floating bar).
    /// An open Group Chat room replaces the conversation surface wholesale:
    /// a room is NOT a session, so this swap is the entire viewport
    /// integration — `ChatView`'s session state (and the saved
    /// `SessionReference`) is untouched by room navigation.
    private var chatNavigationContent: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                if appState.activeRoomSurface != nil {
                    // Keyed by room: another room starts with its own draft.
                    GroupChatView()
                        .id(appState.activeRoomSurface?.room.roomID)
                } else {
                    ChatView()
                }
            }
            .overlay(alignment: .leading) {
                EdgePanGesture { openSessionsPanel(forceSessionsTab: false) }
                    .frame(width: 25)
                    .ignoresSafeArea()
            }
            // The floating bar replaces the navigation bar: mounted as the
            // top safe-area inset it starts the content below itself and
            // lets the transcript slide under the glass while scrolling.
            .safeAreaInset(edge: .top, spacing: 0) {
                floatingTopBar
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // NOT a sheet: a floating side panel that drops down out of the
        // conversation's name (matched geometry between the title pill and
        // the panel header), leaving the conversation visible to its right.
        .overlay {
            if appState.showSidebar {
                ZStack(alignment: .topLeading) {
                    // The conversation stays visible beside the card, but
                    // dim enough that its white text stops fighting the
                    // panel's list (0.12 was measured too weak for
                    // legibility, build 162). Tap outside closes.
                    Color.black.opacity(0.30)
                        .ignoresSafeArea()
                        .onTapGesture { closeSessionsPanel() }
                        .transition(.opacity)

                    SessionsPanel(
                        namespace: sessionsMorph,
                        title: panelTitle,
                        onRequestSettings: presentSettingsFromDrawer,
                        onClose: closeSessionsPanel
                    )
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .padding(.bottom, 16)
                    // Cap AFTER the padding so the card itself is exactly
                    // panelWidth (380 - 24) and hangs from the leading edge.
                    // No transition here: SessionsPanel's own matched
                    // geometry (id "bubble") inflates the card out of the
                    // name's capsule — the bubble IS the first frame.
                }
                .zIndex(2)
            }
        }
    }

    /// What the panel's header says — the same string the source pill had,
    /// so the morph carries the identical text.
    private var panelTitle: String {
        if let room = appState.activeRoomSurface { return room.room.name }
        return appState.displayedChatTitle
    }

    /// The bar: chat identity leading — tapping it grows the sessions panel
    /// out of the very pill (matched geometry) — actions trailing. An open
    /// room swaps both pills for its own. The empty middle keeps
    /// scroll-to-top; see `CenterScrollZone`.
    private var floatingTopBar: some View {
        FloatingTopBar {
            topBarLeading
        } trailing: {
            topBarTrailing
        }
    }

    /// Opens the sessions panel on its Sessions tab: the conversation's
    /// name always lands on conversations. `forceSessionsTab: false` keeps
    /// whatever tab the drawer last showed (the edge swipe's old behavior).
    /// The flip animates so the panel grows out of the pill.
    private func openSessionsPanel(forceSessionsTab: Bool = true) {
        if forceSessionsTab {
            UserDefaults.standard.set(SidebarTab.sessions.rawValue, forKey: "conduit.sidebarTab")
        }
        withAnimation(ConduitMotion.transition) {
            appState.showSidebar = true
        }
    }

    private func closeSessionsPanel() {
        withAnimation(ConduitMotion.transition) {
            appState.dismissSidebarDrawer()
        }
    }

    /// Leading zone: the room's identity while a room is open, otherwise the
    /// session title. Tapping it opens the sessions panel — and while that
    /// panel is open the pill is NOT rendered, so its title text is the
    /// geometry source the panel's header morphs FROM (classic matched
    /// geometry: exactly one of the pair exists at any moment).
    @ViewBuilder
    private var topBarLeading: some View {
        if appState.activeRoomSurface != nil {
            if !appState.showSidebar {
                GroupChatTitlePill(namespace: sessionsMorph, onOpenMenu: { openSessionsPanel() })
            }
        } else if !appState.showSidebar {
            sessionTitlePill
        }
    }

    private var sessionTitlePill: some View {
        Button {
            Haptics.selection()
            openSessionsPanel()
        } label: {
            // displayedChatTitle (upstream #99): shows the saved
            // conversation's name while the offline copy is on screen.
            // The match sits on the TEXT (before the padding) so the panel
            // header receives the exact glyph frame, padding included.
            Text(appState.displayedChatTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .matchedGeometryEffect(id: "conversation-title", in: sessionsMorph)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .conduitGlassSurface(cornerRadius: 20, tint: .conduitAccent.opacity(0.06))
        // Source of the bubble→card morph: while the panel is open this
        // pill is NOT rendered (topBarLeading), so the panel's card takes
        // its capsule frame as the geometry to inflate from (id "bubble").
        .matchedGeometryEffect(id: "bubble", in: sessionsMorph)
        .accessibilityLabel(appState.displayedChatTitle)
        .accessibilityIdentifier("open.sessions")
        .accessibilityHint("Opens the conversations menu")
    }

    /// Trailing zone: refresh + connection dot for a session; the room's
    /// actions menu + connection dot for a room.
    @ViewBuilder
    private var topBarTrailing: some View {
        if appState.activeRoomSurface != nil {
            GroupChatActionsPill()
        } else {
            sessionActionsPill
        }
    }

    private var sessionActionsPill: some View {
        ConduitGlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    Task { await appState.refreshActiveSession() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .rotationEffect(.degrees(appState.isChatRefreshing ? 360 : 0))
                        .animation(
                            appState.isChatRefreshing
                                ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                                : .default,
                            value: appState.isChatRefreshing
                        )
                        .frame(width: 40, height: 40)
                }
                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                .disabled(!appState.isConnected || appState.isChatRefreshing)
                .accessibilityLabel("Refresh conversation")

                ConnectionStatusIndicator()
            }
            .padding(4)
            .conduitGlassSurface(cornerRadius: 22, tint: .conduitAccent.opacity(0.05))
        }
    }

    /// Settings requested from inside the panel: close it (the panel is an
    /// overlay, so nothing waits for a sheet's onDismiss) and present
    /// Settings directly — the sheet lands above the closing panel.
    private func presentSettingsFromDrawer() {
        closeSessionsPanel()
        openSettings()
    }

    private func openSettings() {
        appState.isSettingsSheetPresented = true
        settingsPresentation = appState.makeSettingsSnapshot()
    }

    /// Presents the sessions drawer for a preferred-return-surface request.
    /// Consumption semantics (defer-while-pending, claim-once-per-request,
    /// drop on precedence losers) live in AppState so they survive MainView
    /// teardown; this layer only owns the actual sheet presentation. An
    /// already-open drawer IS the surface, so the request is consumed
    /// without stacking a second presentation.
    private func presentPreferredReturnSurfaceIfNeeded() {
        guard appState.claimPreferredReturnSurfacePresentation() else { return }
        guard !appState.showSidebar else { return }
        // Animated like every other opening: the panel must always grow out
        // of the name, even when the trigger is a notification or a voice
        // intent instead of a tap.
        withAnimation(ConduitMotion.transition) {
            appState.showSidebar = true
        }
    }

    private var voiceCapabilityRefreshKey: String {
        "\(appState.isConnected):\(appState.activeProfile)"
    }
}

// MARK: - Connection Status

struct ConnectionStatusIndicator: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState

    private var color: Color {
        if appState.isConnected {
            return .green
        } else if appState.isConnecting {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        Button {
            Task { await appState.loadGatewayDiagnostics() }
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.75), radius: appState.isConnected ? 5 : 0)
                Circle()
                    .stroke(color.opacity(0.38), lineWidth: 1)
                    .frame(width: 19, height: 19)
            }
            .frame(width: 40, height: 40)
        }
        .conduitGlassControl(cornerRadius: 20, tint: color.opacity(0.10))
        .animation(ConduitMotion.response, value: appState.isConnected)
        .accessibilityLabel(appState.isConnected ? AppLocalization.string("Gateway connected") : AppLocalization.string("Gateway disconnected"))
    }
}


// MARK: - Edge Pan Gesture

/// Detects a left-edge pan gesture to open the sidebar.
/// Uses UIScreenEdgePanGestureRecognizer (~20pt edge width) via UIViewRepresentable.
struct EdgePanGesture: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(context.coordinator.handle(_:))
        )
        gesture.edges = .left
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .began { action() }
        }
    }
}
