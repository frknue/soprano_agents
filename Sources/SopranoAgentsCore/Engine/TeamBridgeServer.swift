import Foundation
import Network

/// Transport interface used by `TeamMCPDispatcher` so MCP tool routing can be unit-tested without
/// opening sockets, and backed by `TeamBridgeServer` over authenticated loopback HTTP in production.
public protocol TeamBridgeClient: Sendable {
    func listTools(threadID: String) async throws -> [HostToolDefinition]
    func callTool(threadID: String, name: String, arguments: JSONValue) async throws -> HostToolResult
}

/// Pure JSON-RPC 2.0 MCP dispatcher serving Soprano Agents' Team & Memory tools to non-omp
/// providers (Codex, Claude Code, Antigravity, OpenCode).
public actor TeamMCPDispatcher {
    private let threadID: String
    private let client: any TeamBridgeClient

    public init(threadID: String, client: any TeamBridgeClient) {
        self.threadID = threadID
        self.client = client
    }

    public func handleJSONRPC(_ message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.stringValue else { return nil }
        let id = message["id"]
        let params = message["params"] ?? .object([:])

        switch method {
        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "ping":
            guard let id else { return nil }
            return rpcResult(id: id, result: .object([:]))

        case "initialize":
            guard let id else { return nil }
            let protocolVersion = params["protocolVersion"]?.stringValue ?? "2024-11-05"
            return rpcResult(id: id, result: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("soprano-team"),
                    "version": .string("1.0.0"),
                ]),
            ]))

        case "tools/list":
            guard let id else { return nil }
            do {
                let definitions = try await client.listTools(threadID: threadID)
                let tools: [JSONValue] = definitions.map { def in
                    .object([
                        "name": .string(def.name),
                        "description": .string(def.description),
                        "inputSchema": def.parameters,
                    ])
                }
                return rpcResult(id: id, result: .object(["tools": .array(tools)]))
            } catch {
                return rpcError(id: id, code: -32000, message: error.localizedDescription)
            }

        case "tools/call":
            guard let id else { return nil }
            let name = params["name"]?.stringValue ?? ""
            let arguments = params["arguments"] ?? .object([:])
            do {
                let result = try await client.callTool(threadID: threadID, name: name, arguments: arguments)
                return rpcResult(id: id, result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
                    "isError": .bool(result.isError),
                ]))
            } catch {
                return rpcResult(id: id, result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(error.localizedDescription)])]),
                    "isError": .bool(true),
                ]))
            }

        default:
            guard let id else { return nil }
            return rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func rpcResult(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func rpcError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }
}

/// HTTP client talking to the running Soprano Agents app's loopback `TeamBridgeServer`.
public struct HTTPTeamBridgeClient: TeamBridgeClient {
    public let endpoint: String
    public let token: String

    public init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    public func listTools(threadID: String) async throws -> [HostToolDefinition] {
        let data = try await post(path: "/tools/list", body: ["threadID": .string(threadID)])
        return try JSONDecoder().decode([HostToolDefinition].self, from: data)
    }

    public func callTool(threadID: String, name: String, arguments: JSONValue) async throws -> HostToolResult {
        let data = try await post(path: "/tools/call", body: [
            "threadID": .string(threadID),
            "name": .string(name),
            "arguments": arguments,
        ])
        let decoded = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        return HostToolResult(
            text: decoded["text"]?.stringValue ?? "",
            isError: decoded["isError"]?.boolValue ?? false
        )
    }

    private func post(path: String, body: [String: JSONValue]) async throws -> Data {
        guard let url = URL(string: endpoint + path) else {
            throw EngineError.message("Invalid team bridge endpoint: \(endpoint)")
        }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(decoding: data, as: UTF8.self)
            throw EngineError.message("Team bridge request failed: \(msg)")
        }
        return data
    }
}

/// Runs `TeamMCPDispatcher` over stdio (`SopranoAgents mcp team`).
public enum TeamMCPStdioRunner {
    public static func run(endpoint: String, token: String, threadID: String) async {
        let client = HTTPTeamBridgeClient(endpoint: endpoint, token: token)
        let dispatcher = TeamMCPDispatcher(threadID: threadID, client: client)
        let encoder = JSONEncoder()
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let message = try? JSONValue.parse(trimmed) else { continue }
            if let response = await dispatcher.handleJSONRPC(message),
               let data = try? encoder.encode(response),
               var text = String(data: data, encoding: .utf8) {
                text.append("\n")
                if let bytes = text.data(using: .utf8) {
                    FileHandle.standardOutput.write(bytes)
                }
            }
        }
    }
}

// MARK: - Authenticated Loopback Bridge Server (127.0.0.1 ephemeral port)

/// Lightweight loopback HTTP server hosted inside `AgentEngine` so `SopranoAgents mcp team` child
/// processes spawned by Codex, Claude Code, Antigravity or OpenCode can invoke team & memory tools
/// against the live engine state. Strictly bound to `127.0.0.1` with a per-run random bearer token.
public final class TeamBridgeServer: @unchecked Sendable {
    public typealias ListHandler = @Sendable (_ threadID: String) async -> [HostToolDefinition]
    public typealias CallHandler = @Sendable (_ threadID: String, _ name: String, _ arguments: JSONValue) async -> HostToolResult

    public let token: String
    private let listHandler: ListHandler
    private let callHandler: CallHandler
    private let queue = DispatchQueue(label: "com.soprano.agents.team-bridge")
    private var listener: NWListener?
    private let lock = NSLock()
    private var boundPort: UInt16?

    public var endpoint: String? {
        lock.withLock {
            boundPort.map { "http://127.0.0.1:\($0)" }
        }
    }

    public init(listHandler: @escaping ListHandler, callHandler: @escaping CallHandler) {
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.listHandler = listHandler
        self.callHandler = callHandler
    }

    public func start() throws -> String {
        if let existing = endpoint { return existing }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        final class ErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Error?
            func set(_ error: Error) { lock.withLock { value = error } }
            func get() -> Error? { lock.withLock { value } }
        }
        let errorBox = ErrorBox()

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    self?.lock.withLock { self?.boundPort = port }
                }
                ready.signal()
            case let .failed(error):
                errorBox.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3.0)
        if let startError = errorBox.get() { throw startError }
        guard let url = endpoint else {
            throw EngineError.message("Team bridge server did not bind a loopback port.")
        }
        return url
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock { boundPort = nil }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let parsed = Self.parseHTTPRequest(accumulated) {
                Task {
                    await self.dispatch(parsed, on: connection)
                }
                return
            }
            if isComplete || error != nil || accumulated.count > 4 * 1024 * 1024 {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    private func dispatch(_ request: ParsedHTTPRequest, on connection: NWConnection) async {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            sendResponse(status: "401 Unauthorized", body: Data("{\"error\":\"unauthorized\"}".utf8), on: connection)
            return
        }
        guard let payload = try? JSONValue.parse(String(decoding: request.body, as: UTF8.self)),
              let threadID = payload["threadID"]?.stringValue
        else {
            sendResponse(status: "400 Bad Request", body: Data("{\"error\":\"invalid payload\"}".utf8), on: connection)
            return
        }

        switch request.path {
        case "/tools/list":
            let defs = await listHandler(threadID)
            let data = (try? JSONEncoder().encode(defs)) ?? Data("[]".utf8)
            sendResponse(status: "200 OK", body: data, on: connection)

        case "/tools/call":
            let name = payload["name"]?.stringValue ?? ""
            let args = payload["arguments"] ?? .object([:])
            let result = await callHandler(threadID, name, args)
            let bodyValue: JSONValue = .object([
                "text": .string(result.text),
                "isError": .bool(result.isError),
            ])
            let data = (try? JSONEncoder().encode(bodyValue)) ?? Data("{}".utf8)
            sendResponse(status: "200 OK", body: data, on: connection)

        default:
            sendResponse(status: "404 Not Found", body: Data("{\"error\":\"not found\"}".utf8), on: connection)
        }
    }

    private func sendResponse(status: String, body: Data, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private struct ParsedHTTPRequest {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private static func parseHTTPRequest(_ data: Data) -> ParsedHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let headerData = data[..<range.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let body = Data(data[range.upperBound...])
        guard body.count >= contentLength else { return nil }
        return ParsedHTTPRequest(path: path, headers: headers, body: body.prefix(contentLength))
    }
}
