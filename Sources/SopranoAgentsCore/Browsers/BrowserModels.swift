import Foundation

/// A user-configured external Chromium-family browser profile reachable over the Chrome DevTools
/// Protocol (CDP) on `127.0.0.1:<port>`. Never embeds WebKit.
public struct BrowserProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var port: Int
    /// Custom Chromium `--user-data-dir`; nil defaults to `~/.soprano-agents/browsers/<id>`.
    public var userDataDirectory: String?
    /// Explicit Chromium/Chrome/Chrome Beta/Brave binary path; nil auto-discovers an installed browser.
    public var binaryPath: String?
    /// Extra flags passed to the browser binary when launched.
    public var extraArgs: [String]

    public init(
        id: String,
        label: String? = nil,
        port: Int,
        userDataDirectory: String? = nil,
        binaryPath: String? = nil,
        extraArgs: [String] = []
    ) {
        self.id = id
        self.label = (label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? label! : id
        self.port = port
        self.userDataDirectory = userDataDirectory
        self.binaryPath = binaryPath
        self.extraArgs = extraArgs
    }

    public var cdpURL: String {
        "http://127.0.0.1:\(port)"
    }

    public func resolvedUserDataDirectory(home: String = NSHomeDirectory()) -> String {
        if let userDataDirectory, !userDataDirectory.isEmpty {
            return expandTilde(userDataDirectory, home: home)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".soprano-agents/browsers/\(id)", isDirectory: true)
            .path
    }

    private func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }
}

/// Maps a working directory, project name or git remote URL to a `BrowserProfile.id`.
public struct BrowserMatchRule: Codable, Sendable, Hashable {
    public var profileID: String
    public var pathPrefixes: [String]
    public var gitRemoteSubstrings: [String]
    public var projectNames: [String]

    public init(
        profileID: String,
        pathPrefixes: [String] = [],
        gitRemoteSubstrings: [String] = [],
        projectNames: [String] = []
    ) {
        self.profileID = profileID
        self.pathPrefixes = pathPrefixes
        self.gitRemoteSubstrings = gitRemoteSubstrings
        self.projectNames = projectNames
    }
}

/// Shared Chromium/CDP browser automation settings (`browsers` in `settings.json`).
/// Ships disabled with zero hardcoded profiles so any user can define their own profiles, routing
/// rules, external resolver CLI, or custom browser MCP server.
public struct BrowserSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Fallback profile id when no rule matches; nil falls back to the first configured profile.
    public var defaultProfile: String?
    /// Idle owned tabs/windows are closed automatically after this many seconds (0 disables).
    public var idleCloseSeconds: Int
    /// Optional external CLI command printing a local CDP URL (`http://127.0.0.1:<port>`),
    /// e.g. `["~/.omp/ai-browser/ai-browser", "url", "--path", "{cwd}"]`.
    public var resolverCommand: [String]?
    /// Optional custom browser MCP server replacing Soprano Agents' built-in CDP browser MCP.
    public var customMcpCommand: MCPServerSpec?
    /// Also inject `chrome-devtools-mcp` pointing at the resolved profile's `--browserUrl`.
    public var includeChromeDevtoolsMcp: Bool
    public var profiles: [BrowserProfile]
    public var rules: [BrowserMatchRule]

    public init(
        enabled: Bool = false,
        defaultProfile: String? = nil,
        idleCloseSeconds: Int = 1800,
        resolverCommand: [String]? = nil,
        customMcpCommand: MCPServerSpec? = nil,
        includeChromeDevtoolsMcp: Bool = false,
        profiles: [BrowserProfile] = [],
        rules: [BrowserMatchRule] = []
    ) {
        self.enabled = enabled
        self.defaultProfile = defaultProfile
        self.idleCloseSeconds = idleCloseSeconds
        self.resolverCommand = resolverCommand
        self.customMcpCommand = customMcpCommand
        self.includeChromeDevtoolsMcp = includeChromeDevtoolsMcp
        self.profiles = profiles
        self.rules = rules
    }
}

/// The resolved CDP browser target for a thread's working directory.
public struct ResolvedBrowserProfile: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case explicit
        case rule
        case resolver
        case fallback
    }

    public var profile: BrowserProfile?
    public var cdpURL: String
    public var source: Source

    public init(profile: BrowserProfile?, cdpURL: String, source: Source) {
        self.profile = profile
        self.cdpURL = cdpURL
        self.source = source
    }
}

/// Live health of one configured CDP browser profile.
public struct BrowserProfileStatus: Sendable, Hashable {
    public var profileID: String
    public var port: Int
    public var isRunning: Bool
    public var browserVersion: String?
    public var webSocketDebuggerURL: String?

    public init(
        profileID: String,
        port: Int,
        isRunning: Bool,
        browserVersion: String? = nil,
        webSocketDebuggerURL: String? = nil
    ) {
        self.profileID = profileID
        self.port = port
        self.isRunning = isRunning
        self.browserVersion = browserVersion
        self.webSocketDebuggerURL = webSocketDebuggerURL
    }
}
