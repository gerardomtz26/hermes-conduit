import XCTest
@testable import Conduit

/// Read-only offline chat copy (#99): what is stored, how it is protected,
/// when it is shown, when it is replaced, and that it never becomes evidence
/// for any live decision.
@MainActor
final class OfflineChatCacheTests: XCTestCase {
    // MARK: - Store

    func testRecordKeepsNewestPageOfDisplayRowsOnly() throws {
        let store = makeStore()
        let dashboard = UUID()
        var rows = (0..<130).map { index in
            ChatMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? .user : .assistant, content: "row \(index)", timestamp: "\(index)")
        }
        rows.append(ChatMessage(id: "approval", role: .approval, content: "Approve?", timestamp: "200"))
        rows.append(ChatMessage(id: "clarify", role: .clarify, content: "Which?", timestamp: "201"))
        rows.append(ChatMessage(id: "partial", role: .partial, content: "stream", timestamp: "202"))

        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-a",
            title: "A",
            messages: rows,
            sessions: [session("stored-a"), session("cron-1", source: .cron)]
        )

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        let transcript = try XCTUnwrap(snapshot.transcript(for: "stored-a"))
        XCTAssertEqual(transcript.messages.count, OfflineChatCacheStore.maxMessagesPerTranscript)
        XCTAssertEqual(transcript.messages.first?.id, "m10")
        XCTAssertEqual(transcript.messages.last?.id, "m129")
        XCTAssertFalse(transcript.messages.contains { [.approval, .clarify, .partial].contains($0.role) },
                       "Interactive decision cards and streaming partials are never stored")
        XCTAssertEqual(snapshot.lastSessionID, "stored-a")
        XCTAssertEqual(snapshot.sessions.map(\.id), ["stored-a"], "Cron rows stay out of the saved session list")
    }

    func testRecentTranscriptsAreBoundedMostRecentFirst() throws {
        let store = makeStore()
        let dashboard = UUID()
        for index in 0..<(OfflineChatCacheStore.maxTranscripts + 2) {
            store.record(
                dashboardID: dashboard,
                profile: "default",
                sessionID: "s\(index)",
                title: "S\(index)",
                messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
                sessions: []
            )
        }
        // Reopening an older one moves it to the front.
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "s3",
            title: "S3",
            messages: [ChatMessage(id: "m", role: .user, content: "again", timestamp: "2")],
            sessions: []
        )
        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.transcripts.map(\.sessionID), ["s3", "s6", "s5", "s4", "s2"])
    }

    func testScopesAreIsolatedAndDashboardRemovalOnlyWipesThatDashboard() {
        let store = makeStore()
        let first = UUID()
        let second = UUID()
        let row = [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")]
        store.record(dashboardID: first, profile: "default", sessionID: "a", title: "A", messages: row, sessions: [])
        store.record(dashboardID: first, profile: "work", sessionID: "w", title: "W", messages: row, sessions: [])
        store.record(dashboardID: second, profile: "default", sessionID: "b", title: "B", messages: row, sessions: [])

        XCTAssertEqual(store.load(dashboardID: first, profile: "work")?.lastSessionID, "w")
        XCTAssertNil(store.load(dashboardID: second, profile: "work"))

        store.removeDashboard(first)
        XCTAssertNil(store.load(dashboardID: first, profile: "default"))
        XCTAssertNil(store.load(dashboardID: first, profile: "work"))
        XCTAssertEqual(store.load(dashboardID: second, profile: "default")?.lastSessionID, "b")

        store.removeAll()
        XCTAssertNil(store.load(dashboardID: second, profile: "default"))
    }

    func testCacheFilesAreProtectedAndExcludedFromBackup() throws {
        let store = makeStore()
        let dashboard = UUID()
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "a",
            title: "A",
            messages: [ChatMessage(id: "m", role: .user, content: "hi", timestamp: "1")],
            sessions: []
        )
        XCTAssertTrue(OfflineChatCacheStore.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        let file = store.fileURL(dashboardID: dashboard, profile: "default")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        // The Simulator does not implement Data Protection and reports no
        // class; on a device the written class must be at least as strong.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertTrue(
                [.complete, .completeUntilFirstUserAuthentication].contains(protection),
                "Offline chat files must be at least complete-until-first-auth protected, got \(protection)"
            )
        }
        let values = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Presentation

    func testPresentingTheCopyNeverFeedsLiveStateOrTheViewport() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        let revision = appState.chatTranscriptRevision
        let transition = appState.chatViewportTransitionGeneration
        let identity = appState.activeChatScrollSessionIdentity

        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        let presentation = try XCTUnwrap(appState.offlineChatPresentation)
        XCTAssertEqual(presentation.displayedSessionID, "stored-a")
        XCTAssertEqual(presentation.displayedMessages.map(\.id), ["u1", "a1"])
        // Not evidence: nothing the live paths read changed.
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertTrue(appState.sessions.isEmpty)
        XCTAssertNil(appState.activeSessionId)
        XCTAssertNil(appState.persistedTranscriptWindow)
        XCTAssertFalse(appState.canLoadEarlierMessagesForActiveConversation)
        // Viewport (#147/#193): no transcript revision, transition, or scroll
        // identity change — the live chat view sees a plain empty cold launch.
        XCTAssertEqual(appState.chatTranscriptRevision, revision)
        XCTAssertEqual(appState.chatViewportTransitionGeneration, transition)
        XCTAssertEqual(appState.activeChatScrollSessionIdentity, identity)
        // Read-only.
        XCTAssertFalse(appState.composerIsEnabled)
        XCTAssertEqual(appState.composerAction(hasText: true, hasAttachments: false), .unavailable)
    }

    func testOtherSavedConversationsOpenInsideTheCopyOnly() throws {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-b",
            title: "B",
            messages: [ChatMessage(id: "b1", role: .user, content: "Other", timestamp: "3")],
            sessions: [session("stored-a"), session("stored-b"), session("stored-c")]
        )
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
        XCTAssertEqual(appState.offlineChatPresentation?.displayedSessionID, "stored-b")

        appState.showOfflineCachedSession("stored-a")
        XCTAssertEqual(appState.offlineChatPresentation?.displayedMessages.map(\.id), ["u1", "a1"])
        appState.showOfflineCachedSession("stored-c")
        XCTAssertEqual(appState.offlineChatPresentation?.displayedSessionID, "stored-a",
                       "A session with no saved transcript cannot be opened offline")
        XCTAssertNil(appState.activeSessionId)
    }

    func testAuthoritativeTranscriptReplacesTheCopyWholesale() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        let applied = appState.applyChatResume(
            SessionResumeResult(
                sessionId: "stored-a",
                messages: [ChatMessage(id: "server-1", role: .assistant, content: "Fresh", timestamp: "9")],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        )

        XCTAssertTrue(applied)
        XCTAssertNil(appState.offlineChatPresentation)
        XCTAssertEqual(appState.messages.map(\.id), ["server-1"], "No cached row survives the server's answer")
    }

    func testEmptyAuthoritativeConversationAlsoReplacesTheCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        _ = appState.applyChatResume(
            SessionResumeResult(
                sessionId: "stored-a",
                messages: [],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        )

        XCTAssertNil(appState.offlineChatPresentation)
        XCTAssertTrue(appState.messages.isEmpty)
    }

    func testCopyIsNotShownOverALiveTranscript() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.messages = [ChatMessage(id: "live", role: .user, content: "Live", timestamp: "1")]

        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        XCTAssertNil(appState.offlineChatPresentation)
    }

    // MARK: - Unreachable server vs. sign-in

    func testUnreachableRestoreKeepsTheCopyInsteadOfSignIn() {
        for failure: ConnectionFailure in [.offline, .hostNotFound, .unreachable, .connectionRefused, .timedOut, .dashboardUnavailable] {
            let (appState, store, dashboard) = makeAppState()
            seedCopy(store, dashboard: dashboard)
            appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
            appState.showLogin = false

            XCTAssertTrue(appState.presentCredentialRestoreFailure(failure, switchGeneration: nil))

            XCTAssertFalse(appState.showLogin, "\(failure)")
            XCTAssertNotNil(appState.offlineChatPresentation, "\(failure)")
            XCTAssertEqual(appState.lastConnectionFailure, failure)
            XCTAssertFalse(appState.isConnecting)
        }
    }

    func testAuthenticationFailureStillGoesToSignIn() {
        for failure: ConnectionFailure in [.authenticationRejected, .loginRequired, .rateLimited, .tlsUntrusted] {
            let (appState, store, dashboard) = makeAppState()
            seedCopy(store, dashboard: dashboard)
            appState.presentOfflineChatIfAvailable(dashboardID: dashboard)
            appState.showLogin = false

            _ = appState.presentCredentialRestoreFailure(failure, switchGeneration: nil)

            XCTAssertTrue(appState.showLogin, "\(failure)")
        }
    }

    func testUnreachableRestoreWithoutACopyGoesToSignIn() {
        let (appState, _, _) = makeAppState()
        appState.showLogin = false

        _ = appState.presentCredentialRestoreFailure(.offline, switchGeneration: nil)

        XCTAssertTrue(appState.showLogin)
    }

    // MARK: - Recording

    func testRecordsOnlyConnectedAuthoritativeState() throws {
        let (appState, store, dashboard) = makeAppState()
        appState.activeSessionId = "stored-a"
        appState.messages = [ChatMessage(id: "live", role: .user, content: "Live", timestamp: "1")]

        appState.recordOfflineChatCopy()
        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"), "Disconnected state is never recorded")

        appState.isConnected = true
        appState.recordOfflineChatCopy()
        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.transcript(for: "stored-a")?.messages.map(\.id), ["live"])
    }

    func testBackgroundFlushRecordsTheOnScreenConversation() throws {
        let (appState, store, dashboard) = makeAppState()
        appState.connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.isConnected = true
        appState.activeSessionId = "stored-a"
        appState.messages = [ChatMessage(id: "live", role: .assistant, content: "Answer", timestamp: "1")]

        appState.handleScenePhase(.background)

        let snapshot = try XCTUnwrap(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(snapshot.lastSessionID, "stored-a")
    }

    // MARK: - Wipes

    func testSignOutWipesTheCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        appState.presentOfflineChatIfAvailable(dashboardID: dashboard)

        appState.disconnect()

        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"))
        XCTAssertNil(appState.offlineChatPresentation)
    }

    func testRemovingAnInactiveDashboardWipesOnlyItsCopy() {
        let active = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let other = SavedDashboard(id: UUID(), label: "Two", normalizedURL: "https://two.example")
        let (appState, store, _) = makeAppState(
            registry: SavedDashboardRegistry(activeDashboardID: active.id, dashboards: [active, other])
        )
        seedCopy(store, dashboard: active.id)
        seedCopy(store, dashboard: other.id)

        appState.removeDashboard(other.id)

        XCTAssertNil(store.load(dashboardID: other.id, profile: "default"))
        XCTAssertNotNil(store.load(dashboardID: active.id, profile: "default"))
    }

    func testServerSwitchWipesEveryCopy() {
        let (appState, store, dashboard) = makeAppState()
        seedCopy(store, dashboard: dashboard)
        _ = appState.prepareChatResumeForConnection(to: "https://one.example", dashboardID: nil)
        XCTAssertNotNil(store.load(dashboardID: dashboard, profile: "default"),
                        "Re-establishing the same server is not a switch")

        _ = appState.prepareChatResumeForConnection(to: "https://two.example", dashboardID: nil)

        XCTAssertNil(store.load(dashboardID: dashboard, profile: "default"))
    }

    // MARK: - Helpers

    private func makeStore() -> OfflineChatCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineChatCacheTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return OfflineChatCacheStore(directory: directory)
    }

    private func makeAppState(
        registry: SavedDashboardRegistry? = nil
    ) -> (AppState, OfflineChatCacheStore, UUID) {
        let suite = "OfflineChatCacheTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "One", normalizedURL: "https://one.example")
        let registry = registry ?? SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        let store = makeStore()
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            offlineChatCache: store
        )
        return (appState, store, registry.activeDashboardID ?? dashboard.id)
    }

    private func seedCopy(_ store: OfflineChatCacheStore, dashboard: UUID) {
        store.record(
            dashboardID: dashboard,
            profile: "default",
            sessionID: "stored-a",
            title: "A",
            messages: [
                ChatMessage(id: "u1", role: .user, content: "Question", timestamp: "1"),
                ChatMessage(id: "a1", role: .assistant, content: "Answer", timestamp: "2"),
            ],
            sessions: [session("stored-a"), session("stored-b")]
        )
    }

    private func session(_ id: String, source: SessionSource = .chat) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}
