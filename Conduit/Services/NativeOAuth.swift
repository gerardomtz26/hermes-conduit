//
//  NativeOAuth.swift
//  Conduit
//
//  Hermes brokered OAuth for native iOS clients: SFSafariViewController,
//  loopback callback, PKCE, Keychain tokens, refresh, and bearer REST.
//

import CryptoKit
import Foundation
import Network
import SafariServices
import Security
import SwiftUI

struct NativeOAuthTokenSet: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let provider: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case provider
        case userID = "user_id"
    }

    func needsRefresh(now: Date = Date(), skewSeconds: TimeInterval = 60) -> Bool {
        expiresAt <= 0 || now.timeIntervalSince1970 >= expiresAt - skewSeconds
    }
}

struct NativeOAuthLoginResult {
    let tokens: NativeOAuthTokenSet
    let ticket: String
}

enum NativeOAuthError: LocalizedError, Equatable {
    case invalidURL
    case randomGenerationFailed
    case listenerFailed
    case callbackMalformed
    case callbackRejected
    case stateMismatch
    case tokenResponseMalformed
    case timedOut
    case requestFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The dashboard returned an invalid sign-in URL."
        case .randomGenerationFailed: return "Could not prepare a secure sign-in request."
        case .listenerFailed: return "Could not start the secure sign-in callback."
        case .callbackMalformed: return "The dashboard returned an invalid sign-in response."
        case .callbackRejected: return "The identity provider did not complete sign-in."
        case .stateMismatch: return "The sign-in response failed its security check."
        case .tokenResponseMalformed: return "The dashboard returned invalid authentication tokens."
        case .timedOut: return "Sign-in timed out. Please try again."
        case .requestFailed(let status): return "Dashboard sign-in failed (HTTP \(status))."
        }
    }
}

enum NativeOAuthFlow {
    struct PKCEPair: Equatable {
        let verifier: String
        let challenge: String
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeOAuthError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    static func pkceChallenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func generatePKCE() throws -> PKCEPair {
        let verifier = try randomURLSafe(byteCount: 32)
        return PKCEPair(verifier: verifier, challenge: pkceChallenge(verifier: verifier))
    }

    static func authorizeURL(
        baseURL: String,
        challenge: String,
        redirectURI: String,
        state: String,
        provider: String? = nil
    ) throws -> URL {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              var components = URLComponents(string: "\(normalized)/auth/native/authorize") else {
            throw NativeOAuthError.invalidURL
        }
        var items = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        if let provider, !provider.isEmpty {
            items.append(URLQueryItem(name: "provider", value: provider))
        }
        components.queryItems = items
        guard let url = components.url else { throw NativeOAuthError.invalidURL }
        return url
    }

    static func callbackCode(
        requestTarget: String,
        expectedState: String,
        expectedPort: UInt16
    ) throws -> String {
        guard var components = URLComponents(string: "http://127.0.0.1:\(expectedPort)\(requestTarget)"),
              components.path == "/callback" else {
            throw NativeOAuthError.callbackMalformed
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { throw NativeOAuthError.callbackMalformed }
            values[item.name] = item.value ?? ""
        }
        if values["error"]?.isEmpty == false { throw NativeOAuthError.callbackRejected }
        guard values["state"] == expectedState else { throw NativeOAuthError.stateMismatch }
        guard let code = values["code"], !code.isEmpty else { throw NativeOAuthError.callbackMalformed }
        components.query = nil
        return code
    }
}

struct NativeOAuthAPIClient {
    let baseURL: String
    let cloudflareAccess: CloudflareAccessCredentials?
    private let session: URLSession
    private let redirectDelegate: SecureRedirectDelegate

    init(
        baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.cloudflareAccess = cloudflareAccess
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpCookieStorage = nil
        let redirectDelegate = SecureRedirectDelegate(passwordLoginURL: nil)
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: sessionConfiguration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func exchange(code: String, verifier: String) async throws -> NativeOAuthTokenSet {
        try await tokenRequest(path: "/auth/native/token", body: [
            "code": code,
            "code_verifier": verifier,
        ])
    }

    func refresh(_ tokens: NativeOAuthTokenSet) async throws -> NativeOAuthTokenSet {
        try await tokenRequest(path: "/auth/native/refresh", body: [
            "refresh_token": tokens.refreshToken,
            "provider": tokens.provider,
        ])
    }

    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        accessToken: String,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        var request = try endpointRequest(path: path)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(max(1_000, timeoutMilliseconds)) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.")
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > maxResponseBytes {
            throw DashboardTicketBridgeError.oversizedResponse(limit: maxResponseBytes)
        }
        guard data.count <= maxResponseBytes else {
            throw DashboardTicketBridgeError.oversizedResponse(limit: maxResponseBytes)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DashboardTicketBridgeError.signInRequired
            }
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: Self.errorDetail(data) ?? "Dashboard request failed (\(http.statusCode))."
            )
        }
        guard !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any] { return object }
        if let array = value as? [Any] { return ["_array": array] }
        return ["value": value]
    }

    func mintTicket(accessToken: String) async throws -> String {
        let response = try await requestJSON(
            path: "/api/auth/ws-ticket",
            method: "POST",
            accessToken: accessToken
        )
        guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
            throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
        }
        return ticket
    }

    private func tokenRequest(path: String, body: [String: String]) async throws -> NativeOAuthTokenSet {
        var request = try endpointRequest(path: path)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeOAuthError.requestFailed(status: 0) }
        guard (200...299).contains(http.statusCode) else {
            throw NativeOAuthError.requestFailed(status: http.statusCode)
        }
        guard let tokens = try? JSONDecoder().decode(NativeOAuthTokenSet.self, from: data),
              !tokens.accessToken.isEmpty else {
            throw NativeOAuthError.tokenResponseMalformed
        }
        return tokens
    }

    private func endpointRequest(path: String) throws -> URLRequest {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)\(path)"),
              ConnectionURLPolicy.originMatches(url, expected: URL(string: normalized)) else {
            throw NativeOAuthError.invalidURL
        }
        return cloudflareAccess?.applying(to: URLRequest(url: url)) ?? URLRequest(url: url)
    }

    private static func errorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["detail"] as? String ?? json["error"] as? String ?? json["message"] as? String
    }
}

@MainActor
final class NativeOAuthSession {
    private let dashboardID: UUID
    private let client: NativeOAuthAPIClient
    private var tokens: NativeOAuthTokenSet
    private var refreshTask: Task<NativeOAuthTokenSet, Error>?

    init?(baseURL: String, dashboardID: UUID, cloudflareAccess: CloudflareAccessCredentials?) {
        guard let tokens = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) else { return nil }
        self.dashboardID = dashboardID
        self.tokens = tokens
        self.client = NativeOAuthAPIClient(baseURL: baseURL, cloudflareAccess: cloudflareAccess)
    }

    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        if tokens.needsRefresh() { try await refresh() }
        do {
            return try await client.requestJSON(
                path: path,
                method: method,
                body: body,
                accessToken: tokens.accessToken,
                timeoutMilliseconds: timeoutMilliseconds,
                maxResponseBytes: maxResponseBytes
            )
        } catch DashboardTicketBridgeError.signInRequired {
            try await refresh()
            let normalizedMethod = method.uppercased()
            let replayIsSafe = normalizedMethod == "GET"
                || normalizedMethod == "HEAD"
                || (normalizedMethod == "POST" && path == "/api/auth/ws-ticket")
            guard replayIsSafe else {
                throw DashboardTicketBridgeError.http(
                    status: 401,
                    detail: "Authentication was refreshed; retry this action."
                )
            }
            do {
                return try await client.requestJSON(
                    path: path,
                    method: method,
                    body: body,
                    accessToken: tokens.accessToken,
                    timeoutMilliseconds: timeoutMilliseconds,
                    maxResponseBytes: maxResponseBytes
                )
            } catch DashboardTicketBridgeError.signInRequired {
                KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
                throw DashboardTicketBridgeError.signInRequired
            }
        }
    }

    func mintTicket() async throws -> String {
        let response = try await requestJSON(path: "/api/auth/ws-ticket", method: "POST")
        guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
            throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
        }
        return ticket
    }

    private func refresh() async throws {
        if let refreshTask {
            tokens = try await refreshTask.value
            return
        }
        guard !tokens.refreshToken.isEmpty else {
            KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
            throw DashboardTicketBridgeError.signInRequired
        }
        let current = tokens
        let task = Task { try await client.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            tokens = refreshed
            KeychainHelper.saveNativeOAuthTokens(refreshed, dashboardID: dashboardID)
        } catch NativeOAuthError.requestFailed(let status) where status == 400 || status == 401 || status == 403 {
            KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
            throw DashboardTicketBridgeError.signInRequired
        }
    }
}

final class NativeOAuthLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.milim.conduit.native-oauth-loopback")
    private let expectedState: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var port: UInt16?
    private var terminalResult: Result<String, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start(timeout: TimeInterval = 5 * 60) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in self?.handle(state: state) }
                    listener.newConnectionHandler = { [weak self] connection in self?.handle(connection: connection) }
                    listener.start(queue: self.queue)
                    let timeoutItem = DispatchWorkItem { [weak self] in self?.finish(.failure(NativeOAuthError.timedOut)) }
                    self.timeoutWorkItem = timeoutItem
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                } catch {
                    continuation.resume(throwing: NativeOAuthError.listenerFailed)
                }
            }
        }
    }

    func waitForCallback() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.terminalResult {
                        continuation.resume(with: result)
                    } else {
                        self.callbackContinuation = continuation
                    }
                }
            }
        }, onCancel: { self.stop() })
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener?.port?.rawValue else {
                finish(.failure(NativeOAuthError.listenerFailed))
                return
            }
            port = rawPort
            startContinuation?.resume(returning: rawPort)
            startContinuation = nil
        case .failed:
            if let continuation = startContinuation {
                continuation.resume(throwing: NativeOAuthError.listenerFailed)
                startContinuation = nil
            }
            finish(.failure(NativeOAuthError.listenerFailed))
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "\r\n").first
            let target = requestLine?.split(separator: " ").dropFirst().first.map(String.init)
            let html = "<!doctype html><meta charset=\"utf-8\"><title>Signed in</title><body style=\"font:15px system-ui;margin:3rem;text-align:center\"><h2>✓ Signed in to Hermes</h2><p>You can close this window and return to Conduit.</p>"
            let body = Data(html.utf8)
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(headers.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            guard let target, target.contains("code=") || target.contains("error=") else { return }
            guard let port = self.port else {
                self.finish(.failure(NativeOAuthError.callbackMalformed))
                return
            }
            do {
                self.finish(.success(try NativeOAuthFlow.callbackCode(
                    requestTarget: target,
                    expectedState: self.expectedState,
                    expectedPort: port
                )))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard terminalResult == nil else { return }
        terminalResult = result
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.cancel()
        listener = nil
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: NativeOAuthError.listenerFailed)
        }
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        }
    }
}

@MainActor
final class NativeOAuthLoginModel: ObservableObject {
    @Published private(set) var authorizeURL: URL?
    private var server: NativeOAuthLoopbackServer?

    func run(baseURL: String, cloudflareAccess: CloudflareAccessCredentials?, provider: String?) async throws -> NativeOAuthLoginResult {
        let pkce = try NativeOAuthFlow.generatePKCE()
        let state = try NativeOAuthFlow.randomURLSafe(byteCount: 24)
        let server = NativeOAuthLoopbackServer(expectedState: state)
        self.server = server
        defer {
            server.stop()
            self.server = nil
        }
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        authorizeURL = try NativeOAuthFlow.authorizeURL(
            baseURL: baseURL,
            challenge: pkce.challenge,
            redirectURI: redirectURI,
            state: state,
            provider: provider
        )
        let code = try await server.waitForCallback()
        let client = NativeOAuthAPIClient(baseURL: baseURL, cloudflareAccess: cloudflareAccess)
        let tokens = try await client.exchange(code: code, verifier: pkce.verifier)
        let ticket = try await client.mintTicket(accessToken: tokens.accessToken)
        return NativeOAuthLoginResult(tokens: tokens, ticket: ticket)
    }

    func cancel() {
        server?.stop()
    }
}

struct NativeOAuthSignInSheet: View {
    let baseURL: String
    let cloudflareAccess: CloudflareAccessCredentials?
    let provider: String?
    let onSuccess: (NativeOAuthLoginResult) -> Void
    let onError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = NativeOAuthLoginModel()

    var body: some View {
        Group {
            if let url = model.authorizeURL {
                SafariAuthenticationView(url: url) {
                    model.cancel()
                    dismiss()
                }
                    .ignoresSafeArea()
            } else {
                ProgressView("Preparing secure sign-in…")
            }
        }
        .task {
            do {
                let result = try await model.run(
                    baseURL: baseURL,
                    cloudflareAccess: cloudflareAccess,
                    provider: provider
                )
                onSuccess(result)
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                onError(error)
                dismiss()
            }
        }
        .onDisappear { model.cancel() }
    }
}

private struct SafariAuthenticationView: UIViewControllerRepresentable {
    let url: URL
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onCancel()
        }
    }
}
