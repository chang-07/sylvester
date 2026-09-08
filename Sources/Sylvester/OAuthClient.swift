import AppKit
import CryptoKit
import Foundation
import Network
import Security

// Personal-key OAuth2 (django-oauth-toolkit / "DOT") authorization-code flow with PKCE,
// as a public native client. Identifies as the pre-registered release client when one is
// shipped (releaseClientId), falling back to one-time dynamic client registration; opens
// the dashboard consent page in the browser, captures the redirect on a 127.0.0.1 loopback,
// and exchanges the code for access + refresh tokens.
//
// Endpoints are resolved at runtime from the server's discovery document
// (<apiBase>/.well-known/oauth-authorization-server) rather than hardcoded — prod serves
// them at /oauth/{token,register}/ with the interactive authorize on dashboard.snaptrade.com,
// and discovery keeps us correct across environments.
struct OAuthClient {
    var apiBase = URL(string: "https://api.snaptrade.com")!

    // The pre-registered public client id shipped with release builds. Applies to prod
    // only — an apiBaseURL override (staging) still registers its own client. While this
    // is empty, every install falls back to one-time dynamic client registration.
    static let releaseClientId = ""

    // The server requires an EXACT redirect_uri match incl. port (no ephemeral ports), so we
    // register a few fixed loopback ports and bind whichever is free at sign-in time.
    static let redirectPorts: [UInt16] = [8765, 8919, 9137]
    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/callback" }

    private var discoveryURL: URL {
        URL(string: apiBase.absoluteString + "/.well-known/oauth-authorization-server")!
    }

    struct Metadata {
        let authorize: URL   // interactive consent (browser) — typically the dashboard host
        let token: URL
        let register: URL
        let revoke: URL?     // RFC 7009 — optional in the discovery document
    }

    struct Tokens {
        var accessToken: String
        var refreshToken: String
        var expiry: Date
    }

    enum OAuthError: LocalizedError {
        case message(String)
        // code is the structured OAuth error ("invalid_grant", …) when the server sent
        // one — classification must use it, not the human-readable detail, because
        // servers are free to reword error_description at any time.
        case http(status: Int, code: String?, detail: String)
        var errorDescription: String? {
            switch self {
            case .message(let m): return m
            case .http(let status, _, let detail): return "OAuth \(status): \(detail)"
            }
        }
        private func matches(_ codes: Set<String>) -> Bool {
            switch self {
            case .http(_, let code, let detail):
                if let code { return codes.contains(code) }
                return codes.contains(where: detail.lowercased().contains)
            case .message(let m):
                return codes.contains(where: m.lowercased().contains)
            }
        }
        // The registered client was purged/expired server-side — recoverable by
        // re-running dynamic client registration.
        var isInvalidClient: Bool { matches(["invalid_client"]) }
        // The grant itself is dead (revoked/expired refresh token, dead client) —
        // as opposed to the server or network merely misbehaving.
        var indicatesDeadGrant: Bool { matches(["invalid_grant", "invalid_client"]) }
    }

    // MARK: - Discovery

    func discover() async throws -> Metadata {
        let (data, resp) = try await URLSession.shared.data(from: discoveryURL)
        try Self.checkOK(resp, data)
        struct Doc: Decodable {
            let authorization_endpoint: String
            let token_endpoint: String
            let registration_endpoint: String
            let revocation_endpoint: String?
        }
        let d = try JSONDecoder().decode(Doc.self, from: data)
        guard let a = URL(string: d.authorization_endpoint),
              let t = URL(string: d.token_endpoint),
              let r = URL(string: d.registration_endpoint)
        else { throw OAuthError.message("malformed OAuth discovery document") }
        return Metadata(authorize: a, token: t, register: r,
                        revoke: d.revocation_endpoint.flatMap(URL.init(string:)))
    }

    // MARK: - Dynamic client registration (once; persist the returned client_id)

    func registerClient(clientName: String) async throws -> String {
        let meta = try await discover()
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": Self.redirectPorts.map { Self.redirectURI(port: $0) },
            "token_endpoint_auth_method": "none",   // public client — no secret
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "scope": "read",
        ]
        var req = URLRequest(url: meta.register)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkOK(resp, data)
        struct RegisterResponse: Decodable {
            let clientId: String
            enum CodingKeys: String, CodingKey { case clientId = "client_id" }
        }
        return try JSONDecoder().decode(RegisterResponse.self, from: data).clientId
    }

    // MARK: - Client-id preflight

    // A purged/unknown client id fails at the authorization endpoint INSIDE THE BROWSER —
    // per RFC 6749 the server must not redirect for a client it can't verify, so the
    // loopback never fires and all the app would see is a 5-minute timeout. Probe the
    // authorize URL directly first. Only a positive "this client is unknown" verdict is
    // returned as true; anything ambiguous (offline, a login page, an error that
    // redirected to the loopback) proceeds with the id as-is.
    func clientLooksInvalid(clientId: String) async -> Bool {
        guard let meta = try? await discover(),
              var comps = URLComponents(url: meta.authorize, resolvingAgainstBaseURL: false)
        else { return false }
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: Self.redirectURI(port: Self.redirectPorts[0])),
            .init(name: "scope", value: "read"),
            .init(name: "state", value: Self.randomURLSafe(bytes: 8)),
            .init(name: "code_challenge", value: Self.codeChallenge(for: Self.randomURLSafe(bytes: 32))),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = comps.url else { return false }
        // A fast fail-open check must not stall the sign-in button behind default
        // 60s timeouts, and redirects are never followed: any redirect means the
        // client + redirect_uri were accepted (a login page or an error handed back
        // to the app), and following one could hand the verdict to whatever foreign
        // process happens to hold the loopback port.
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req, delegate: RedirectBlocker())
        else { return false }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) { return false }
        let body = String(data: data.prefix(4096), encoding: .utf8)?.lowercased() ?? ""
        return status == 400 || body.contains("invalid_client") || body.contains("unauthorized_client")
    }

    // MARK: - Interactive authorization

    // Opens the browser, waits for the loopback redirect, and returns freshly-minted tokens.
    func authorize(clientId: String) async throws -> Tokens {
        let meta = try await discover()
        let verifier = Self.randomURLSafe(bytes: 32)          // PKCE code_verifier
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(bytes: 16)

        let receiver = LoopbackReceiver()
        let port = try await receiver.start(ports: Self.redirectPorts)
        let redirectURI = Self.redirectURI(port: port)

        var comps = URLComponents(url: meta.authorize, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "read"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = comps.url else { throw OAuthError.message("couldn't build the authorize URL") }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        let query = try await receiver.waitForCallback(timeout: 300)
        if let err = query["error"] {
            throw OAuthError.message("sign-in was denied (\(query["error_description"] ?? err))")
        }
        guard query["state"] == state else { throw OAuthError.message("state mismatch — sign-in aborted for safety") }
        guard let code = query["code"], !code.isEmpty else { throw OAuthError.message("no authorization code was returned") }

        // The authorization code expires in ~60s, so exchange immediately.
        return try await tokenRequest(endpoint: meta.token, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
    }

    // MARK: - Refresh (refresh token ROTATES — always persist the returned one)

    func refresh(refreshToken: String, clientId: String) async throws -> Tokens {
        let meta = try await discover()
        return try await tokenRequest(endpoint: meta.token, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])
    }

    // MARK: - Revocation (best-effort — never blocks a local sign-out)

    // RFC 7009. The endpoint is optional in discovery; failures are swallowed because the
    // local sign-out must succeed even when the server is unreachable.
    func revoke(token: String, clientId: String) async {
        guard let meta = try? await discover(), let revoke = meta.revoke else { return }
        var req = URLRequest(url: revoke)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(["token": token, "client_id": clientId]).utf8)
        _ = try? await URLSession.shared.data(for: req)
    }

    private func tokenRequest(endpoint: URL, form: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(form).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkOK(resp, data)
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(
            accessToken: t.accessToken,
            // Refresh-grant rotates; fall back to the sent token only if the server omits it.
            refreshToken: t.refreshToken ?? form["refresh_token"] ?? "",
            // When the server omits expires_in, assume a short lifetime — refreshing
            // early is harmless, trusting a token for 10h isn't.
            expiry: Date().addingTimeInterval(TimeInterval(t.expiresIn ?? 3_600))
        )
    }

    // MARK: - Helpers

    private static func checkOK(_ resp: URLResponse, _ data: Data) throws {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = body?["error"] as? String
            let detail = (body?["error_description"] as? String)
                ?? (body?["detail"] as? String)
                ?? code
                ?? String(data: data.prefix(300), encoding: .utf8)
                ?? "unknown error"
            var detailOut = detail
            // Personal sign-in can be disabled account-by-account on the server; say so
            // without leaking internal flag names into user-facing copy.
            let lower = detail.lowercased()
            if status == 404 || status == 403 || lower.contains("not enabled") || lower.contains("access_denied") || lower.contains("personal_oauth") {
                detailOut += " — personal sign-in may not be enabled for this SnapTrade account yet."
            }
            throw OAuthError.http(status: status, code: code, detail: detailOut)
        }
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved
        return params.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&")
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64url(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// Declines every redirect so the probe in clientLooksInvalid judges only the
// authorization server's own first response.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

// One-shot loopback HTTP server that captures a single OAuth redirect on 127.0.0.1.
// A custom URL scheme would be simpler, but the backend only allows http loopback redirects.
private final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.chang.sylvester.oauth-loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: [String: String]?
    private var finished = false

    // Binds the first available port and returns it; throws if none are free.
    func start(ports: [UInt16]) async throws -> UInt16 {
        for port in ports {
            if await tryBind(port: port) { return port }
        }
        let list = ports.map(String.init).joined(separator: ", ")
        throw OAuthClient.OAuthError.message("couldn't open a local callback port (\(list)) — another app may be using them")
    }

    private func tryBind(port: UInt16) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { cont.resume(returning: false); return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            guard let listener = try? NWListener(using: params) else { cont.resume(returning: false); return }
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume(returning: true) }
                case .failed, .cancelled:
                    if !resumed { resumed = true; cont.resume(returning: false) }
                    listener.cancel()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.pendingResult { cont.resume(returning: result); return }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard !self.finished else { return }
                    self.finish(query: nil, error: OAuthClient.OAuthError.message("timed out waiting for the browser sign-in"))
                }
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            var query: [String: String] = [:]
            if let data, let text = String(data: data, encoding: .utf8),
               let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first {
                let parts = requestLine.split(separator: " ")   // GET /callback?code=..&state=.. HTTP/1.1
                if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1\(parts[1])") {
                    for item in comps.queryItems ?? [] { query[item.name] = item.value }
                }
            }
            let success = query["code"] != nil && query["error"] == nil
            self.respond(conn, success: success)
            self.finish(query: query, error: nil)
        }
    }

    private func respond(_ conn: NWConnection, success: Bool) {
        let title = success ? "Sylvester is connected" : "Sign-in didn’t complete"
        let sub = success ? "You can close this tab and return to Sylvester." : "Return to Sylvester and try again."
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Sylvester</title><style>\
        body{font:15px -apple-system,system-ui,sans-serif;margin:0;height:100vh;display:flex;\
        align-items:center;justify-content:center;background:#111418;color:#e6e6e6}\
        .t{font-size:19px;font-weight:600;margin-bottom:6px}.m{color:#9aa0a6}.c{text-align:center}\
        </style></head><body><div class="c"><div class="t">\(title)</div><div class="m">\(sub)</div></div></body></html>
        """
        let bodyData = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // Resolve the pending wait exactly once (or buffer the result if the wait isn't set yet).
    private func finish(query: [String: String]?, error: Error?) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        if let cont = continuation {
            continuation = nil
            if let error { cont.resume(throwing: error) } else { cont.resume(returning: query ?? [:]) }
        } else if let query {
            pendingResult = query
        }
    }
}
