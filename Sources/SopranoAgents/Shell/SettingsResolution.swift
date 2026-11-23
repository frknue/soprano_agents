import Foundation
import SopranoAgentsCore

/// A problem found while resolving settings.json. Issues never block startup:
/// a bad value keeps its default and is logged (Soprano's `ConfigIssue`).
struct ConfigIssue: Equatable, Identifiable, Sendable {
    enum Severity: Equatable, Sendable {
        /// The document could not be read at all; the last good settings stay in force.
        case error
        /// One key was ignored; everything else applied.
        case warning
    }

    let severity: Severity
    let message: String
    /// 1-based line in settings.json, when the problem has a position.
    var line: Int?

    var id: String { "\(severity)-\(line ?? 0)-\(message)" }
}

/// A `keybindings.bindings` value: one chord, several, or `null` to unbind.
enum BindingOverride: Equatable, Sendable {
    case chords([String])
    case disabled
}

/// Raw keybinding settings, applied to the command registry by `Keymap.resolve`.
struct KeybindingSettings: Equatable, Sendable {
    var prefixKey = "a"
    var prefixTimeoutMs = 1500
    var overrides: [String: BindingOverride] = [:]
}

/// settings.json applied on top of the defaults.
struct ResolvedSettings: Equatable, Sendable {
    var settings = AppSettings.defaults
    var keybindings = KeybindingSettings()
    var issues: [ConfigIssue] = []

    static let defaults = ResolvedSettings()
}

enum SettingsResolver {
    enum Limits {
        static let prefixTimeoutMs = 300...5000
    }

    /// Parses JSONC text. Throws `JSONCText.ParseError` (or a decoding error)
    /// when the document is not a JSON object.
    static func resolve(text: String) throws -> ResolvedSettings {
        let data = try JSONCText.strictJSONData(from: text)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = object as? [String: Any] else {
            throw JSONCText.ParseError(message: "The settings document must be a JSON object", line: 1, column: 1)
        }
        return resolve(root)
    }

    static func resolve(_ root: [String: Any]) -> ResolvedSettings {
        var result = ResolvedSettings()
        var issues: [ConfigIssue] = []
        func warn(_ message: String) {
            issues.append(ConfigIssue(severity: .warning, message: message))
        }

        let knownTopLevel: Set<String> = ["theme", "agents", "providers", "textGeneration", "worktrees", "projects", "resources", "mcpServers", "browsers", "workflows", "chat", "notifications", "remote", "editor", "keybindings"]
        for key in root.keys.sorted() where !knownTopLevel.contains(key) {
            warn("Unknown setting \"\(key)\".")
        }

        if let value = root["theme"] {
            if let theme = value as? String, theme == "soprano" || AppTheme.isKnownId(theme) {
                result.settings.theme = theme
            } else {
                let known = (["soprano"] + AppTheme.options.map(\.id)).joined(separator: ", ")
                warn("Unknown theme \(describe(value)). Known themes: \(known).")
            }
        }

        if let agents = section("agents", in: root, warn: warn) {
            for key in agents.keys.sorted() where !["defaultProvider", "defaultModel", "defaultRuntimeMode"].contains(key) {
                warn("Unknown setting \"agents.\(key)\".")
            }
            if let value = agents["defaultProvider"] {
                if let provider = providerKind(value) {
                    result.settings.defaultProvider = provider
                } else {
                    warn("agents.defaultProvider must be \(knownProviders).")
                }
            }
            if let value = agents["defaultModel"] {
                if let model = value as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.settings.defaultModel = model
                } else {
                    warn("agents.defaultModel must be a model id string.")
                }
            }
            if let value = agents["defaultRuntimeMode"] {
                if let raw = value as? String, let mode = RuntimeMode(rawValue: raw) {
                    result.settings.defaultRuntimeMode = mode
                } else {
                    let known = RuntimeMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                    warn("agents.defaultRuntimeMode must be one of \(known).")
                }
            }
        }

        if let providers = section("providers", in: root, warn: warn) {
            for key in providers.keys.sorted() where !["ompPath", "codexPath", "claudePath", "opencodePath", "antigravityPath"].contains(key) {
                warn("Unknown setting \"providers.\(key)\".")
            }
            result.settings.ompPath = optionalPath(providers["ompPath"], key: "providers.ompPath", warn: warn) ?? result.settings.ompPath
            result.settings.codexPath = optionalPath(providers["codexPath"], key: "providers.codexPath", warn: warn) ?? result.settings.codexPath
            result.settings.claudePath = optionalPath(providers["claudePath"], key: "providers.claudePath", warn: warn) ?? result.settings.claudePath
            result.settings.opencodePath = optionalPath(providers["opencodePath"], key: "providers.opencodePath", warn: warn) ?? result.settings.opencodePath
            result.settings.antigravityPath = optionalPath(providers["antigravityPath"], key: "providers.antigravityPath", warn: warn) ?? result.settings.antigravityPath
        }

        if let generation = section("textGeneration", in: root, warn: warn) {
            for key in generation.keys.sorted() where !["provider", "model", "titles"].contains(key) {
                warn("Unknown setting \"textGeneration.\(key)\".")
            }
            if let value = generation["provider"] {
                if let provider = providerKind(value) {
                    result.settings.textGenerationProvider = provider
                } else {
                    warn("textGeneration.provider must be \(knownProviders).")
                }
            }
            if let value = generation["model"] {
                if let model = value as? String, !model.isEmpty {
                    result.settings.textGenerationModel = model
                } else {
                    warn("textGeneration.model must be a model id string.")
                }
            }
            if let value = generation["titles"] {
                if let enabled = value as? Bool {
                    result.settings.generateTitles = enabled
                } else {
                    warn("textGeneration.titles must be true or false.")
                }
            }
        }

        if let worktrees = section("worktrees", in: root, warn: warn) {
            for key in worktrees.keys.sorted() where !["directory", "branchPrefix"].contains(key) {
                warn("Unknown setting \"worktrees.\(key)\".")
            }
            if let value = worktrees["directory"] {
                if let path = value as? String, !path.isEmpty, expandingTilde(path).hasPrefix("/"), expandingTilde(path) != "/" {
                    result.settings.worktreesDirectory = expandingTilde(path)
                } else {
                    warn("worktrees.directory must be an absolute folder (not /).")
                }
            }
            if let value = worktrees["branchPrefix"] {
                if let prefix = value as? String, !prefix.contains(" ") {
                    result.settings.branchPrefix = prefix
                } else {
                    warn("worktrees.branchPrefix must be a string without spaces.")
                }
            }
        }

        if let projects = section("projects", in: root, warn: warn) {
            for key in projects.keys.sorted() where key != "directories" {
                warn("Unknown setting \"projects.\(key)\".")
            }
            if let value = projects["directories"] {
                if let entries = value as? [Any], entries.allSatisfy({ $0 is String }) {
                    var directories: [String] = []
                    for raw in entries.compactMap({ $0 as? String }) {
                        let path = URL(fileURLWithPath: expandingTilde(raw)).standardizedFileURL.path
                        var isDirectory: ObjCBool = false
                        guard raw.hasPrefix("/") || raw.hasPrefix("~"),
                              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                            warn("projects.directories: \"\(raw)\" is not a folder.")
                            continue
                        }
                        if !directories.contains(path) { directories.append(path) }
                    }
                    result.settings.projectDirectories = directories
                } else {
                    warn("projects.directories must be an array of folder paths.")
                }
            }
        }

        if let resources = section("resources", in: root, warn: warn) {
            let known: Set<String> = ["extraDirectories", "importMcpFiles", "injectInstructions", "injectMcp"]
            for key in resources.keys.sorted() where !known.contains(key) {
                warn("Unknown setting \"resources.\(key)\".")
            }
            if let value = resources["extraDirectories"] {
                if let entries = value as? [Any], entries.allSatisfy({ $0 is String }) {
                    result.settings.resources.extraDirectories = entries.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                } else {
                    warn("resources.extraDirectories must be an array of folder paths.")
                }
            }
            if let value = resources["importMcpFiles"] {
                if let entries = value as? [Any], entries.allSatisfy({ $0 is String }) {
                    result.settings.resources.importMcpFiles = entries.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                } else {
                    warn("resources.importMcpFiles must be an array of file paths.")
                }
            }
            if let value = resources["injectInstructions"] {
                if let flag = value as? Bool { result.settings.resources.injectInstructions = flag } else { warn("resources.injectInstructions must be true or false.") }
            }
            if let value = resources["injectMcp"] {
                if let flag = value as? Bool { result.settings.resources.injectMcp = flag } else { warn("resources.injectMcp must be true or false.") }
            }
        }

        if let mcp = section("mcpServers", in: root, warn: warn) {
            var mapped: [String: JSONValue] = [:]
            for (name, raw) in mcp {
                if let json = try? JSONSerialization.data(withJSONObject: raw),
                   let text = String(data: json, encoding: .utf8),
                   let value = try? JSONValue.parse(text) {
                    mapped[name] = value
                } else {
                    warn("mcpServers.\(name) must be an MCP server object.")
                }
            }
            result.settings.resources.mcpServers = ResourceCatalog.parseMCPDictionary(mapped)
        }

        if let browsers = section("browsers", in: root, warn: warn) {
            let known: Set<String> = [
                "enabled", "defaultProfile", "idleCloseSeconds", "resolverCommand",
                "customMcpCommand", "includeChromeDevtoolsMcp", "profiles", "rules",
            ]
            for key in browsers.keys.sorted() where !known.contains(key) {
                warn("Unknown setting \"browsers.\(key)\".")
            }
            if let value = browsers["enabled"] {
                if let flag = value as? Bool { result.settings.browsers.enabled = flag } else { warn("browsers.enabled must be true or false.") }
            }
            if let value = browsers["defaultProfile"] {
                if let profile = value as? String, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.settings.browsers.defaultProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if value is NSNull {
                    result.settings.browsers.defaultProfile = nil
                } else {
                    warn("browsers.defaultProfile must be a profile id string.")
                }
            }
            if let value = browsers["idleCloseSeconds"] {
                if let seconds = integer(value), seconds >= 0 {
                    result.settings.browsers.idleCloseSeconds = seconds
                } else {
                    warn("browsers.idleCloseSeconds must be a non-negative integer.")
                }
            }
            if let value = browsers["includeChromeDevtoolsMcp"] {
                if let flag = value as? Bool { result.settings.browsers.includeChromeDevtoolsMcp = flag } else { warn("browsers.includeChromeDevtoolsMcp must be true or false.") }
            }
            if let value = browsers["resolverCommand"] {
                if let array = value as? [Any], array.allSatisfy({ $0 is String }) {
                    let tokens = array.compactMap { $0 as? String }.filter { !$0.isEmpty }
                    result.settings.browsers.resolverCommand = tokens.isEmpty ? nil : tokens
                } else if value is NSNull {
                    result.settings.browsers.resolverCommand = nil
                } else {
                    warn("browsers.resolverCommand must be an array of command arguments.")
                }
            }
            if let value = browsers["customMcpCommand"] {
                if value is NSNull {
                    result.settings.browsers.customMcpCommand = nil
                } else if let obj = value as? [String: Any],
                          let json = try? JSONSerialization.data(withJSONObject: obj),
                          let text = String(data: json, encoding: .utf8),
                          let parsed = try? JSONValue.parse(text) {
                    let rawName = parsed["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = (rawName?.isEmpty == false) ? rawName! : "soprano-browser"
                    if let spec = ResourceCatalog.parseMCPDictionary([name: parsed]).first {
                        result.settings.browsers.customMcpCommand = spec
                    } else {
                        warn("browsers.customMcpCommand must define \"command\" or \"url\".")
                    }
                } else {
                    warn("browsers.customMcpCommand must be an MCP server object.")
                }
            }
            if let value = browsers["profiles"] {
                if let entries = value as? [Any] {
                    var profiles: [BrowserProfile] = []
                    var seenIDs: Set<String> = []
                    for (index, raw) in entries.enumerated() {
                        guard let obj = raw as? [String: Any],
                              let id = (obj["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                              let port = obj["port"].flatMap(integer), (1...65535).contains(port)
                        else {
                            warn("browsers.profiles[\(index)] must have non-empty \"id\" and valid \"port\" (1–65535).")
                            continue
                        }
                        if seenIDs.contains(id) {
                            warn("Duplicate browser profile id \"\(id)\".")
                            continue
                        }
                        seenIDs.insert(id)
                        let label = obj["label"] as? String
                        let userDataDir = obj["userDataDirectory"] as? String
                        let binaryPath = obj["binaryPath"] as? String
                        let extraArgs = (obj["extraArgs"] as? [Any])?.compactMap { $0 as? String } ?? []
                        profiles.append(BrowserProfile(
                            id: id,
                            label: label,
                            port: port,
                            userDataDirectory: userDataDir,
                            binaryPath: binaryPath,
                            extraArgs: extraArgs
                        ))
                    }
                    result.settings.browsers.profiles = profiles
                } else {
                    warn("browsers.profiles must be an array of profile objects.")
                }
            }
            if let value = browsers["rules"] {
                if let entries = value as? [Any] {
                    var rules: [BrowserMatchRule] = []
                    for (index, raw) in entries.enumerated() {
                        guard let obj = raw as? [String: Any],
                              let profileID = ((obj["profile"] ?? obj["profileID"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !profileID.isEmpty
                        else {
                            warn("browsers.rules[\(index)] must specify \"profile\".")
                            continue
                        }
                        let pathPrefixes = (obj["pathPrefixes"] as? [Any])?.compactMap { $0 as? String } ?? []
                        let gitRemoteSubstrings = (obj["gitRemoteSubstrings"] as? [Any])?.compactMap { $0 as? String } ?? []
                        let projectNames = (obj["projectNames"] as? [Any])?.compactMap { $0 as? String } ?? []
                        rules.append(BrowserMatchRule(
                            profileID: profileID,
                            pathPrefixes: pathPrefixes,
                            gitRemoteSubstrings: gitRemoteSubstrings,
                            projectNames: projectNames
                        ))
                    }
                    result.settings.browsers.rules = rules
                } else {
                    warn("browsers.rules must be an array of match rule objects.")
                }
            }
        }

        if let workflows = section("workflows", in: root, warn: warn) {
            let known: Set<String> = ["advisorEnabled", "advisorProvider", "advisorModel", "advisorPrompt", "autoRecapEnabled"]
            for key in workflows.keys.sorted() where !known.contains(key) {
                warn("Unknown setting \"workflows.\(key)\".")
            }
            if let value = workflows["advisorEnabled"] {
                if let flag = value as? Bool { result.settings.workflows.advisorEnabled = flag } else { warn("workflows.advisorEnabled must be true or false.") }
            }
            if let value = workflows["advisorProvider"] {
                if value is NSNull {
                    result.settings.workflows.advisorProvider = nil
                } else if let provider = providerKind(value) {
                    result.settings.workflows.advisorProvider = provider
                } else {
                    warn("workflows.advisorProvider must be \(knownProviders).")
                }
            }
            if let value = workflows["advisorModel"] {
                if value is NSNull {
                    result.settings.workflows.advisorModel = nil
                } else if let model = value as? String, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.settings.workflows.advisorModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    warn("workflows.advisorModel must be a model id string.")
                }
            }
            if let value = workflows["advisorPrompt"] {
                if let prompt = value as? String {
                    result.settings.workflows.advisorPrompt = prompt
                } else if value is NSNull {
                    result.settings.workflows.advisorPrompt = ""
                } else {
                    warn("workflows.advisorPrompt must be a string.")
                }
            }
            if let value = workflows["autoRecapEnabled"] {
                if let flag = value as? Bool { result.settings.workflows.autoRecapEnabled = flag } else { warn("workflows.autoRecapEnabled must be true or false.") }
            }
        }

        if let chat = section("chat", in: root, warn: warn) {
            for key in chat.keys.sorted() where !["followUp", "width", "workLog"].contains(key) {
                warn("Unknown setting \"chat.\(key)\".")
            }
            if let value = chat["followUp"] {
                if let raw = value as? String, let mode = AppSettings.FollowUp(rawValue: raw) {
                    result.settings.followUp = mode
                } else {
                    warn("chat.followUp must be \"steer\" or \"queue\".")
                }
            }
            if let value = chat["width"] {
                if let raw = value as? String, let width = AppSettings.ChatWidth(rawValue: raw) {
                    result.settings.chatWidth = width
                } else {
                    warn("chat.width must be \"normal\", \"wide\" or \"full\".")
                }
            }
            if let value = chat["workLog"] {
                if let raw = value as? String, let workLog = AppSettings.WorkLog(rawValue: raw) {
                    result.settings.workLog = workLog
                } else {
                    warn("chat.workLog must be \"detailed\" or \"minimal\".")
                }
            }
        }

        if let notifications = section("notifications", in: root, warn: warn) {
            for key in notifications.keys.sorted() where !["enabled", "sound"].contains(key) {
                warn("Unknown setting \"notifications.\(key)\".")
            }
            if let value = notifications["enabled"] {
                if let enabled = value as? Bool { result.settings.notificationsEnabled = enabled } else { warn("notifications.enabled must be true or false.") }
            }
            if let value = notifications["sound"] {
                if let enabled = value as? Bool { result.settings.notificationSound = enabled } else { warn("notifications.sound must be true or false.") }
            }
        }

        if let remote = section("remote", in: root, warn: warn) {
            let flags: [(String, WritableKeyPath<AppSettings.Remote, Bool>)] = [
                ("enabled", \.enabled), ("launchAtLogin", \.launchAtLogin), ("preventSleep", \.preventSleep), ("push", \.push),
            ]
            let ports: [(String, WritableKeyPath<AppSettings.Remote, Int>)] = [("port", \.port), ("httpsPort", \.httpsPort)]
            let known = Set(flags.map(\.0) + ports.map(\.0))
            for key in remote.keys.sorted() where !known.contains(key) {
                warn("Unknown setting \"remote.\(key)\".")
            }
            for (key, path) in flags {
                guard let value = remote[key] else { continue }
                if let flag = value as? Bool { result.settings.remote[keyPath: path] = flag } else { warn("remote.\(key) must be true or false.") }
            }
            for (key, path) in ports {
                guard let value = remote[key] else { continue }
                if let port = integer(value), (1...65535).contains(port) {
                    result.settings.remote[keyPath: path] = port
                } else {
                    warn("remote.\(key) must be a port number (1–65535).")
                }
            }
        }

        if let editor = section("editor", in: root, warn: warn) {
            for key in editor.keys.sorted() where key != "app" {
                warn("Unknown setting \"editor.\(key)\".")
            }
            if let value = editor["app"] {
                if let app = value as? String, !app.isEmpty {
                    result.settings.editorApp = app
                } else if value is NSNull {
                    result.settings.editorApp = nil
                } else {
                    warn("editor.app must be an editor id (cursor, vscode, zed, xcode, finder, …) or null.")
                }
            }
        }

        if let keybindings = section("keybindings", in: root, warn: warn) {
            for key in keybindings.keys.sorted() where !["prefixKey", "prefixTimeoutMs", "bindings"].contains(key) {
                warn("Unknown setting \"keybindings.\(key)\".")
            }
            if let value = keybindings["prefixKey"] {
                let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.count == 1 {
                    result.keybindings.prefixKey = trimmed.lowercased()
                } else {
                    warn("keybindings.prefixKey must be a single character; kept \"\(result.keybindings.prefixKey)\".")
                }
            }
            if let value = keybindings["prefixTimeoutMs"] {
                if let timeout = integer(value) {
                    let clamped = clamp(timeout, to: Limits.prefixTimeoutMs)
                    if clamped != timeout {
                        warn("keybindings.prefixTimeoutMs must be \(Limits.prefixTimeoutMs.lowerBound)–\(Limits.prefixTimeoutMs.upperBound); clamped to \(clamped).")
                    }
                    result.keybindings.prefixTimeoutMs = clamped
                } else {
                    warn("keybindings.prefixTimeoutMs must be a number.")
                }
            }
            if let value = keybindings["bindings"] {
                if let bindings = value as? [String: Any] {
                    for id in bindings.keys.sorted() {
                        let entry = bindings[id]
                        if entry is NSNull {
                            result.keybindings.overrides[id] = .disabled
                        } else if let chord = entry as? String {
                            result.keybindings.overrides[id] = .chords([chord])
                        } else if let chords = entry as? [Any], chords.allSatisfy({ $0 is String }) {
                            result.keybindings.overrides[id] = .chords(chords.compactMap { $0 as? String })
                        } else {
                            warn("keybindings.bindings.\(id) must be a chord string, an array of chords, or null.")
                        }
                    }
                } else {
                    warn("keybindings.bindings must be an object of command id → chord.")
                }
            }
        }

        result.issues = issues
        return result
    }

    private static func section(
        _ key: String,
        in root: [String: Any],
        warn: (String) -> Void
    ) -> [String: Any]? {
        guard let value = root[key] else { return nil }
        guard let object = value as? [String: Any] else {
            warn("\"\(key)\" must be an object.")
            return nil
        }
        return object
    }

    private static func providerKind(_ value: Any) -> ProviderKind? {
        (value as? String).flatMap(ProviderKind.init(rawValue:))
    }

    /// `"omp", "opencode" or "antigravity"`.
    private static var knownProviders: String {
        let names = ProviderKind.allCases.map { "\"\($0.rawValue)\"" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
    }

    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(range.lowerBound, value), range.upperBound)
    }

    /// A path string, `null` (nil inside `.some`), or a warning (nil).
    private static func optionalPath(_ value: Any?, key: String, warn: (String) -> Void) -> String?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        if let path = value as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return .some(expandingTilde(path))
        }
        warn("\(key) must be a path string or null.")
        return nil
    }

    private static func expandingTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        return String(describing: value)
    }
}
