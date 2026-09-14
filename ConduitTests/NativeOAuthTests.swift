import Foundation
import XCTest
@testable import Conduit

final class NativeOAuthTests: XCTestCase {
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        super.tearDown()
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        XCTAssertEqual(
            NativeOAuthFlow.pkceChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGeneratedPKCEUsesRequiredVerifierLengthAndS256() throws {
        let pair = try NativeOAuthFlow.generatePKCE()
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge, NativeOAuthFlow.pkceChallenge(verifier: pair.verifier))
        XCTAssertFalse(pair.challenge.contains("="))
    }

    func testAuthorizeURLPreservesPathPrefixAndEncodesBrokerParameters() throws {
        let url = try NativeOAuthFlow.authorizeURL(
            baseURL: "https://hermes.example/team/hermes/",
            challenge: "challenge-value",
            redirectURI: "http://127.0.0.1:49152/callback",
            state: "state-value",
            provider: "google"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value) })
        XCTAssertEqual(components.path, "/team/hermes/auth/native/authorize")
        XCTAssertEqual(values["code_challenge"]!, "challenge-value")
        XCTAssertEqual(values["code_challenge_method"]!, "S256")
        XCTAssertEqual(values["redirect_uri"]!, "http://127.0.0.1:49152/callback")
        XCTAssertEqual(values["state"]!, "state-value")
        XCTAssertEqual(values["provider"]!, "google")
    }

    func testAuthorizeURLOmitsProviderForServerChooser() throws {
        let url = try NativeOAuthFlow.authorizeURL(
            baseURL: "https://hermes.example",
            challenge: "challenge",
            redirectURI: "http://127.0.0.1:49152/callback",
            state: "state"
        )
        XCTAssertFalse(try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false).queryItems)
            .contains { $0.name == "provider" })
    }

    func testCallbackRequiresExactPathMatchingStateAndCode() throws {
        XCTAssertEqual(
            try NativeOAuthFlow.callbackCode(
                requestTarget: "/callback?code=one-time-code&state=expected",
                expectedState: "expected",
                expectedPort: 49152
            ),
            "one-time-code"
        )
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/other?code=one-time-code&state=expected",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackMalformed) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?code=one-time-code&state=attacker",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .stateMismatch) }
    }

    func testCallbackRejectsProviderErrorMissingCodeAndDuplicateState() {
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?error=access_denied&state=expected",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackRejected) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?state=expected",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackMalformed) }
        XCTAssertThrowsError(try NativeOAuthFlow.callbackCode(
            requestTarget: "/callback?code=value&state=expected&state=attacker",
            expectedState: "expected",
            expectedPort: 49152
        )) { XCTAssertEqual($0 as? NativeOAuthError, .callbackMalformed) }
    }

    func testTokenResponseDecodesAndRefreshBoundaryIsEarly() throws {
        let data = Data(#"{"access_token":"access","refresh_token":"refresh","expires_at":2000,"provider":"google","user_id":"luc"}"#.utf8)
        let tokens = try JSONDecoder().decode(NativeOAuthTokenSet.self, from: data)
        XCTAssertEqual(tokens.accessToken, "access")
        XCTAssertEqual(tokens.refreshToken, "refresh")
        XCTAssertEqual(tokens.provider, "google")
        XCTAssertFalse(tokens.needsRefresh(now: Date(timeIntervalSince1970: 1939)))
        XCTAssertTrue(tokens.needsRefresh(now: Date(timeIntervalSince1970: 1940)))
    }

    func testNativeTokenKeychainRecordsAreDashboardScopedAndClearIndependently() {
        let a = UUID()
        let b = UUID()
        let tokensA = NativeOAuthTokenSet(accessToken: "a", refreshToken: "ra", expiresAt: 2_000, provider: "google", userID: "a-user")
        let tokensB = NativeOAuthTokenSet(accessToken: "b", refreshToken: "rb", expiresAt: 3_000, provider: "google", userID: "b-user")
        KeychainHelper.saveNativeOAuthTokens(tokensA, dashboardID: a)
        KeychainHelper.saveNativeOAuthTokens(tokensB, dashboardID: b)

        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: a), tokensA)
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: b), tokensB)
        KeychainHelper.clearNativeOAuthTokens(dashboardID: a)
        XCTAssertNil(KeychainHelper.loadNativeOAuthTokens(dashboardID: a))
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: b), tokensB)
    }

    func testProviderClassificationSupportsOAuthOnlyAndMixedDashboards() {
        let password: [String: Any] = ["name": "basic", "supports_password": true, "supports_session": true]
        let google: [String: Any] = ["name": "google", "supports_password": false, "supports_session": true]
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([google]))
        XCTAssertEqual(HermesProviderCheck.nativeOAuthProvider([google]), "google")
        XCTAssertTrue(HermesProviderCheck.supportsPassword([password, google]))
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([password, google]))
    }

    func testMultipleOAuthProvidersDelegateChoiceToHermes() {
        let google: [String: Any] = ["name": "google", "supports_password": false]
        let oidc: [String: Any] = ["name": "corporate", "supports_password": false]
        XCTAssertTrue(HermesProviderCheck.hasNativeOAuthProvider([google, oidc]))
        XCTAssertNil(HermesProviderCheck.nativeOAuthProvider([google, oidc]))
    }
}
