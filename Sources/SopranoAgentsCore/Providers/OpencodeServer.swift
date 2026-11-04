import Foundation

/// What OpenCode sessions need from the server: `OpencodeServer`, or a fake in tests.
public protocol OpencodeTransport: Sendable {
    /// `method path` with JSON `body`; the decoded response (`.null` for 204).
    func request(_ method: String, _ path: String, query: [String: String], body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    /// `GET path` scoped to `directory` → its `data` list.
    func list(_ path: String, directory: String, retryWhileEmpty: Bool) async throws -> JSONValue
    /// The server-sent event payloads, starting with `server.connected`.
    func events() async throws -> AsyncThrowingStream<JSONValue, any Error>
}

extension OpencodeTransport {
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil, timeout: TimeInterval = OpencodeServer.requestTimeout) async throws -> JSONValue {
        try await request(method, path, query: query, body: body, timeout: timeout)
    }

    func list(_ path: String, directory: String) async throws -> JSONValue {
        try await list(path, directory: directory, retryWhileEmpty: false)
    }
}

/// The OpenCode server the app talks to: OpenCode's background service (`opencode serve
/// --service`), the same server the `opencode` TUI and CLI use, so sessions are shared with them.
///
/// Connecting goes through the CLI, which finds the service and starts it when it is not
/// running: `opencode api server.info` (its `urls[0]`), then `opencode api server.pair` (a one-time
/// code), redeemed at `GET <url>/auth/connect/<code>` for a token. Requests authenticate with HTTP
/// Basic `opencode:<token>`. A 401 or a refused connection (the service restarted, maybe on
/// another port) pairs again once and retries.
///
/// Requests are JSON (`/api/...`, the v2 HTTP API); errors become `ProviderError.rpc` with the
/// server's message. `events()` is the server-sent event stream (`GET /api/event`): one JSON
/// object per `data:` line (`{id, type, data, ...}`), starting with `server.connected`.
public actor OpencodeServer: OpencodeTransport {
    public struct Endpoint: Sendable, Hashable {
        public var url: URL
        /// `Basic <base64(opencode:<token>)>`.
        public var authorization: String
    }

    public static let requestTimeout: TimeInterval = 60
    /// `opencode api …` may start the service first.
    static let cliTimeout: TimeInterval = 60

    private let executablePath: @Sendable () -> String?
    /// Pairs with the service through the `opencode` executable (tests stub it).
    private let pairing: @Sendable (String) async throws -> Endpoint
    private let urlSession: URLSession
    private let streamSession: URLSession
    private var endpoint: Endpoint?
    private var connecting: Task<Endpoint, any Error>?

    /// `executablePath` returns the settings override, read on every connect; nil = search PATH.
    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.init(executablePath: executablePath, pairing: { try await Self.pair(executable: $0) })
    }

    init(executablePath: @escaping @Sendable () -> String?, pairing: @escaping @Sendable (String) async throws -> Endpoint) {
        self.executablePath = executablePath
        self.pairing = pairing
        let requests = URLSessionConfiguration.ephemeral
        requests.timeoutIntervalForRequest = Self.requestTimeout
        requests.urlCache = nil
        urlSession = URLSession(configuration: requests)
        // The event stream idles between events; the server's heartbeats keep it alive.
        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = 600
        stream.timeoutIntervalForResource = 60 * 60 * 24 * 7
        stream.urlCache = nil
        streamSession = URLSession(configuration: stream)
    }

    /// The `opencode` executable (settings override or PATH), or `notInstalled`.
    nonisolated func executable() throws -> String {
        let explicit = executablePath()
        guard let path = ExecutableLocator.locate(ProviderKind.opencode.executableName, explicitPath: explicit) else {
            throw ProviderError.notInstalled(.opencode, path: explicit)
        }
        return path
    }

    // MARK: - Requests

    /// `method path` with JSON `body`; returns the decoded response (`.null` for 204).
    public func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: JSONValue? = nil,
        timeout: TimeInterval = OpencodeServer.requestTimeout
    ) async throws -> JSONValue {
        var current = try await connect(refresh: false)
        var retried = false
        while true {
            let request = Self.makeRequest(current, method: method, path: path, query: query, body: body, timeout: timeout)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch let error as URLError where !retried && Self.isUnreachable(error) {
                retried = true
                current = try await connect(refresh: true)
                continue
            } catch let error as URLError {
                throw ProviderError.message("OpenCode did not answer \(method) \(path): \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !retried {
                retried = true
                current = try await connect(refresh: true)
                continue
            }
            guard (200..<300).contains(status) else {
                throw ProviderError.rpc(method: "\(method) \(path)", code: status, message: Self.errorMessage(data, status: status))
            }
            guard !data.isEmpty else { return .null }
            do {
                return try JSONValue.parse(String(decoding: data, as: UTF8.self))
            } catch {
                throw ProviderError.invalidOutput("OpenCode answered \(method) \(path) with invalid JSON.")
            }
        }
    }

    /// `GET path` scoped to `directory` (`location[directory]`) → its `data` list. OpenCode loads
    /// a folder on first use and answers an empty list meanwhile: lists that are never empty
    /// once loaded (`/api/command`, which has built-ins; `/api/model`) are asked again for up to
    /// 1.5 s.
    public func list(_ path: String, directory: String, retryWhileEmpty: Bool = false) async throws -> JSONValue {
        let query = ["location[directory]": directory]
        var data = try await request("GET", path, query: query)["data"] ?? []
        var attempts = 0
        while retryWhileEmpty, data.arrayValue?.isEmpty == true, attempts < 5 {
            attempts += 1
            try await Task.sleep(nanoseconds: 300_000_000)
            data = try await request("GET", path, query: query)["data"] ?? []
        }
        return data
    }

    /// The server's event stream, opened before it returns: a refused connection or a 401 (the
    /// service restarted, maybe on another port) pairs again once, like `request`. The stream
    /// finishes when the connection ends (with an error when it broke); cancelling the
    /// consumer closes the connection.
    public func events() async throws -> AsyncThrowingStream<JSONValue, any Error> {
        var current = try await connect(refresh: false)
        var retried = false
        while true {
            var request = Self.makeRequest(current, method: "GET", path: "/api/event", query: [:], body: nil, timeout: 600)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await streamSession.bytes(for: request)
            } catch let error as URLError where !retried && Self.isUnreachable(error) {
                retried = true
                current = try await connect(refresh: true)
                continue
            } catch let error as URLError {
                throw ProviderError.message("OpenCode's event stream did not open: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !retried {
                bytes.task.cancel()
                retried = true
                current = try await connect(refresh: true)
                continue
            }
            guard status == 200 else {
                bytes.task.cancel()
                throw ProviderError.rpc(method: "GET /api/event", code: status, message: "OpenCode refused the event stream.")
            }
            return Self.eventStream(bytes)
        }
    }

    private static func eventStream(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<JSONValue, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var decoder = OpencodeEventStreamDecoder()
                    for try await line in bytes.lines {
                        if let event = decoder.decode(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
    }

    // MARK: - Connecting

    /// The cached endpoint, or a fresh pairing (`refresh`, or none yet). Concurrent callers
    /// share one pairing.
    func connect(refresh: Bool) async throws -> Endpoint {
        if !refresh, let endpoint { return endpoint }
        if let connecting { return try await connecting.value }
        let executable = try executable()
        let pairing = pairing
        let task = Task { try await pairing(executable) }
        connecting = task
        defer { connecting = nil }
        let paired = try await task.value
        endpoint = paired
        return paired
    }

    /// `opencode api server.info` → URL, `opencode api server.pair` → code, redeemed for a token.
    private static func pair(executable: String) async throws -> Endpoint {
        let info = try await api(executable, "server.info")
        guard let address = info["urls"]?.arrayValue?.first?.stringValue, let url = URL(string: address) else {
            throw ProviderError.invalidOutput("OpenCode did not report its server address.")
        }
        guard let code = try await api(executable, "server.pair")["code"]?.nonEmptyString else {
            throw ProviderError.invalidOutput("OpenCode did not hand out a pairing code.")
        }
        var request = URLRequest(url: url.appending(path: "auth/connect/\(code)"), timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let token = (try? JSONValue.parse(String(decoding: data, as: UTF8.self)))?["token"]?.nonEmptyString else {
            throw ProviderError.rpc(method: "GET /auth/connect", code: status, message: errorMessage(data, status: status))
        }
        let credentials = Data("opencode:\(token)".utf8).base64EncodedString()
        return Endpoint(url: url, authorization: "Basic \(credentials)")
    }

    /// `opencode api <operation>` (finds the service, starting it if needed) → its JSON output.
    private static func api(_ executable: String, _ operation: String) async throws -> JSONValue {
        let output = try await LineProcess.run(
            LineProcess.Configuration(
                executable: executable,
                arguments: ["api", operation],
                environment: ExecutableLocator.childEnvironment(),
                directory: NSHomeDirectory()
            ),
            timeout: cliTimeout,
            label: "opencode api \(operation)"
        )
        guard output.status == 0 else {
            throw ProviderError.processExited(.opencode, status: output.status, stderr: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
        do {
            return try ProviderPrompt.firstJSONObject(in: output.stdout)
        } catch {
            throw ProviderError.invalidOutput("`opencode api \(operation)` printed no JSON.")
        }
    }

    // MARK: - Helpers

    static func makeRequest(_ endpoint: Endpoint, method: String, path: String, query: [String: String], body: JSONValue?, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        var request = URLRequest(url: components.url ?? endpoint.url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(endpoint.authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.jsonString().utf8)
        }
        return request
    }

    /// The service went away (or moved to another port).
    private static func isUnreachable(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet].contains(error.code)
    }

    /// The server's `message` (its error bodies are `{_tag, message, ...}`), else the body text.
    static func errorMessage(_ data: Data, status: Int) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = (try? JSONValue.parse(text))?["message"]?.nonEmptyString { return message }
        return text.isEmpty ? "HTTP \(status)" : String(text.prefix(300))
    }
}

/// Server-sent events → JSON payloads. OpenCode writes each event's JSON on one `data:` line;
/// a payload split over several `data:` lines is joined until it parses. Comments
/// (`: heartbeat`), `event:`/`id:` fields and blank lines carry nothing the app needs.
struct OpencodeEventStreamDecoder: Sendable {
    private var buffer = ""

    mutating func decode(_ line: String) -> JSONValue? {
        guard line.hasPrefix("data:") else {
            if line.isEmpty { buffer = "" }
            return nil
        }
        var payload = line.dropFirst("data:".count)
        if payload.first == " " { payload = payload.dropFirst() }
        buffer = buffer.isEmpty ? String(payload) : buffer + "\n" + payload
        guard let value = try? JSONValue.parse(buffer), value.objectValue != nil else { return nil }
        buffer = ""
        return value
    }
}
