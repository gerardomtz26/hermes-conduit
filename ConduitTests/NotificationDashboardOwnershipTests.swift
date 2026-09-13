//
//  NotificationDashboardOwnershipTests.swift
//  Conduit
//
//  Push/relay dashboard ownership (#148 / B3): the collision matrix that
//  keeps a push from dashboard A from ever acting against active dashboard
//  B. Covers the pure ownership resolution, the APNs payload's dashboard_id
//  parsing (valid, absent, and malformed), and the fail-closed integration
//  through AppState.openNotificationTarget.
//

import XCTest
@testable import Conduit

@MainActor
final class NotificationDashboardOwnershipTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        defaultsSuite = "NotificationDashboardOwnershipTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    // MARK: - Ownership matrix (pure)

    private let dashboardA = UUID()
    private let dashboardB = UUID()

    private func resolve(
        _ target: UUID?,
        malformed: Bool = false,
        active: UUID?,
        saved: [UUID]
    ) -> NotificationDashboardOwnership.Outcome {
        NotificationDashboardOwnership.resolve(
            targetDashboardID: target,
            hasMalformedDashboardID: malformed,
            activeDashboardID: active,
            savedDashboardIDs: saved
        )
    }

    func testPushFromActiveDashboardRoutes() {
        XCTAssertEqual(
            resolve(dashboardA, active: dashboardA, saved: [dashboardA, dashboardB]),
            .route
        )
    }

    func testPushFromKnownOtherDashboardSwitchesFirst() {
        XCTAssertEqual(
            resolve(dashboardB, active: dashboardA, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardB)
        )
    }

    func testPushFromUnknownDashboardFailsClosed() {
        let unknown = UUID()
        XCTAssertEqual(
            resolve(unknown, active: dashboardA, saved: [dashboardA, dashboardB]),
            .failClosed(.unrecognizedDashboard)
        )
    }

    func testMalformedDashboardIdentityFailsClosed() {
        XCTAssertEqual(
            resolve(nil, malformed: true, active: dashboardA, saved: [dashboardA]),
            .failClosed(.unrecognizedDashboard)
        )
    }

    func testLegacyUnscopedPushRoutesWithAtMostOneSavedDashboard() {
        XCTAssertEqual(resolve(nil, active: dashboardA, saved: [dashboardA]), .route)
        XCTAssertEqual(resolve(nil, active: nil, saved: []), .route)
    }

    func testLegacyUnscopedPushFailsClosedWithMultipleDashboards() {
        XCTAssertEqual(
            resolve(nil, active: dashboardA, saved: [dashboardA, dashboardB]),
            .failClosed(.unscopedPush)
        )
    }

    func testUnscopedPushFailsClosedEvenWhenActiveIsNil() {
        // "Do not guess based on current active dashboard" holds when nothing
        // is active either: several saved dashboards, no ownership evidence.
        XCTAssertEqual(
            resolve(nil, active: nil, saved: [dashboardA, dashboardB]),
            .failClosed(.unscopedPush)
        )
    }

    func testKnownDashboardSwitchesFirstWhenNothingIsActive() {
        XCTAssertEqual(
            resolve(dashboardA, active: nil, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardA)
        )
    }

    // MARK: - Payload parsing

    private func parsePayload(_ payload: [String: Any]) -> ConduitNotificationTarget? {
        PushNotificationService.parseNotificationTarget(
            from: ["conduit": payload]
        )
    }

    private func routingPayload(dashboardID: Any?) -> [String: Any] {
        var payload: [String: Any] = [
            "session_id": "runtime-1",
            "type": "response.ready",
        ]
        if let dashboardID { payload["dashboard_id"] = dashboardID }
        return payload
    }

    func testPayloadWithValidDashboardIDParsesUUID() throws {
        let target = try XCTUnwrap(parsePayload(routingPayload(dashboardID: dashboardA.uuidString)))
        XCTAssertEqual(target.dashboardID, dashboardA)
        XCTAssertFalse(target.hasMalformedDashboardID)
    }

    func testPayloadWithoutDashboardIDIsUnscoped() throws {
        let target = try XCTUnwrap(parsePayload(routingPayload(dashboardID: nil)))
        XCTAssertNil(target.dashboardID)
        XCTAssertFalse(target.hasMalformedDashboardID)
    }

    func testPayloadWithMalformedDashboardIDIsMarkedUnrecognized() throws {
        let target = try XCTUnwrap(parsePayload(routingPayload(dashboardID: "not-a-uuid")))
        XCTAssertNil(target.dashboardID)
        XCTAssertTrue(target.hasMalformedDashboardID)
    }

    func testDashboardIDReadsFromNestedRoutingStubToo() throws {
        let payload: [String: Any] = [
            "session_id": "runtime-1",
            "dashboard_id": dashboardB.uuidString,
        ]
        let direct = PushNotificationService.parseNotificationTarget(from: ["conduit": payload])
        let nested = PushNotificationService.parseNotificationTarget(from: ["body": ["conduit": payload]])
        XCTAssertEqual(direct?.dashboardID, dashboardB)
        XCTAssertEqual(nested?.dashboardID, dashboardB)
    }

    // MARK: - Fail-closed integration

    private func makeAppState(registry: SavedDashboardRegistry) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func decisionTarget(dashboardID: UUID?, malformed: Bool = false) -> ConduitNotificationTarget {
        ConduitNotificationTarget(
            profile: "default",
            sessionId: "runtime-1",
            dashboardID: dashboardID,
            hasMalformedDashboardID: malformed,
            type: "approval.needed",
            decision: .approval(sessionKey: "default", description: "Run?", choices: ["once"])
        )
    }

    func testOpenNotificationTargetFailsClosedForUnknownDashboardWithoutRecording() async {
        let saved = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [saved]))
        appState.messages = []

        let opened = await appState.openNotificationTarget(decisionTarget(dashboardID: UUID()))

        XCTAssertFalse(opened)
        XCTAssertNotNil(appState.errorMessage)
        // The decision card was never recorded into any dashboard's state.
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertFalse(appState.isConnected)
    }

    func testOpenNotificationTargetFailsClosedForUnscopedPushWithMultipleDashboards() async {
        let savedA = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "VPS", normalizedURL: "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))

        let opened = await appState.openNotificationTarget(decisionTarget(dashboardID: nil))

        XCTAssertFalse(opened)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertEqual(appState.activeDashboardID, dashboardA, "The active dashboard must not change on a fail-closed push")
    }

    func testOpenNotificationTargetFailsClosedForMalformedDashboardID() async {
        let saved = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [saved]))

        let opened = await appState.openNotificationTarget(decisionTarget(dashboardID: nil, malformed: true))

        XCTAssertFalse(opened)
        XCTAssertNotNil(appState.errorMessage)
    }
}
