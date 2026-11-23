import Foundation
import SQLite3

/// Reads and updates `omp`'s OAuth credentials stored in `~/.omp/agent/agent.db`
/// (`auth_credentials` table, `provider = "mcp_oauth:profile:default:<url>"`) so all non-omp
/// providers (Antigravity, Codex, Claude Code, OpenCode) can authenticate against OAuth-protected
/// HTTP MCP servers such as Asana and keep rotated tokens in sync with `omp`.
public struct OmpMCPOAuthStore: Sendable {
    public struct Credential: Sendable, Hashable {
        public var rowID: Int64
        public var provider: String
        public var accessToken: String
        public var refreshToken: String?
        /// Expiry timestamp in milliseconds since Unix epoch, when known.
        public var expiresAtMs: Double?
        public var tokenURL: String?
        public var clientID: String?
        public var clientSecret: String?
        public var resource: String?
        public var rawObject: [String: JSONValue]

        public init(
            rowID: Int64,
            provider: String,
            accessToken: String,
            refreshToken: String? = nil,
            expiresAtMs: Double? = nil,
            tokenURL: String? = nil,
            clientID: String? = nil,
            clientSecret: String? = nil,
            resource: String? = nil,
            rawObject: [String: JSONValue] = [:]
        ) {
            self.rowID = rowID
            self.provider = provider
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAtMs = expiresAtMs
            self.tokenURL = tokenURL
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.resource = resource
            self.rawObject = rawObject
        }

        public func isFresh(now: Date = Date(), leewaySeconds: TimeInterval = 60) -> Bool {
            guard !accessToken.isEmpty else { return false }
            guard let expiresAtMs else { return true }
            let thresholdMs = (now.timeIntervalSince1970 + leewaySeconds) * 1000.0
            return expiresAtMs > thresholdMs
        }
    }

    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public static func defaultDatabasePath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".omp/agent/agent.db")
    }

    /// Fast read-only check for whether `agent.db` holds an OAuth credential for `serverURL`.
    public func hasCredential(for serverURL: String) -> Bool {
        loadCredential(for: serverURL) != nil
    }

    /// Loads the newest non-disabled `mcp_oauth` credential matching `serverURL`.
    public func loadCredential(for serverURL: String) -> Credential? {
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        let variants = urlVariants(serverURL)
        let sql = """
        SELECT id, provider, data
        FROM auth_credentials
        WHERE disabled_cause IS NULL
          AND (provider = ? OR provider = ? OR provider LIKE ? OR provider LIKE ?)
        ORDER BY updated_at DESC, id DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "mcp_oauth:profile:default:\(variants.primary)", -1, transient)
        sqlite3_bind_text(stmt, 2, "mcp_oauth:profile:default:\(variants.alternate)", -1, transient)
        sqlite3_bind_text(stmt, 3, "mcp_oauth:%:\(variants.primary)", -1, transient)
        sqlite3_bind_text(stmt, 4, "mcp_oauth:%:\(variants.alternate)", -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let rowID = sqlite3_column_int64(stmt, 0)
        let provider = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let rawData = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        guard let parsed = try? JSONValue.parse(rawData),
              let object = parsed.objectValue else { return nil }

        let access = object["access"]?.nonEmptyString ?? object["accessToken"]?.nonEmptyString ?? ""
        let refresh = object["refresh"]?.nonEmptyString ?? object["refreshToken"]?.nonEmptyString
        let expires: Double? = {
            if case let .number(value) = object["expires"] { return value }
            if case let .number(value) = object["expiresAt"] { return value }
            return nil
        }()
        return Credential(
            rowID: rowID,
            provider: provider,
            accessToken: access,
            refreshToken: refresh,
            expiresAtMs: expires,
            tokenURL: object["tokenUrl"]?.nonEmptyString ?? object["token_url"]?.nonEmptyString,
            clientID: object["clientId"]?.nonEmptyString ?? object["client_id"]?.nonEmptyString,
            clientSecret: object["clientSecret"]?.nonEmptyString ?? object["client_secret"]?.nonEmptyString,
            resource: object["resource"]?.nonEmptyString,
            rawObject: object
        )
    }

    /// Persists an updated credential JSON payload back into `auth_credentials`.
    public func saveCredential(rowID: Int64, updatedObject: [String: JSONValue]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw EngineError.message("Could not open omp auth database for update.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        let payload = JSONValue.object(updatedObject).jsonString()
        let sql = "UPDATE auth_credentials SET data = ?, updated_at = CAST(strftime('%s','now') AS INTEGER) WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EngineError.message("Could not prepare omp auth update.")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, payload, -1, transient)
        sqlite3_bind_int64(stmt, 2, rowID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EngineError.message("Could not persist refreshed omp OAuth token.")
        }
    }

    private func urlVariants(_ raw: String) -> (primary: String, alternate: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            return (trimmed, String(trimmed.dropLast()))
        }
        return (trimmed, trimmed + "/")
    }
}

/// Transport abstraction for `MCPHTTPProxyClient` so unit tests can mock HTTP/SSE and OAuth refresh.
public protocol MCPHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}

public struct URLSessionMCPHTTPTransport: MCPHTTPTransport {
    private let session: URLSession

    public init(timeoutSeconds: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = max(timeoutSeconds * 2, 120)
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.message("MCP server returned a non-HTTP response.")
        }
        return (data, http)
    }
}

/// Bridges stdio JSON-RPC MCP requests to a Streamable HTTP MCP endpoint (`application/json` or
/// `text/event-stream` SSE responses), injecting and auto-refreshing OAuth bearer tokens from
/// `omp`'s `agent.db` when configured.
public actor MCPHTTPProxyClient {
    public let endpointURL: URL
    private let staticHeaders: [String: String]
    private let oauthStore: OmpMCPOAuthStore?
    private let oauthConfig: MCPOAuthConfig?
    private let transport: any MCPHTTPTransport
    private let now: @Sendable () -> Date

    private var sessionID: String?
    private var negotiatedProtocolVersion: String?
    private var cachedCredential: OmpMCPOAuthStore.Credential?

    public init(
        endpointURL: URL,
        staticHeaders: [String: String] = [:],
        ompDatabasePath: String? = nil,
        oauthConfig: MCPOAuthConfig? = nil,
        transport: any MCPHTTPTransport = URLSessionMCPHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard let scheme = endpointURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw EngineError.message("MCP HTTP proxy only supports http:// and https:// endpoints.")
        }
        self.endpointURL = endpointURL
        self.staticHeaders = staticHeaders
        self.oauthStore = ompDatabasePath.map { OmpMCPOAuthStore(databasePath: $0) }
        self.oauthConfig = oauthConfig
        self.transport = transport
        self.now = now
    }

    /// Forwards one JSON-RPC message (request or notification) and returns any JSON-RPC responses.
    public func forward(_ message: JSONValue) async -> [JSONValue] {
        let requestID = message["id"]
        do {
            let token = await resolveBearerToken(forceRefresh: false)
            var (data, response) = try await post(message, bearerToken: token)

            if response.statusCode == 401, oauthStore != nil, !hasStaticAuthorizationHeader {
                if let refreshed = await resolveBearerToken(forceRefresh: true), !refreshed.isEmpty {
                    (data, response) = try await post(message, bearerToken: refreshed)
                }
            }

            if let sid = headerValue("Mcp-Session-Id", in: response), !sid.isEmpty {
                sessionID = sid
            }

            guard (200..<300).contains(response.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let snippet = detail.isEmpty ? "HTTP \(response.statusCode)" : "HTTP \(response.statusCode): \(String(detail.prefix(300)))"
                return errorResponse(id: requestID, message: "MCP HTTP server error (\(snippet)).")
            }

            if response.statusCode == 202 || data.isEmpty {
                return []
            }

            let contentType = headerValue("Content-Type", in: response)?.lowercased() ?? ""
            let responses: [JSONValue]
            if contentType.contains("text/event-stream") {
                guard let text = String(data: data, encoding: .utf8) else { return [] }
                responses = Self.parseSSEPayloads(text)
            } else {
                guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    return []
                }
                if let parsed = try? JSONValue.parse(text) {
                    if case let .array(items) = parsed { responses = items } else { responses = [parsed] }
                } else {
                    let sse = Self.parseSSEPayloads(text)
                    if !sse.isEmpty { responses = sse }
                    else { return errorResponse(id: requestID, message: "MCP server returned invalid JSON.") }
                }
            }
            for item in responses {
                if let version = item["result"]?["protocolVersion"]?.nonEmptyString {
                    negotiatedProtocolVersion = version
                }
            }
            return responses
        } catch {
            return errorResponse(id: requestID, message: "MCP HTTP request failed: \(error.localizedDescription)")
        }
    }

    /// Parses JSON-RPC objects embedded in an SSE `text/event-stream` response body.
    public static func parseSSEPayloads(_ text: String) -> [JSONValue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var results: [JSONValue] = []
        var dataLines: [String] = []

        func flush() {
            guard !dataLines.isEmpty else { return }
            let joined = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            dataLines.removeAll(keepingCapacity: true)
            guard !joined.isEmpty, joined != "[DONE]",
                  let parsed = try? JSONValue.parse(joined) else { return }
            if case let .array(items) = parsed {
                results.append(contentsOf: items)
            } else {
                results.append(parsed)
            }
        }

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
        }
        flush()
        return results
    }

    // MARK: - HTTP & OAuth helpers

    private var hasStaticAuthorizationHeader: Bool {
        staticHeaders.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    }

    private func post(_ message: JSONValue, bearerToken: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in staticHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let bearerToken, !bearerToken.isEmpty, !hasStaticAuthorizationHeader {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        let protocolVersion = message["params"]?["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.nonEmptyString
            ?? message["params"]?["protocolVersion"]?.nonEmptyString
            ?? negotiatedProtocolVersion
        if let protocolVersion, !protocolVersion.isEmpty {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = Data(message.jsonString().utf8)
        return try await transport.send(request)
    }

    private func resolveBearerToken(forceRefresh: Bool) async -> String? {
        guard let oauthStore, !hasStaticAuthorizationHeader else { return nil }
        let currentNow = now()
        if !forceRefresh, let cached = cachedCredential, cached.isFresh(now: currentNow) {
            return cached.accessToken
        }

        // Always re-read from SQLite before refreshing in case omp or another agent refreshed it.
        guard let stored = oauthStore.loadCredential(for: endpointURL.absoluteString) else {
            return cachedCredential?.accessToken
        }
        if !forceRefresh, stored.isFresh(now: currentNow) {
            cachedCredential = stored
            return stored.accessToken
        }

        // If `forceRefresh` was requested due to a 401 and SQLite already has a DIFFERENT access
        // token than the one that just failed, try that newer token before calling the OAuth server.
        if forceRefresh,
           let previous = cachedCredential?.accessToken,
           !stored.accessToken.isEmpty,
           stored.accessToken != previous,
           stored.isFresh(now: currentNow) {
            cachedCredential = stored
            return stored.accessToken
        }

        if let refreshed = await refreshToken(stored, store: oauthStore, now: currentNow) {
            cachedCredential = refreshed
            return refreshed.accessToken
        }

        cachedCredential = stored
        return stored.accessToken.isEmpty ? nil : stored.accessToken
    }

    private func refreshToken(
        _ credential: OmpMCPOAuthStore.Credential,
        store: OmpMCPOAuthStore,
        now: Date
    ) async -> OmpMCPOAuthStore.Credential? {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty,
              let tokenURLString = credential.tokenURL ?? oauthConfig?.tokenURL,
              let tokenURL = URL(string: tokenURLString),
              let scheme = tokenURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        if let clientID = credential.clientID ?? oauthConfig?.clientID, !clientID.isEmpty {
            fields.append(("client_id", clientID))
        }
        if let clientSecret = credential.clientSecret ?? oauthConfig?.clientSecret, !clientSecret.isEmpty {
            fields.append(("client_secret", clientSecret))
        }
        if let resource = credential.resource, !resource.isEmpty {
            fields.append(("resource", resource))
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(fields).utf8)

        guard let (data, response) = try? await transport.send(request),
              (200..<300).contains(response.statusCode),
              let body = String(data: data, encoding: .utf8),
              let json = try? JSONValue.parse(body),
              let newAccess = json["access_token"]?.nonEmptyString else {
            return nil
        }

        let newRefresh = json["refresh_token"]?.nonEmptyString ?? refreshToken
        let expiresIn = json["expires_in"]?.intValue.map(Double.init)
            ?? {
                if case let .number(n) = json["expires_in"] { return n }
                return 3600
            }()
        let newExpiresMs = (now.timeIntervalSince1970 + max(60, expiresIn)) * 1000.0

        var updatedObject = credential.rawObject
        updatedObject["access"] = .string(newAccess)
        updatedObject["refresh"] = .string(newRefresh)
        updatedObject["expires"] = .number(newExpiresMs)

        try? store.saveCredential(rowID: credential.rowID, updatedObject: updatedObject)
        return OmpMCPOAuthStore.Credential(
            rowID: credential.rowID,
            provider: credential.provider,
            accessToken: newAccess,
            refreshToken: newRefresh,
            expiresAtMs: newExpiresMs,
            tokenURL: tokenURLString,
            clientID: credential.clientID ?? oauthConfig?.clientID,
            clientSecret: credential.clientSecret ?? oauthConfig?.clientSecret,
            resource: credential.resource,
            rawObject: updatedObject
        )
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if let keyStr = key as? String, keyStr.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    private func errorResponse(id: JSONValue?, message: String) -> [JSONValue] {
        guard let id else { return [] }
        return [[
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": .number(-32000),
                "message": .string(message),
            ],
        ]]
    }

    private static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

/// Runs `MCPHTTPProxyClient` over newline-delimited stdio (`SopranoAgents mcp http-proxy`).
public enum MCPHTTPProxyStdioRunner {
    public static func run(
        url: URL,
        staticHeaders: [String: String] = [:],
        ompDatabasePath: String? = nil,
        oauthConfig: MCPOAuthConfig? = nil
    ) async {
        guard let client = try? MCPHTTPProxyClient(
            endpointURL: url,
            staticHeaders: staticHeaders,
            ompDatabasePath: ompDatabasePath,
            oauthConfig: oauthConfig
        ) else {
            fputs("Invalid MCP HTTP proxy URL: \(url.absoluteString)\n", stderr)
            return
        }

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let message = try? JSONValue.parse(trimmed) else { continue }
            let responses = await client.forward(message)
            for response in responses {
                let text = response.jsonString() + "\n"
                if let bytes = text.data(using: .utf8) {
                    FileHandle.standardOutput.write(bytes)
                }
            }
        }
    }
}
