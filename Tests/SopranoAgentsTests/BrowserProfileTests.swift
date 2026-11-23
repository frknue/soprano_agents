import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct BrowserProfileTests {
    // MARK: - Profile resolution

    @Test func rulesMatchPathPrefixProjectNameAndGitRemote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-rules-\(UUID().uuidString)", isDirectory: true)
        let workRepo = root.appendingPathComponent("work/acme-shop", isDirectory: true)
        let remoteRepo = root.appendingPathComponent("other/partner-app", isDirectory: true)
        let namedRepo = root.appendingPathComponent("misc/personal-blog", isDirectory: true)
        let fallbackRepo = root.appendingPathComponent("misc/unmatched", isDirectory: true)
        for dir in [workRepo, remoteRepo, namedRepo, fallbackRepo] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let dotGit = remoteRepo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try """
        [core]
            repositoryformatversion = 0
        [remote "origin"]
            url = git@github.com:partner-org/partner-app.git
        """.write(to: dotGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let settings = BrowserSettings(
            enabled: true,
            defaultProfile: "personal",
            profiles: [
                BrowserProfile(id: "work", label: "Work", port: 9333),
                BrowserProfile(id: "partner", label: "Partner", port: 9334),
                BrowserProfile(id: "personal", label: "Personal", port: 9335),
            ],
            rules: [
                BrowserMatchRule(profileID: "work", pathPrefixes: [root.appendingPathComponent("work").path]),
                BrowserMatchRule(profileID: "partner", gitRemoteSubstrings: ["partner-org/"]),
                BrowserMatchRule(profileID: "personal", projectNames: ["personal-blog"]),
            ]
        )

        let byPath = BrowserProfileResolver.resolve(cwd: workRepo.path, settings: settings, home: root.path)
        #expect(byPath?.profile?.id == "work")
        #expect(byPath?.cdpURL == "http://127.0.0.1:9333")
        #expect(byPath?.source == .rule)

        let byRemote = BrowserProfileResolver.resolve(cwd: remoteRepo.path, settings: settings, home: root.path)
        #expect(byRemote?.profile?.id == "partner")
        #expect(byRemote?.cdpURL == "http://127.0.0.1:9334")
        #expect(byRemote?.source == .rule)

        let byName = BrowserProfileResolver.resolve(cwd: namedRepo.path, settings: settings, home: root.path)
        #expect(byName?.profile?.id == "personal")
        #expect(byName?.source == .rule)

        let byFallback = BrowserProfileResolver.resolve(cwd: fallbackRepo.path, settings: settings, home: root.path)
        #expect(byFallback?.profile?.id == "personal")
        #expect(byFallback?.source == .fallback)

        let byExplicit = BrowserProfileResolver.resolve(cwd: fallbackRepo.path, requestedProfile: "work", settings: settings, home: root.path)
        #expect(byExplicit?.profile?.id == "work")
        #expect(byExplicit?.source == .explicit)
    }

    @Test func externalResolverValidatesLoopbackOnly() {
        let settings = BrowserSettings(
            enabled: true,
            resolverCommand: ["/usr/local/bin/custom-browser", "url", "--path", "{cwd}"],
            profiles: [BrowserProfile(id: "main", port: 9444)]
        )

        let valid = BrowserProfileResolver.resolve(
            cwd: "/tmp/repo",
            settings: settings,
            runResolver: { argv, _ in
                #expect(argv == ["/usr/local/bin/custom-browser", "url", "--path", "/tmp/repo"])
                return "http://127.0.0.1:9444\n"
            }
        )
        #expect(valid?.cdpURL == "http://127.0.0.1:9444")
        #expect(valid?.profile?.id == "main")
        #expect(valid?.source == .resolver)

        // Remote host must be rejected and fall back safely to the configured profile.
        let rejected = BrowserProfileResolver.resolve(
            cwd: "/tmp/repo",
            settings: settings,
            runResolver: { _, _ in "http://example.com:9444" }
        )
        #expect(rejected?.source == .fallback)
        #expect(rejected?.cdpURL == "http://127.0.0.1:9444")
    }

    @Test func ompOverlayFormatsCdpUrl() {
        let yaml = BrowserProfileResolver.ompBrowserOverlay(cdpURL: "http://127.0.0.1:9333")
        #expect(yaml.contains("browser:"))
        #expect(yaml.contains("cdpUrl: \"http://127.0.0.1:9333\""))
    }

    // MARK: - Settings parsing

    @Test func settingsResolverParsesBrowsersSectionAndWarnsOnInvalidEntries() throws {
        let json = """
        {
          "browsers": {
            "enabled": true,
            "defaultProfile": "work",
            "idleCloseSeconds": 900,
            "includeChromeDevtoolsMcp": true,
            "resolverCommand": ["~/bin/browser-url", "{cwd}"],
            "customMcpCommand": { "name": "my-browser", "command": "bun", "args": ["browser.ts"] },
            "profiles": [
              { "id": "work", "label": "Work Chrome", "port": 9333 },
              { "id": "work", "port": 9334 },
              { "id": "bad-port", "port": 99999 }
            ],
            "rules": [
              { "profile": "work", "pathPrefixes": ["~/git/work"], "gitRemoteSubstrings": ["acme"] },
              { "pathPrefixes": ["~/missing-profile"] }
            ]
          }
        }
        """
        let resolved = try SettingsResolver.resolve(text: json)
        let browsers = resolved.settings.browsers
        #expect(browsers.enabled == true)
        #expect(browsers.defaultProfile == "work")
        #expect(browsers.idleCloseSeconds == 900)
        #expect(browsers.includeChromeDevtoolsMcp == true)
        #expect(browsers.resolverCommand == ["~/bin/browser-url", "{cwd}"])
        #expect(browsers.customMcpCommand?.name == "my-browser")
        if case let .stdio(command, args, _) = browsers.customMcpCommand?.transport {
            #expect(command == "bun")
            #expect(args == ["browser.ts"])
        } else {
            Issue.record("Expected stdio customMcpCommand transport")
        }
        #expect(browsers.profiles.count == 1)
        #expect(browsers.profiles[0].id == "work")
        #expect(browsers.profiles[0].label == "Work Chrome")
        #expect(browsers.rules.count == 1)
        #expect(browsers.rules[0].profileID == "work")
        #expect(resolved.issues.count == 3)
    }

    // MARK: - Built-in CDP MCP dispatcher

    @Test func browserMCPDispatcherHandlesLifecycleAndToolsOverMockCDP() async throws {
        let mock = MockCDPTransport()
        let settings = BrowserSettings(
            enabled: true,
            profiles: [BrowserProfile(id: "default", port: 9333)]
        )
        let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("browser-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ledger) }

        let dispatcher = BrowserMCPDispatcher(
            transport: mock,
            defaultEndpoint: "http://127.0.0.1:9333",
            settings: settings,
            ledgerDirectory: ledger
        )

        let initResp = await dispatcher.handleJSONRPC(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2024-11-05")]),
        ]))
        #expect(initResp?["result"]?["serverInfo"]?["name"]?.stringValue == "soprano-browser")

        let listToolsResp = await dispatcher.handleJSONRPC(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(2),
            "method": .string("tools/list"),
        ]))
        let toolNames = (listToolsResp?["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(toolNames.contains("open"))
        #expect(toolNames.contains("observe"))
        #expect(toolNames.contains("screenshot"))
        #expect(toolNames.contains("action"))
        #expect(toolNames.contains("cookies"))

        // Open an owned background page.
        let opened = await dispatcher.callTool(name: "open", arguments: .object([
            "name": .string("preview"),
            "url": .string("https://example.test/dashboard"),
        ]))
        #expect(!opened.isError)
        let openText = opened.content.first?["text"]?.stringValue ?? ""
        #expect(openText.contains("target-1"))

        // Observe returns DOM snapshot + buffered console/network diagnostics.
        await mock.pushEvent(
            sessionID: "session-1",
            event: CDPEvent(
                method: "Runtime.consoleAPICalled",
                params: .object([
                    "type": .string("warning"),
                    "args": .array([.object(["value": .string("slow query")])]),
                ])
            )
        )
        let observed = await dispatcher.callTool(name: "observe", arguments: .object(["name": .string("preview")]))
        #expect(!observed.isError)
        let observeText = observed.content.first?["text"]?.stringValue ?? ""
        #expect(observeText.contains("slow query"))
        #expect(observeText.contains("Example Dashboard"))

        // Screenshot returns an MCP image block.
        let shot = await dispatcher.callTool(name: "screenshot", arguments: .object(["name": .string("preview")]))
        #expect(!shot.isError)
        #expect(shot.content.first?["type"]?.stringValue == "image")
        #expect(shot.content.first?["mimeType"]?.stringValue == "image/png")
        #expect(shot.content.first?["data"]?.stringValue == "iVBORw0KGgo=")

        // Cookies refuse cross-domain overrides.
        let badCookie = await dispatcher.callTool(name: "cookies", arguments: .object([
            "name": .string("preview"),
            "set": .array([.object(["name": .string("sid"), "value": .string("1"), "domain": .string("other.test")])]),
        ]))
        #expect(badCookie.isError)

        // Closing removes only the owned target.
        let closed = await dispatcher.callTool(name: "close", arguments: .object(["name": .string("preview")]))
        #expect(!closed.isError)
        let methods = await mock.recordedMethods()
        #expect(methods.contains("Target.createTarget"))
        #expect(methods.contains("Emulation.setFocusEmulationEnabled"))
        #expect(methods.contains("Target.closeTarget"))

        // Using a closed page returns an error.
        let missing = await dispatcher.callTool(name: "observe", arguments: .object(["name": .string("preview")]))
        #expect(missing.isError)
    }

    // MARK: - Engine session wiring

    @Test @MainActor func engineInjectsBrowserMCPForCodexAndOverlayForOmp() throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-browsers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let settings = EngineSettings(
            browsers: BrowserSettings(
                enabled: true,
                includeChromeDevtoolsMcp: true,
                profiles: [BrowserProfile(id: "default", port: 9333)]
            )
        )
        let env = EngineEnvironment(
            drivers: [:],
            git: FixtureGitService(),
            store: InMemoryThreadStore(),
            dataDirectory: dataDir,
            executablePath: "/Applications/Soprano Agents.app/Contents/MacOS/SopranoAgents"
        )
        let engine = AgentEngine(environment: env, settings: settings)

        let codexThread = AgentThread(projectID: nil, modelSelection: .default(for: .codex))
        let codexConfig = try engine.sessionConfig(for: codexThread)
        #expect(codexConfig.mcpServers.contains { spec in
            guard spec.name == "soprano-browser", case let .stdio(_, args, _) = spec.transport else { return false }
            return args.contains("--cdp-url") && args.contains("http://127.0.0.1:9333")
        })
        #expect(codexConfig.mcpServers.contains { $0.name == "chrome-devtools" })

        let ompThread = AgentThread(projectID: nil, modelSelection: .default(for: .omp))
        let ompConfig = try engine.sessionConfig(for: ompThread)
        #expect(ompConfig.configOverlays.count == 1)
        let overlayContent = try String(contentsOfFile: ompConfig.configOverlays[0], encoding: .utf8)
        #expect(overlayContent.contains("http://127.0.0.1:9333"))
    }
}

private actor MockCDPTransport: CDPTransport {
    private var methods: [String] = []
    private var events: [String: [CDPEvent]] = [:]

    func pushEvent(sessionID: String, event: CDPEvent) {
        events[sessionID, default: []].append(event)
    }

    func recordedMethods() -> [String] { methods }

    func send(
        endpoint: String,
        method: String,
        params: [String: JSONValue],
        sessionID: String?
    ) async throws -> JSONValue {
        methods.append(method)
        switch method {
        case "Target.createTarget":
            return .object(["targetId": .string("target-1")])
        case "Target.attachToTarget":
            return .object(["sessionId": .string("session-1")])
        case "Page.captureScreenshot":
            return .object(["data": .string("iVBORw0KGgo=")])
        case "Network.getCookies":
            return .object(["cookies": .array([])])
        case "Runtime.evaluate":
            let expr = params["expression"]?.stringValue ?? ""
            if expr == "document.readyState" {
                return .object(["result": .object(["value": .string("complete")])])
            }
            if expr == "location.href" {
                return .object(["result": .object(["value": .string("https://example.test/dashboard")])])
            }
            if expr.contains("document.title") {
                return .object(["result": .object(["value": .object([
                    "url": .string("https://example.test/dashboard"),
                    "title": .string("Example Dashboard"),
                    "text": .string("Welcome"),
                    "interactive": .array([]),
                ])])])
            }
            return .object(["result": .object(["value": .bool(true)])])
        default:
            return .object([:])
        }
    }

    func drainEvents(endpoint: String, sessionID: String) async -> [CDPEvent] {
        events.removeValue(forKey: sessionID) ?? []
    }

    func closeAllConnections() async {}
}

