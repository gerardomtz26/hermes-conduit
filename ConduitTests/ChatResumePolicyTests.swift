import XCTest
@testable import Conduit

final class ChatResumePolicyTests: XCTestCase {
    func testPreserveCurrentNeverFallsBackWhenCatalogOmitsCurrentConversation() {
        XCTAssertNil(ChatResumeSessionResolver.target(
            in: [session("unrelated")],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: "stored-a",
            currentSessionID: "runtime-a"
        ))
    }

    private func session(
        _ id: String,
        alternates: [String] = [],
        source: SessionSource = .chat,
        lastActivityAt: TimeInterval? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternates,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: lastActivityAt,
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    // MARK: - authoritative "latest"

    /// List position is not recency: the sync path prepends a retained
    /// active-turn row and merges cached rows behind live ones, so the newest
    /// conversation is the one with the greatest activity instant.
    func testLatestActivityFallbackOrdersByTimestampNotListPosition() {
        let selected = ChatResumeSessionResolver.target(
            in: [
                session("older", lastActivityAt: 100),
                session("newer", lastActivityAt: 500),
                session("undated")
            ],
            behavior: .latestActivity,
            purpose: .automaticReturn,
            savedSessionID: nil,
            currentSessionID: nil
        )

        XCTAssertEqual(selected?.id, "newer")
    }

    /// Rows without a machine-readable instant cannot outrank one that has it.
    func testUndatedRowsNeverOutrankTimestampedOnes() {
        XCTAssertEqual(
            ChatResumeSessionResolver.latestChat(in: [
                session("undated-first"),
                session("dated", lastActivityAt: 10)
            ])?.id,
            "dated"
        )
    }

    /// With no timestamps at all, the server's own ordering is the only
    /// evidence there is — the historical first-row behavior stands.
    func testUndatedCatalogKeepsServerOrdering() {
        XCTAssertEqual(
            ChatResumeSessionResolver.latestChat(in: [session("first"), session("second")])?.id,
            "first"
        )
    }

    /// A conversation the client knows to be a Bot Chat is never adopted as the
    /// workspace's conversation — not by the stored-id match and not by the
    /// latest-activity fallback.
    func testBotOwnedConversationIsNeverAnOrdinarySelection() {
        let botRow = session("runtime-bot", lastActivityAt: 900)
        let ordinary = session("ordinary-1", lastActivityAt: 100)
        let ownership: Set<String> = ["runtime-bot", "stored-bot"]

        // The stored id resolves only to a bot-owned row, so ordinary selection
        // declines it and falls through to the workspace's own newest
        // conversation. The bot conversation is restored through the Bot Mode
        // path (the caller owns the reference's kind), never adopted here.
        XCTAssertEqual(
            ChatResumeSessionResolver.target(
                in: [botRow, ordinary],
                behavior: .continueWhereLeftOff,
                purpose: .automaticReturn,
                savedSessionID: "runtime-bot",
                currentSessionID: "runtime-bot",
                botOwnedSessionIDs: ownership
            )?.id,
            "ordinary-1"
        )
        XCTAssertEqual(
            ChatResumeSessionResolver.target(
                in: [botRow, ordinary],
                behavior: .latestActivity,
                purpose: .automaticReturn,
                savedSessionID: nil,
                currentSessionID: nil,
                botOwnedSessionIDs: ownership
            )?.id,
            "ordinary-1",
            "a newer bot chat is not the workspace's latest conversation"
        )
        XCTAssertNil(
            ChatResumeSessionResolver.missingSavedSessionID(
                in: [ordinary],
                behavior: .continueWhereLeftOff,
                purpose: .automaticReturn,
                savedSessionID: "stored-bot",
                botOwnedSessionIDs: ownership
            ),
            "the missing-saved-session escape hatch never resumes a bot conversation as ordinary"
        )
    }

    func testContinueReturnsSavedConversationWhenAnotherConversationIsNewer() {
        let newestB = session("stored-b", alternates: ["runtime-b"])
        let savedA = session("stored-a", alternates: ["runtime-a"])

        let selected = ChatResumeSessionResolver.target(
            in: [newestB, savedA],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "runtime-a",
            currentSessionID: "runtime-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testLatestReturnDeliberatelyIgnoresSavedConversation() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("stored-a")],
            behavior: .latestActivity,
            purpose: .automaticReturn,
            savedSessionID: "stored-a",
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testRecoverySyncPreservesCurrentConversationRegardlessOfPreference() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("stored-a")],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: "stored-a",
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testUnavailableSavedConversationFallsBackToNewestOrdinaryChat() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("cron", source: .cron), session("stored-b")],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "deleted-a",
            currentSessionID: "deleted-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testLatestReturnsNilWhenNoOrdinaryChatExists() {
        XCTAssertNil(ChatResumeSessionResolver.target(
            in: [session("cron", source: .cron)],
            behavior: .latestActivity,
            purpose: .automaticReturn,
            savedSessionID: "cron",
            currentSessionID: "cron"
        ))
    }

    func testRecoveryMatchesAlternateCurrentID() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-a", alternates: ["runtime-a"])],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: nil,
            currentSessionID: "runtime-a"
        )
        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testContinueCanRestoreSavedCronConversation() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("cron-a", source: .cron)],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "cron-a",
            currentSessionID: "cron-a"
        )
        XCTAssertEqual(selected?.id, "cron-a")
    }

    func testResumeBehaviorPresentationCopyIsStable() {
        XCTAssertEqual(ChatResumeBehavior.continueWhereLeftOff.title, "Continue where I left off")
        XCTAssertEqual(ChatResumeBehavior.latestActivity.title, "Jump to latest activity")
    }

    func testPersistedAnchorSurvivesWhenTargetExists() {
        let message = ChatMessage(
            id: "source-12",
            role: .assistant,
            content: "Stable",
            timestamp: "now"
        )
        let target = ChatMessageScrollTargets.make(for: [message])[0]
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: target.semanticID,
            followsLatest: false,
            anchorMetadata: target.restorationMetadata,
            anchorSourceMessageID: target.id
        )

        XCTAssertEqual(
            ChatResumeViewportResolver.destination(
                for: snapshot,
                availableTargets: .init(targets: [target])
            ),
            .anchor(target.semanticID)
        )
    }

    func testMissingAnchorFallsBackToLatestWithinSelectedConversation() {
        XCTAssertEqual(
            ChatResumeViewportResolver.destination(
                for: .init(anchorMessageID: "deleted", followsLatest: false),
                availableTargets: .init(targets: [])
            ),
            .latest
        )
    }
}
