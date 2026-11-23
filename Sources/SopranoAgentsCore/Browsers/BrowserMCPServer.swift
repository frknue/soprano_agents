import Foundation

/// Minimal Chrome DevTools Protocol transport used by `BrowserMCPDispatcher`. Abstracted behind a
/// protocol so unit tests can exercise every MCP tool without launching Chromium.
public protocol CDPTransport: Sendable {
    func send(
        endpoint: String,
        method: String,
        params: [String: JSONValue],
        sessionID: String?
    ) async throws -> JSONValue

    func drainEvents(endpoint: String, sessionID: String) async -> [CDPEvent]
    func closeAllConnections() async
}

public struct CDPEvent: Sendable, Hashable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

public enum CDPError: Error, LocalizedError, Sendable {
    case invalidEndpoint(String)
    case browserNotReachable(String)
    case protocolError(String)
    case pageNotOwned(String)
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(url): "Invalid local CDP endpoint: \(url). Only 127.0.0.1 / localhost endpoints are permitted."
        case let .browserNotReachable(url): "Browser is not reachable at \(url). Launch the Chromium profile in Settings › Browsers first."
        case let .protocolError(message): "CDP error: \(message)"
        case let .pageNotOwned(name): "Page \"\(name)\" is not owned by this MCP session."
        case let .invalidArguments(message): message
        }
    }
}

// MARK: - Live URLSessionWebSocketTask CDP Client

/// Speaks standard Chrome DevTools Protocol over WebSocket (`URLSessionWebSocketTask`) to a local
/// Chromium browser (`127.0.0.1:<port>`). Zero WebKit.
public actor LiveCDPTransport: CDPTransport {
    private actor BrowserSocket {
        let endpoint: String
        private let task: URLSessionWebSocketTask
        private var nextID = 1
        private var waiters: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        private var eventsBySession: [String: [CDPEvent]] = [:]
        private var readerTask: Task<Void, Never>?
        private var closed = false

        init(endpoint: String, wsURL: URL) {
            self.endpoint = endpoint
            self.task = URLSession.shared.webSocketTask(with: wsURL)
            self.task.resume()
        }

        func start() {
            guard readerTask == nil else { return }
            readerTask = Task { [weak self] in
                await self?.readLoop()
            }
        }

        func send(method: String, params: [String: JSONValue], sessionID: String?) async throws -> JSONValue {
            guard !closed else { throw CDPError.browserNotReachable(endpoint) }
            let id = nextID
            nextID += 1
            var payload: [String: JSONValue] = [
                "id": .number(Double(id)),
                "method": .string(method),
                "params": .object(params),
            ]
            if let sessionID {
                payload["sessionId"] = .string(sessionID)
            }
            let data = try JSONEncoder().encode(JSONValue.object(payload))
            guard let text = String(data: data, encoding: .utf8) else {
                throw CDPError.protocolError("Failed to encode CDP message")
            }
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                task.send(.string(text)) { [weak self] error in
                    if let error {
                        Task { await self?.failWaiter(id: id, error: error) }
                    }
                }
            }
        }

        func drainEvents(sessionID: String) -> [CDPEvent] {
            eventsBySession.removeValue(forKey: sessionID) ?? []
        }

        func close() {
            closed = true
            readerTask?.cancel()
            task.cancel(with: .goingAway, reason: nil)
            let pending = waiters
            waiters.removeAll()
            for (_, waiter) in pending {
                waiter.resume(throwing: CDPError.browserNotReachable(endpoint))
            }
        }

        private func failWaiter(id: Int, error: Error) {
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume(throwing: error)
            }
        }

        private func readLoop() async {
            while !Task.isCancelled && !closed {
                do {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case let .string(str): text = str
                    case let .data(data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: continue
                    }
                    guard let value = try? JSONValue.parse(text) else { continue }
                    if let id = value["id"]?.intValue {
                        if let waiter = waiters.removeValue(forKey: id) {
                            if let error = value["error"] {
                                let msg = error["message"]?.stringValue ?? "CDP call failed"
                                waiter.resume(throwing: CDPError.protocolError(msg))
                            } else {
                                waiter.resume(returning: value["result"] ?? .object([:]))
                            }
                        }
                    } else if let method = value["method"]?.stringValue,
                              let sessionID = value["sessionId"]?.stringValue {
                        var list = eventsBySession[sessionID, default: []]
                        list.append(CDPEvent(method: method, params: value["params"] ?? .object([:])))
                        if list.count > 400 { list.removeFirst(list.count - 400) }
                        eventsBySession[sessionID] = list
                    }
                } catch {
                    close()
                    return
                }
            }
        }
    }

    private var sockets: [String: BrowserSocket] = [:]

    public init() {}

    public func send(
        endpoint: String,
        method: String,
        params: [String: JSONValue],
        sessionID: String?
    ) async throws -> JSONValue {
        let socket = try await socket(for: endpoint)
        return try await socket.send(method: method, params: params, sessionID: sessionID)
    }

    public func drainEvents(endpoint: String, sessionID: String) async -> [CDPEvent] {
        guard let socket = sockets[endpoint] else { return [] }
        return await socket.drainEvents(sessionID: sessionID)
    }

    public func closeAllConnections() async {
        for (_, socket) in sockets {
            await socket.close()
        }
        sockets.removeAll()
    }

    private func socket(for endpoint: String) async throws -> BrowserSocket {
        if let existing = sockets[endpoint] { return existing }
        guard let normalized = BrowserProfileResolver.validatedLocalCDPEndpoint(endpoint),
              let versionURL = URL(string: "\(normalized)/json/version")
        else {
            throw CDPError.invalidEndpoint(endpoint)
        }
        var request = URLRequest(url: versionURL, timeoutInterval: 2.0)
        request.httpMethod = "GET"
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CDPError.browserNotReachable(normalized)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wsString = object["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsString)
        else {
            throw CDPError.browserNotReachable(normalized)
        }
        let socket = BrowserSocket(endpoint: normalized, wsURL: wsURL)
        await socket.start()
        sockets[normalized] = socket
        return socket
    }
}

// MARK: - Built-in CDP Browser MCP Dispatcher

/// Stateful MCP tool dispatcher managing owned background tabs/windows on local Chromium browsers
/// via CDP. Tracks owned targets in a PID-scoped ledger directory so orphaned targets from crashed
/// MCP processes can be cleaned up without ever closing the user's own browser windows.
public actor BrowserMCPDispatcher {
    private struct OwnedPage {
        var name: String
        var profileID: String
        var endpoint: String
        var targetID: String
        var sessionID: String
        var url: String
        var lastUsed: Date
        var logs: [[String: JSONValue]]
        var network: [[String: JSONValue]]
        var ledgerPath: String?
    }

    public struct ToolOutput: Sendable, Hashable {
        public var content: [JSONValue]
        public var isError: Bool

        public init(content: [JSONValue], isError: Bool = false) {
            self.content = content
            self.isError = isError
        }
    }

    private let transport: any CDPTransport
    private let defaultEndpoint: String?
    private let settings: BrowserSettings
    private let cwd: String?
    private let ledgerDirectory: URL?
    private let pid: Int32
    private var pages: [String: OwnedPage] = [:]

    public init(
        transport: any CDPTransport,
        defaultEndpoint: String? = nil,
        settings: BrowserSettings = BrowserSettings(),
        cwd: String? = nil,
        ledgerDirectory: URL? = nil,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.transport = transport
        self.defaultEndpoint = defaultEndpoint
        self.settings = settings
        self.cwd = cwd
        self.ledgerDirectory = ledgerDirectory
        self.pid = pid
    }

    /// Handles one JSON-RPC 2.0 MCP message and returns the JSON-RPC response (or nil for notifications).
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
                    "name": .string("soprano-browser"),
                    "version": .string("1.0.0"),
                ]),
            ]))

        case "tools/list":
            guard let id else { return nil }
            return rpcResult(id: id, result: .object(["tools": .array(toolDefinitions())]))

        case "tools/call":
            guard let id else { return nil }
            let toolName = params["name"]?.stringValue ?? ""
            let args = params["arguments"] ?? .object([:])
            let output = await callTool(name: toolName, arguments: args)
            return rpcResult(id: id, result: .object([
                "content": .array(output.content),
                "isError": .bool(output.isError),
            ]))

        default:
            guard let id else { return nil }
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .number(-32601),
                    "message": .string("Method not found: \(method)"),
                ]),
            ])
        }
    }

    public func toolDefinitions() -> [JSONValue] {
        let profileEnum: JSONValue? = settings.profiles.isEmpty
            ? nil
            : .array(settings.profiles.map { .string($0.id) })

        var openProps: [String: JSONValue] = [
            "name": .object(["type": .string("string"), "description": .string("Unique name of your owned background page")]),
            "url": .object(["type": .string("string"), "description": .string("URL to open")]),
        ]
        var profileProp: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string("Optional browser profile id; omit to use the workspace's resolved profile."),
        ]
        if let profileEnum { profileProp["enum"] = profileEnum }
        openProps["profile"] = .object(profileProp)

        let nameProp: [String: JSONValue] = [
            "name": .object(["type": .string("string"), "description": .string("Unique name of your owned page")]),
        ]

        return [
            tool(
                name: "open",
                description: "Open a background Chromium tab/window over CDP in the resolved logged-in profile. Never steals focus. Close it when done.",
                properties: openProps,
                required: ["name", "url"]
            ),
            tool(
                name: "close",
                description: "Close only your owned page.",
                properties: nameProp,
                required: ["name"]
            ),
            tool(
                name: "list",
                description: "List pages owned by this MCP process.",
                properties: [:],
                required: []
            ),
            tool(
                name: "observe",
                description: "Read URL, title, visible text, interactive elements, console logs and network responses from your owned page.",
                properties: nameProp,
                required: ["name"]
            ),
            tool(
                name: "evaluate",
                description: "Evaluate a JavaScript expression or function in your owned page.",
                properties: nameProp.merging([
                    "code": .object(["type": .string("string"), "description": .string("JavaScript expression or function body")]),
                ]) { _, new in new },
                required: ["name", "code"]
            ),
            tool(
                name: "screenshot",
                description: "Capture a PNG screenshot of your background page, optionally clipped to a CSS selector or full page.",
                properties: nameProp.merging([
                    "selector": .object(["type": .string("string")]),
                    "fullPage": .object(["type": .string("boolean")]),
                ]) { _, new in new },
                required: ["name"]
            ),
            tool(
                name: "emulate",
                description: "Set viewport dimensions on your owned page.",
                properties: nameProp.merging([
                    "width": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "height": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "mobile": .object(["type": .string("boolean")]),
                ]) { _, new in new },
                required: ["name", "width", "height"]
            ),
            tool(
                name: "styles",
                description: "Read computed CSS styles and bounding rect for a CSS selector.",
                properties: nameProp.merging([
                    "selector": .object(["type": .string("string")]),
                ]) { _, new in new },
                required: ["name", "selector"]
            ),
            tool(
                name: "action",
                description: "Act in your owned page without bringing the browser forward: navigate, reload, back, click, hover, check, uncheck, fill, type, press, select, wait, scroll.",
                properties: nameProp.merging([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array(["navigate", "reload", "back", "click", "hover", "check", "uncheck", "fill", "type", "press", "select", "wait", "scroll"].map { .string($0) }),
                    ]),
                    "selector": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                ]) { _, new in new },
                required: ["name", "action"]
            ),
            tool(
                name: "cookies",
                description: "Inspect or change specific cookies scoped to this page's URL.",
                properties: nameProp.merging([
                    "set": .object(["type": .string("array"), "items": .object(["type": .string("object")])]),
                    "remove": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                ]) { _, new in new },
                required: ["name"]
            ),
        ]
    }

    public func callTool(name: String, arguments: JSONValue) async -> ToolOutput {
        do {
            switch name {
            case "open":
                let pageName = try requireString("name", in: arguments)
                let url = try requireString("url", in: arguments)
                let requestedProfile = arguments["profile"]?.nonEmptyString ?? arguments["account"]?.nonEmptyString
                let result = try await openPage(name: pageName, url: url, requestedProfile: requestedProfile)
                return textOutput(result)

            case "close":
                let pageName = try requireString("name", in: arguments)
                let closed = try await closePage(name: pageName)
                return textOutput(.object(["closed": .bool(closed)]))

            case "list":
                let items: [JSONValue] = pages.values.sorted { $0.name < $1.name }.map { page in
                    .object([
                        "name": .string(page.name),
                        "profile": .string(page.profileID),
                        "url": .string(page.url),
                    ])
                }
                return textOutput(.array(items))

            case "observe":
                let pageName = try requireString("name", in: arguments)
                let result = try await observePage(name: pageName)
                return textOutput(result)

            case "evaluate":
                let pageName = try requireString("name", in: arguments)
                let code = try requireString("code", in: arguments)
                let result = try await evaluate(name: pageName, code: code)
                return textOutput(result)

            case "screenshot":
                let pageName = try requireString("name", in: arguments)
                let selector = arguments["selector"]?.nonEmptyString
                let fullPage = arguments["fullPage"]?.boolValue ?? false
                let base64 = try await captureScreenshot(name: pageName, selector: selector, fullPage: fullPage)
                return ToolOutput(content: [.object([
                    "type": .string("image"),
                    "mimeType": .string("image/png"),
                    "data": .string(base64),
                ])])

            case "emulate":
                let pageName = try requireString("name", in: arguments)
                guard let width = arguments["width"]?.intValue, width > 0,
                      let height = arguments["height"]?.intValue, height > 0
                else {
                    throw CDPError.invalidArguments("width and height must be positive integers.")
                }
                let mobile = arguments["mobile"]?.boolValue ?? false
                let page = try touchPage(pageName)
                _ = try await transport.send(
                    endpoint: page.endpoint,
                    method: "Emulation.setDeviceMetricsOverride",
                    params: [
                        "width": .number(Double(width)),
                        "height": .number(Double(height)),
                        "deviceScaleFactor": .number(1),
                        "mobile": .bool(mobile),
                    ],
                    sessionID: page.sessionID
                )
                return textOutput(.object(["ok": .bool(true), "width": .number(Double(width)), "height": .number(Double(height))]))

            case "styles":
                let pageName = try requireString("name", in: arguments)
                let selector = try requireString("selector", in: arguments)
                let result = try await computedStyles(name: pageName, selector: selector)
                return textOutput(result)

            case "action":
                let pageName = try requireString("name", in: arguments)
                let actionName = try requireString("action", in: arguments)
                let result = try await performAction(
                    name: pageName,
                    action: actionName,
                    selector: arguments["selector"]?.nonEmptyString,
                    value: arguments["value"]?.stringValue,
                    x: arguments["x"]?.doubleValue,
                    y: arguments["y"]?.doubleValue
                )
                return textOutput(result)

            case "cookies":
                let pageName = try requireString("name", in: arguments)
                let result = try await handleCookies(
                    name: pageName,
                    set: arguments["set"]?.arrayValue,
                    remove: arguments["remove"]?.arrayValue?.compactMap(\.stringValue)
                )
                return textOutput(result)

            default:
                return ToolOutput(content: [.object(["type": .string("text"), "text": .string("Unknown tool: \(name)")])], isError: true)
            }
        } catch {
            return ToolOutput(
                content: [.object(["type": .string("text"), "text": .string(error.localizedDescription)])],
                isError: true
            )
        }
    }

    public func closeIdlePages(olderThan seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        let expired = pages.values.filter { $0.lastUsed < cutoff }.map(\.name)
        for name in expired {
            _ = try? await closePage(name: name)
        }
    }

    public func dispose() async {
        for name in Array(pages.keys) {
            _ = try? await closePage(name: name)
        }
        await transport.closeAllConnections()
    }

    /// Cleans up orphaned ledger entries whose owning PID is no longer running.
    public func cleanupOrphanedTargets() async {
        guard let dir = ledgerDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8),
                  let entry = try? JSONValue.parse(text),
                  let ownerPID = entry["pid"]?.intValue,
                  let targetID = entry["targetId"]?.nonEmptyString,
                  let endpoint = entry["endpoint"]?.nonEmptyString,
                  let validEndpoint = BrowserProfileResolver.validatedLocalCDPEndpoint(endpoint)
            else { continue }
            if kill(Int32(ownerPID), 0) == 0 || errno == EPERM {
                continue
            }
            _ = try? await transport.send(
                endpoint: validEndpoint,
                method: "Target.closeTarget",
                params: ["targetId": .string(targetID)],
                sessionID: nil
            )
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Operations

    private func resolveEndpoint(requestedProfile: String?) throws -> (endpoint: String, profileID: String) {
        if let requestedProfile {
            if let resolved = BrowserProfileResolver.resolve(cwd: cwd, requestedProfile: requestedProfile, settings: settings),
               let valid = BrowserProfileResolver.validatedLocalCDPEndpoint(resolved.cdpURL) {
                return (valid, resolved.profile?.id ?? requestedProfile)
            }
            throw CDPError.invalidArguments("Unknown browser profile: \(requestedProfile)")
        }
        if let defaultEndpoint, let valid = BrowserProfileResolver.validatedLocalCDPEndpoint(defaultEndpoint) {
            let matched = settings.profiles.first { $0.cdpURL == valid }?.id ?? "default"
            return (valid, matched)
        }
        if let resolved = BrowserProfileResolver.resolve(cwd: cwd, settings: settings),
           let valid = BrowserProfileResolver.validatedLocalCDPEndpoint(resolved.cdpURL) {
            return (valid, resolved.profile?.id ?? "default")
        }
        throw CDPError.invalidArguments("No browser profile is configured. Configure \"browsers.profiles\" in settings.json.")
    }

    private func openPage(name: String, url: String, requestedProfile: String?) async throws -> JSONValue {
        if pages[name] != nil {
            throw CDPError.invalidArguments("Page \"\(name)\" already exists; navigate or close it first.")
        }
        let (endpoint, profileID) = try resolveEndpoint(requestedProfile: requestedProfile)

        let created = try await transport.send(
            endpoint: endpoint,
            method: "Target.createTarget",
            params: [
                "url": .string("about:blank"),
                "background": .bool(true),
            ],
            sessionID: nil
        )
        guard let targetID = created["targetId"]?.nonEmptyString else {
            throw CDPError.protocolError("Target.createTarget did not return targetId")
        }

        do {
            let attached = try await transport.send(
                endpoint: endpoint,
                method: "Target.attachToTarget",
                params: ["targetId": .string(targetID), "flatten": .bool(true)],
                sessionID: nil
            )
            guard let sessionID = attached["sessionId"]?.nonEmptyString else {
                throw CDPError.protocolError("Target.attachToTarget did not return sessionId")
            }

            _ = try? await transport.send(endpoint: endpoint, method: "Page.enable", params: [:], sessionID: sessionID)
            _ = try? await transport.send(endpoint: endpoint, method: "Runtime.enable", params: [:], sessionID: sessionID)
            _ = try? await transport.send(endpoint: endpoint, method: "Network.enable", params: [:], sessionID: sessionID)
            _ = try? await transport.send(
                endpoint: endpoint,
                method: "Emulation.setFocusEmulationEnabled",
                params: ["enabled": .bool(true)],
                sessionID: sessionID
            )
            _ = try? await transport.send(
                endpoint: endpoint,
                method: "Emulation.setDeviceMetricsOverride",
                params: [
                    "width": .number(1440),
                    "height": .number(900),
                    "deviceScaleFactor": .number(1),
                    "mobile": .bool(false),
                ],
                sessionID: sessionID
            )

            var ledgerPath: String?
            if let ledgerDirectory {
                try? FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
                let file = ledgerDirectory.appendingPathComponent("\(pid)-\(targetID).json")
                let entry: JSONValue = .object([
                    "pid": .number(Double(pid)),
                    "targetId": .string(targetID),
                    "endpoint": .string(endpoint),
                ])
                if let data = try? JSONEncoder().encode(entry) {
                    try? data.write(to: file, options: .atomic)
                    ledgerPath = file.path
                }
            }

            pages[name] = OwnedPage(
                name: name,
                profileID: profileID,
                endpoint: endpoint,
                targetID: targetID,
                sessionID: sessionID,
                url: url,
                lastUsed: Date(),
                logs: [],
                network: [],
                ledgerPath: ledgerPath
            )

            _ = try await transport.send(
                endpoint: endpoint,
                method: "Page.navigate",
                params: ["url": .string(url)],
                sessionID: sessionID
            )
            await waitForDocumentReady(endpoint: endpoint, sessionID: sessionID)

            let currentURL = (try? await evalJS(endpoint: endpoint, sessionID: sessionID, expression: "location.href"))?.stringValue ?? url
            pages[name]?.url = currentURL
            return .object([
                "name": .string(name),
                "profile": .string(profileID),
                "url": .string(currentURL),
                "targetId": .string(targetID),
            ])
        } catch {
            if pages[name] != nil {
                _ = try? await closePage(name: name)
            } else {
                _ = try? await transport.send(
                    endpoint: endpoint,
                    method: "Target.closeTarget",
                    params: ["targetId": .string(targetID)],
                    sessionID: nil
                )
            }
            throw error
        }
    }

    private func closePage(name: String) async throws -> Bool {
        guard let page = pages.removeValue(forKey: name) else { return false }
        _ = try? await transport.send(
            endpoint: page.endpoint,
            method: "Target.closeTarget",
            params: ["targetId": .string(page.targetID)],
            sessionID: nil
        )
        if let ledgerPath = page.ledgerPath {
            try? FileManager.default.removeItem(atPath: ledgerPath)
        }
        return true
    }

    private func observePage(name: String) async throws -> JSONValue {
        let page = try touchPage(name)
        await ingestEvents(for: name)
        let js = """
        (() => {
          const interactive = [...document.querySelectorAll('a,button,input,textarea,select,[role="button"],[role="link"]')].slice(0, 120).map(el => ({
            tag: el.tagName.toLowerCase(),
            type: el.getAttribute('type') || undefined,
            name: el.getAttribute('name') || undefined,
            id: el.id || undefined,
            role: el.getAttribute('role') || undefined,
            ariaLabel: el.getAttribute('aria-label') || undefined,
            text: (el.innerText || el.value || el.getAttribute('placeholder') || '').trim().slice(0, 120)
          }));
          return {
            url: location.href,
            title: document.title,
            text: (document.body ? document.body.innerText : '').slice(0, 20000),
            interactive
          };
        })()
        """
        let snapshot = try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: js)
        if let currentURL = snapshot["url"]?.nonEmptyString {
            pages[name]?.url = currentURL
        }
        let updated = pages[name]
        var result = snapshot.objectValue ?? [:]
        result["console"] = .array((updated?.logs ?? []).map { .object($0) })
        result["requests"] = .array((updated?.network ?? []).map { .object($0) })
        return .object(result)
    }

    private func evaluate(name: String, code: String) async throws -> JSONValue {
        let page = try touchPage(name)
        let wrapped = """
        (() => {
          const __val = (0, eval)(\(jsString(code)));
          return typeof __val === 'function' ? __val() : __val;
        })()
        """
        return try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: wrapped)
    }

    private func captureScreenshot(name: String, selector: String?, fullPage: Bool) async throws -> String {
        let page = try touchPage(name)
        var params: [String: JSONValue] = [
            "format": .string("png"),
            "captureBeyondViewport": .bool(true),
        ]
        if let selector {
            let js = """
            (() => {
              const el = document.querySelector(\(jsString(selector)));
              if (!el) return null;
              el.scrollIntoView({ block: 'center', inline: 'center' });
              const r = el.getBoundingClientRect();
              return { x: r.x + scrollX, y: r.y + scrollY, width: r.width, height: r.height, scale: 1 };
            })()
            """
            let clip = try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: js)
            guard case .object = clip else {
                throw CDPError.invalidArguments("Screenshot selector did not match a visible element: \(selector)")
            }
            params["clip"] = clip
        } else if fullPage {
            let metrics = try await transport.send(
                endpoint: page.endpoint,
                method: "Page.getLayoutMetrics",
                params: [:],
                sessionID: page.sessionID
            )
            if let size = metrics["cssContentSize"],
               let width = size["width"]?.doubleValue,
               let height = size["height"]?.doubleValue {
                params["clip"] = .object([
                    "x": .number(0),
                    "y": .number(0),
                    "width": .number(width),
                    "height": .number(height),
                    "scale": .number(1),
                ])
            }
        }
        let result = try await transport.send(
            endpoint: page.endpoint,
            method: "Page.captureScreenshot",
            params: params,
            sessionID: page.sessionID
        )
        guard let data = result["data"]?.stringValue else {
            throw CDPError.protocolError("Page.captureScreenshot did not return image data")
        }
        return data
    }

    private func computedStyles(name: String, selector: String) async throws -> JSONValue {
        let page = try touchPage(name)
        let js = """
        (() => {
          const el = document.querySelector(\(jsString(selector)));
          if (!el) throw new Error('Element not found: ' + \(jsString(selector)));
          const cs = getComputedStyle(el);
          const styles = {};
          for (const prop of cs) styles[prop] = cs.getPropertyValue(prop);
          return { styles, rect: el.getBoundingClientRect().toJSON() };
        })()
        """
        return try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: js)
    }

    private func performAction(
        name: String,
        action: String,
        selector: String?,
        value: String?,
        x: Double?,
        y: Double?
    ) async throws -> JSONValue {
        let page = try touchPage(name)
        switch action {
        case "navigate":
            guard let value, !value.isEmpty else { throw CDPError.invalidArguments("navigate requires value (URL).") }
            _ = try await transport.send(endpoint: page.endpoint, method: "Page.navigate", params: ["url": .string(value)], sessionID: page.sessionID)
            await waitForDocumentReady(endpoint: page.endpoint, sessionID: page.sessionID)

        case "reload":
            _ = try await transport.send(endpoint: page.endpoint, method: "Page.reload", params: [:], sessionID: page.sessionID)
            await waitForDocumentReady(endpoint: page.endpoint, sessionID: page.sessionID)

        case "back":
            _ = try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: "history.back(); true")

        case "scroll":
            let dx = x ?? 0
            let dy = y ?? 500
            _ = try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: "window.scrollBy(\(dx), \(dy)); true")

        case "click", "hover", "check", "uncheck", "fill", "type", "press", "select":
            guard let selector else { throw CDPError.invalidArguments("\(action) requires selector.") }
            let js = domActionScript(action: action, selector: selector, value: value ?? "")
            _ = try await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: js)

        case "wait":
            let deadline = Date().addingTimeInterval(30)
            let checkJS: String
            if let selector {
                checkJS = "(() => { const el = document.querySelector(\(jsString(selector))); return !!(el && el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0); })()"
            } else if let value, !value.isEmpty {
                checkJS = "((document.body && document.body.innerText) || '').includes(\(jsString(value)))"
            } else {
                throw CDPError.invalidArguments("wait requires selector or value.")
            }
            while Date() < deadline {
                if (try? await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: checkJS))?.boolValue == true {
                    break
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

        default:
            throw CDPError.invalidArguments("Unknown page action: \(action)")
        }

        let currentURL = (try? await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: "location.href"))?.stringValue ?? page.url
        pages[name]?.url = currentURL
        return .object(["url": .string(currentURL)])
    }

    private func handleCookies(name: String, set: [JSONValue]?, remove: [String]?) async throws -> JSONValue {
        let page = try touchPage(name)
        let currentURL = (try? await evalJS(endpoint: page.endpoint, sessionID: page.sessionID, expression: "location.href"))?.stringValue ?? page.url
        pages[name]?.url = currentURL

        let existing = try await transport.send(
            endpoint: page.endpoint,
            method: "Network.getCookies",
            params: ["urls": .array([.string(currentURL)])],
            sessionID: page.sessionID
        )
        if let remove, !remove.isEmpty, let cookies = existing["cookies"]?.arrayValue {
            for cookie in cookies {
                guard let cookieName = cookie["name"]?.stringValue, remove.contains(cookieName) else { continue }
                var params: [String: JSONValue] = ["name": .string(cookieName), "url": .string(currentURL)]
                if let domain = cookie["domain"]?.stringValue { params["domain"] = .string(domain) }
                if let path = cookie["path"]?.stringValue { params["path"] = .string(path) }
                _ = try await transport.send(endpoint: page.endpoint, method: "Network.deleteCookies", params: params, sessionID: page.sessionID)
            }
        }
        if let set {
            for item in set {
                guard let obj = item.objectValue,
                      let cookieName = obj["name"]?.nonEmptyString,
                      let cookieValue = obj["value"]?.stringValue
                else { throw CDPError.invalidArguments("Each cookie in set must have name and value.") }
                if obj["domain"] != nil || obj["url"] != nil || obj["path"] != nil {
                    throw CDPError.invalidArguments("Set cookies by name/value only; scope is the owned page URL.")
                }
                _ = try await transport.send(
                    endpoint: page.endpoint,
                    method: "Network.setCookie",
                    params: [
                        "name": .string(cookieName),
                        "value": .string(cookieValue),
                        "url": .string(currentURL),
                    ],
                    sessionID: page.sessionID
                )
            }
        }
        let refreshed = try await transport.send(
            endpoint: page.endpoint,
            method: "Network.getCookies",
            params: ["urls": .array([.string(currentURL)])],
            sessionID: page.sessionID
        )
        return refreshed["cookies"] ?? .array([])
    }

    // MARK: Helpers

    private func touchPage(_ name: String) throws -> OwnedPage {
        guard var page = pages[name] else { throw CDPError.pageNotOwned(name) }
        page.lastUsed = Date()
        pages[name] = page
        return page
    }

    private func ingestEvents(for name: String) async {
        guard var page = pages[name] else { return }
        let events = await transport.drainEvents(endpoint: page.endpoint, sessionID: page.sessionID)
        for event in events {
            switch event.method {
            case "Runtime.consoleAPICalled":
                let type = event.params["type"]?.stringValue ?? "log"
                let args = event.params["args"]?.arrayValue ?? []
                let text = args.compactMap { $0["value"]?.stringValue ?? $0["description"]?.stringValue }.joined(separator: " ")
                page.logs.append(["type": .string(type), "text": .string(text)])
                if page.logs.count > 200 { page.logs.removeFirst(page.logs.count - 200) }
            case "Runtime.exceptionThrown":
                let text = event.params["exceptionDetails"]?["text"]?.stringValue ?? "Uncaught exception"
                page.logs.append(["type": .string("error"), "text": .string(text)])
                if page.logs.count > 200 { page.logs.removeFirst(page.logs.count - 200) }
            case "Network.responseReceived":
                if let response = event.params["response"] {
                    var entry: [String: JSONValue] = [:]
                    if let url = response["url"]?.stringValue { entry["url"] = .string(url) }
                    if let status = response["status"]?.intValue { entry["status"] = .number(Double(status)) }
                    if let mime = response["mimeType"]?.stringValue { entry["mimeType"] = .string(mime) }
                    page.network.append(entry)
                    if page.network.count > 300 { page.network.removeFirst(page.network.count - 300) }
                }
            default:
                break
            }
        }
        pages[name] = page
    }

    private func evalJS(endpoint: String, sessionID: String, expression: String) async throws -> JSONValue {
        let response = try await transport.send(
            endpoint: endpoint,
            method: "Runtime.evaluate",
            params: [
                "expression": .string(expression),
                "awaitPromise": .bool(true),
                "returnByValue": .bool(true),
            ],
            sessionID: sessionID
        )
        if let exception = response["exceptionDetails"] {
            let description = exception["exception"]?["description"]?.stringValue
                ?? exception["text"]?.stringValue
                ?? "JavaScript evaluation error"
            throw CDPError.protocolError(description)
        }
        return response["result"]?["value"] ?? .null
    }

    private func waitForDocumentReady(endpoint: String, sessionID: String) async {
        for _ in 0..<25 {
            if let state = (try? await evalJS(endpoint: endpoint, sessionID: sessionID, expression: "document.readyState"))?.stringValue,
               state == "interactive" || state == "complete" {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func domActionScript(action: String, selector: String, value: String) -> String {
        let sel = jsString(selector)
        let val = jsString(value)
        return """
        (() => {
          const el = document.querySelector(\(sel));
          if (!el) throw new Error('Element not found: ' + \(sel));
          el.scrollIntoView({ block: 'center', inline: 'center' });
          switch (\(jsString(action))) {
            case 'click': el.click(); break;
            case 'hover': el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true })); break;
            case 'check': if (!el.checked) { el.checked = true; el.dispatchEvent(new Event('change', { bubbles: true })); } break;
            case 'uncheck': if (el.checked) { el.checked = false; el.dispatchEvent(new Event('change', { bubbles: true })); } break;
            case 'fill':
            case 'type':
              el.focus();
              el.value = \(val);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              break;
            case 'press':
              el.focus();
              el.dispatchEvent(new KeyboardEvent('keydown', { key: \(val), bubbles: true }));
              el.dispatchEvent(new KeyboardEvent('keyup', { key: \(val), bubbles: true }));
              break;
            case 'select': {
              const target = \(val);
              for (const opt of el.options || []) {
                if (opt.value === target || opt.textContent.trim() === target) {
                  el.value = opt.value;
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                  return true;
                }
              }
              throw new Error('Option not found: ' + target);
            }
          }
          return true;
        })()
        """
    }

    private func jsString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\""
    }

    private func requireString(_ key: String, in object: JSONValue) throws -> String {
        guard let value = object[key]?.nonEmptyString else {
            throw CDPError.invalidArguments("Missing required string argument \"\(key)\".")
        }
        return value
    }

    private func tool(name: String, description: String, properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    private func textOutput(_ value: JSONValue) -> ToolOutput {
        let text: String
        if let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            text = "{}"
        }
        return ToolOutput(content: [.object(["type": .string("text"), "text": .string(text)])])
    }

    private func rpcResult(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
    }
}

// MARK: - Stdio Runner

/// Runs `BrowserMCPDispatcher` as a standard MCP stdio server (newline-delimited JSON-RPC 2.0 on
/// stdin/stdout). Invoked by `SopranoAgents mcp browser`.
public enum BrowserMCPStdioRunner {
    public static func run(
        defaultEndpoint: String?,
        settings: BrowserSettings,
        cwd: String?,
        ledgerDirectory: URL?
    ) async {
        let transport = LiveCDPTransport()
        let dispatcher = BrowserMCPDispatcher(
            transport: transport,
            defaultEndpoint: defaultEndpoint,
            settings: settings,
            cwd: cwd,
            ledgerDirectory: ledgerDirectory
        )
        await dispatcher.cleanupOrphanedTargets()

        let idleSeconds = TimeInterval(max(0, settings.idleCloseSeconds))
        let idleTask = Task {
            guard idleSeconds > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await dispatcher.closeIdlePages(olderThan: idleSeconds)
            }
        }

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

        idleTask.cancel()
        await dispatcher.dispose()
    }
}
