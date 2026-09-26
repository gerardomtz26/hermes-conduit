import Combine
import XCTest
@testable import Conduit

/// A delegate agent that finished must leave BOTH the list and the badge
/// count. The gateway already reports `subagent.complete`, but the card was
/// keyed by an id the gateway never sends, so the terminal event appended a
/// second card instead of updating the first one: every finished agent kept
/// counting as working, and nothing ever removed it — restarting the app was
/// the only way to clear the list (reported by Gerardo, 2026-09-26).
@MainActor
final class AppStateDelegateAgentsTests: XCTestCase {

    // MARK: - Harness

    private func makeAppState() -> AppState {
        let suite = "AppStateDelegateAgentsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: .live,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func installActiveSession(_ state: AppState, id: String) {
        let summary = SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        state.sessions = [summary]
        state.activeSessionId = id
    }

    private func agent(_ id: String,
                       status: DelegateAgentActivity.Status) -> DelegateAgentActivity {
        DelegateAgentActivity(
            id: id,
            goal: "Fix the bug",
            model: "mimo",
            status: status,
            taskCount: 3,
            taskIndex: 1,
            currentTool: nil,
            summary: nil,
            stream: []
        )
    }

    // MARK: - Tests

    func testFinishedAgentLeavesListAndCount() {
        let state = makeAppState()
        installActiveSession(state, id: "s1")

        state.handleStreamEvent(
            .delegateAgent(sessionId: "s1", activity: agent("sa-7", status: .running)))
        XCTAssertEqual(state.delegateAgents.count, 1)
        XCTAssertEqual(state.activeAgents, 1)

        state.handleStreamEvent(
            .delegateAgent(sessionId: "s1", activity: agent("sa-7", status: .completed)))
        XCTAssertEqual(state.delegateAgents.count, 0,
                       "a finished agent must not stay listed until restart")
        XCTAssertEqual(state.activeAgents, 0)
    }

    func testFailedAgentStaysVisibleWithZeroActiveCount() {
        let state = makeAppState()
        installActiveSession(state, id: "s1")

        state.handleStreamEvent(
            .delegateAgent(sessionId: "s1", activity: agent("sa-8", status: .failed)))
        XCTAssertEqual(state.delegateAgents.count, 1,
                       "a failure stays on screen so it can be read")
        XCTAssertEqual(state.activeAgents, 0)
    }

    func testOtherAgentsKeepRunningAfterOneFinishes() {
        let state = makeAppState()
        installActiveSession(state, id: "s1")

        state.handleStreamEvent(
            .delegateAgent(sessionId: "s1", activity: agent("sa-7", status: .running)))
        state.handleStreamEvent(
            .delegateAgent(sessionId: "s1", activity: agent("sa-8", status: .running)))
        XCTAssertEqual(state.activeAgents, 2)

        state.handleStreamEvent(
            .delegateAgent(sessionId: "s1", activity: agent("sa-7", status: .completed)))
        XCTAssertEqual(state.delegateAgents.count, 1)
        XCTAssertEqual(state.activeAgents, 1)
        XCTAssertEqual(state.delegateAgents.first?.id, "sa-8")
    }
}
