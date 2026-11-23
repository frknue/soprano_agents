import AppKit
import SQLite3
import Testing
@testable import SopranoAgentsCore

struct MCPHTTPProxyTests {
    private actor MockTransport: MCPHTTPTransport {
        struct Exchange: Sendable {
            var request: URLRequest
            var body: String
        }

        private(set) var recorded: [Exchange] = []
        private var handlers: [@Sendable (URLRequest) throws -> (Data, HTTPURLResponse)]

        init(handlers: [@Sendable (URLRequest) throws -> (Data, HTTPURLResponse)]) {
            self.handlers = handlers
        }

        func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            recorded.append(Exchange(request: request, body: body))
            guard !handlers.isEmpty else {
                throw EngineError.message("Unexpected HTTP request in test.")
            }
            let next = handlers.removeFirst()
            return try next(request)
        }
    }

    private func makeOmpDB(provider: String, jsonData: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sa-omp-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("agent.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT DEFAULT NULL,
            identity_key TEXT DEFAULT NULL,
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let sql = "INSERT INTO auth_credentials (provider, credential_type, data) VALUES (?, 'oauth', ?);"
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, provider, -1, transient)
        sqlite3_bind_text(stmt, 2, jsonData, -1, transient)
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        return dbURL
    }

    private func httpResponse(url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func parsesStreamableHTTPSSEPayloadsAndInjectsOmpOAuthToken() async throws {
        let endpoint = URL(string: "https://mcp.asana.com/v2/mcp")!
        let futureMs = (Date().timeIntervalSince1970 + 3600) * 1000
        let dbURL = try makeOmpDB(
            provider: "mcp_oauth:profile:default:https://mcp.asana.com/v2/mcp",
            jsonData: #"{"access":"live-token-123","refresh":"ref-1","expires":\#(futureMs),"tokenUrl":"https://app.asana.com/-/oauth_token","clientId":"cid","clientSecret":"csec"}"#
        )
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let sseBody = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"asana_list_tasks"}]}}

        """
        let transport = MockTransport(handlers: [
            { _ in
                (
                    Data(sseBody.utf8),
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "sess-42"]
                    )!
                )
            },
            { _ in
                (
                    Data(),
                    HTTPURLResponse(url: endpoint, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)!
                )
            },
        ])

        let client = try MCPHTTPProxyClient(endpointURL: endpoint, ompDatabasePath: dbURL.path, transport: transport)
        let responses = await client.forward(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        #expect(responses.count == 1)
        #expect(responses[0]["result"]?["tools"]?.arrayValue?.first?["name"]?.stringValue == "asana_list_tasks")

        let notifResponses = await client.forward(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notifResponses.isEmpty)

        let exchanges = await transport.recorded
        #expect(exchanges.count == 2)
        #expect(exchanges[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer live-token-123")
        #expect(exchanges[1].request.value(forHTTPHeaderField: "Mcp-Session-Id") == "sess-42")
    }

    @Test func refreshesExpiredOmpOAuthTokenAndPersistsItBackToAgentDB() async throws {
        let endpoint = URL(string: "https://mcp.asana.com/v2/mcp")!
        let tokenURL = URL(string: "https://app.asana.com/-/oauth_token")!
        let expiredMs = (Date().timeIntervalSince1970 - 300) * 1000
        let dbURL = try makeOmpDB(
            provider: "mcp_oauth:profile:default:https://mcp.asana.com/v2/mcp",
            jsonData: #"{"access":"stale-token","refresh":"old-refresh","expires":\#(expiredMs),"tokenUrl":"https://app.asana.com/-/oauth_token","clientId":"cid","clientSecret":"csec","resource":"https://mcp.asana.com/v2/mcp"}"#
        )
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let transport = MockTransport(handlers: [
            { req in
                #expect(req.url == tokenURL)
                let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("refresh_token=old-refresh"))
                return (
                    Data(#"{"access_token":"fresh-token-999","refresh_token":"new-refresh-2","expires_in":3600}"#.utf8),
                    HTTPURLResponse(url: tokenURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                )
            },
            { req in
                #expect(req.url == endpoint)
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token-999")
                return (
                    Data(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.utf8),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                )
            },
        ])

        let client = try MCPHTTPProxyClient(endpointURL: endpoint, ompDatabasePath: dbURL.path, transport: transport)
        let responses = await client.forward(["jsonrpc": "2.0", "id": 7, "method": "ping"])
        #expect(responses.count == 1)
        #expect(responses[0]["result"]?["ok"]?.boolValue == true)

        // Verify refreshed token was persisted back to agent.db for omp and other agents.
        let reloaded = try #require(OmpMCPOAuthStore(databasePath: dbURL.path).loadCredential(for: endpoint.absoluteString))
        #expect(reloaded.accessToken == "fresh-token-999")
        #expect(reloaded.refreshToken == "new-refresh-2")
        #expect(reloaded.isFresh())
    }

    @Test func resolveProxyTransportsBridgesOAuthAndAntigravityHeaderServers() throws {
        let dbURL = try makeOmpDB(
            provider: "mcp_oauth:profile:default:https://mcp.asana.com/v2/mcp",
            jsonData: #"{"access":"tok","expires":9999999999999}"#
        )
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let asana = MCPServerSpec(
            name: "asana",
            transport: .http(url: "https://mcp.asana.com/v2/mcp"),
            oauth: MCPOAuthConfig(clientID: "cid")
        )
        let keyed = MCPServerSpec(
            name: "docs",
            transport: .http(url: "https://docs.example/mcp", headers: ["X-Api-Key": "secret"])
        )
        let plain = MCPServerSpec(
            name: "public",
            transport: .http(url: "https://public.example/mcp")
        )

        let agyResolved = ResourceCatalog.resolveProxyTransports(
            [asana, keyed, plain],
            for: .antigravity,
            executablePath: "/app/SopranoAgents",
            includeOmpOAuth: true,
            ompDatabasePath: dbURL.path
        )
        guard case let .stdio(cmd1, args1, _) = agyResolved[0].transport else {
            Issue.record("expected asana to be bridged via http-proxy")
            return
        }
        #expect(cmd1 == "/app/SopranoAgents")
        #expect(args1 == ["mcp", "http-proxy", "--url", "https://mcp.asana.com/v2/mcp", "--omp-db", dbURL.path])

        guard case let .stdio(cmd2, args2, env2) = agyResolved[1].transport else {
            Issue.record("expected header-bearing HTTP MCP to be bridged for Antigravity")
            return
        }
        #expect(cmd2 == "/app/SopranoAgents")
        #expect(args2 == ["mcp", "http-proxy", "--url", "https://docs.example/mcp"])
        #expect(env2["SOPRANO_MCP_HEADERS_JSON"]?.contains("secret") == true)

        guard case .http("https://public.example/mcp", _) = agyResolved[2].transport else {
            Issue.record("expected plain HTTP MCP to remain direct")
            return
        }

        // Codex keeps static-header HTTP direct, but still bridges OAuth HTTP via http-proxy.
        let codexResolved = ResourceCatalog.resolveProxyTransports(
            [asana, keyed],
            for: .codex,
            executablePath: "/app/SopranoAgents",
            includeOmpOAuth: true,
            ompDatabasePath: dbURL.path
        )
        if case .stdio = codexResolved[0].transport {} else { Issue.record("expected asana bridged for Codex") }
        if case .http = codexResolved[1].transport {} else { Issue.record("expected static-header HTTP direct for Codex") }
    }
}
