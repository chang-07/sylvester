import Foundation
import CryptoKit

struct SnapTradeError: LocalizedError {
    var status: Int
    var detail: String
    var errorDescription: String? { "SnapTrade \(status): \(detail)" }
}

struct SnapTradeClient {
    // Partner keys sign every request (HMAC over clientId/consumerKey); personal keys send
    // an OAuth bearer token instead, which the server resolves to the single personal user
    // (no clientId/userId/userSecret/Signature are sent).
    enum Auth {
        case partner(clientId: String, consumerKey: String)
        case bearer(accessToken: String)
    }
    var auth: Auth
    var baseURL = URL(string: "https://api.snaptrade.com")!

    init(clientId: String, consumerKey: String) {
        auth = .partner(clientId: clientId, consumerKey: consumerKey)
    }
    init(bearerToken: String) {
        auth = .bearer(accessToken: bearerToken)
    }

    // MARK: - Signing
    //
    // Signature = base64(HMAC-SHA256(consumerKey,
    //   canonicalJSON({"content": <body or null>, "path": path, "query": queryString})))
    // Canonical JSON must match python json.dumps(..., separators=(",",":"), sort_keys=True):
    // sorted keys, no whitespace, unescaped forward slashes.

    private func canonicalJSON(_ obj: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func sign(path: String, query: String, content: Any?, consumerKey: String) throws -> String {
        let sigObject: [String: Any] = [
            "content": content ?? NSNull(),
            "path": path,
            "query": query,
        ]
        let payload = try canonicalJSON(sigObject)
        let mac = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: Data(consumerKey.utf8))
        )
        return Data(mac).base64EncodedString()
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    // Params are signed as the exact query string sent; the server re-encodes with
    // python urlencode/quote_plus, so match its escaping (space -> +).
    private func queryString(_ params: [(String, String)]) -> String {
        params
            .sorted { $0.0 < $1.0 }
            .map { key, value in
                let v = (value.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? value)
                    .replacingOccurrences(of: "%20", with: "+")
                return "\(key)=\(v)"
            }
            .joined(separator: "&")
    }

    // MARK: - Transport

    // authParams (userId/userSecret) are sent + signed under partner auth, but dropped under
    // bearer auth (the token resolves the user). queryParams (startDate/limit/…) are always sent.
    private func request(
        method: String,
        path: String,
        authParams: [(String, String)] = [],
        queryParams: [(String, String)] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        var req: URLRequest

        switch auth {
        case .partner(let clientId, let consumerKey):
            var params = queryParams + authParams
            params.append(("clientId", clientId))
            params.append(("timestamp", String(Int(Date().timeIntervalSince1970))))
            let query = queryString(params)
            req = URLRequest(url: URL(string: "\(baseURL.absoluteString)\(path)?\(query)")!)
            req.httpMethod = method
            // Server signs falsy bodies as null, so an empty {} must be signed as null too.
            let signContent: Any? = (body?.isEmpty ?? true) ? nil : body
            req.setValue(
                try sign(path: path, query: query, content: signContent, consumerKey: consumerKey),
                forHTTPHeaderField: "Signature"
            )
        case .bearer(let accessToken):
            let query = queryString(queryParams)
            let url = query.isEmpty ? "\(baseURL.absoluteString)\(path)" : "\(baseURL.absoluteString)\(path)?\(query)"
            req = URLRequest(url: URL(string: url)!)
            req.httpMethod = method
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try canonicalJSON(body)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let err = try? JSONDecoder().decode(STErrorResponse.self, from: data)
            var detail = err?.detail
                ?? err?.message
                ?? String(data: data.prefix(300), encoding: .utf8)
                ?? "unknown error"
            // Unknown clientId returns this same message as a real mismatch.
            if detail.contains("Unable to verify signature") {
                detail += " — check clientId/consumerKey (an unknown clientId returns this exact error)"
            }
            throw SnapTradeError(status: status, detail: detail)
        }
        return data
    }

    private func userParams(_ userId: String, _ userSecret: String) -> [(String, String)] {
        [("userId", userId), ("userSecret", userSecret)]
    }

    // MARK: - Endpoints

    // Cheapest partner-scope call — used to validate a pasted clientId/consumerKey pair.
    func listUsers() async throws -> [String] {
        let data = try await request(method: "GET", path: "/api/v1/snapTrade/listUsers")
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func registerUser(userId: String) async throws -> STRegisterUserResponse {
        let data = try await request(
            method: "POST",
            path: "/api/v1/snapTrade/registerUser",
            body: ["userId": userId]
        )
        return try JSONDecoder().decode(STRegisterUserResponse.self, from: data)
    }

    // Per-account activities — the partner-level /activities endpoint is 410 Gone
    // for partners created after its cutoff.
    func accountActivities(
        accountId: String, userId: String, userSecret: String, startDate: String
    ) async throws -> [STActivity] {
        let data = try await request(
            method: "GET",
            path: "/api/v1/accounts/\(accountId)/activities",
            authParams: userParams(userId, userSecret),
            queryParams: [("startDate", startDate), ("limit", "250")]
        )
        return try JSONDecoder().decode(STActivityPage.self, from: data).data
    }

    // Removes a connection and all its accounts from SnapTrade.
    func deleteAuthorization(id: String, userId: String, userSecret: String) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/api/v1/authorizations/\(id)",
            authParams: userParams(userId, userSecret)
        )
    }

    func listAuthorizations(userId: String, userSecret: String) async throws -> [STAuthorization] {
        let data = try await request(
            method: "GET",
            path: "/api/v1/authorizations",
            authParams: userParams(userId, userSecret)
        )
        return try JSONDecoder().decode([STAuthorization].self, from: data)
    }

    // Mints a connection-portal URL; open it in the browser to link/fix a brokerage.
    // Pass reconnect to deep-link the portal's reconnect flow for a broken connection.
    func connectURL(userId: String, userSecret: String, reconnect: String? = nil) async throws -> URL {
        var body: [String: Any] = [:]
        if let reconnect { body["reconnect"] = reconnect }
        let data = try await request(
            method: "POST",
            path: "/api/v1/snapTrade/login",
            authParams: userParams(userId, userSecret),
            body: body
        )
        let resp = try JSONDecoder().decode(STLoginResponse.self, from: data)
        guard let url = URL(string: resp.redirectURI) else {
            throw SnapTradeError(status: 200, detail: "bad redirectURI: \(resp.redirectURI)")
        }
        return url
    }

    func listAccounts(userId: String, userSecret: String) async throws -> [STAccount] {
        let data = try await request(
            method: "GET",
            path: "/api/v1/accounts",
            authParams: userParams(userId, userSecret)
        )
        return try JSONDecoder().decode([STAccount].self, from: data)
    }

    // Single-account read — unlike listAccounts, the server live-fetches balance.total here.
    func accountDetail(accountId: String, userId: String, userSecret: String) async throws -> STAccount {
        let data = try await request(
            method: "GET",
            path: "/api/v1/accounts/\(accountId)",
            authParams: userParams(userId, userSecret)
        )
        return try JSONDecoder().decode(STAccount.self, from: data)
    }

    func positions(accountId: String, userId: String, userSecret: String) async throws -> [STPosition] {
        let data = try await request(
            method: "GET",
            path: "/api/v1/accounts/\(accountId)/positions",
            authParams: userParams(userId, userSecret)
        )
        return try JSONDecoder().decode([STPosition].self, from: data)
    }

    func balances(accountId: String, userId: String, userSecret: String) async throws -> [STBalance] {
        let data = try await request(
            method: "GET",
            path: "/api/v1/accounts/\(accountId)/balances",
            authParams: userParams(userId, userSecret)
        )
        return try JSONDecoder().decode([STBalance].self, from: data)
    }
}
