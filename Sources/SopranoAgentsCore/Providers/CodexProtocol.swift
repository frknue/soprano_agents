import Foundation

/// OpenAI's Codex CLI as an app-server (`codex app-server --stdio`, JSON-RPC 2.0 over stdio):
/// launch, handshake, catalog, modes, collaboration/plan mode, skills, approvals and prompts.
/// Wire contract verified against `codex-cli 0.144.6` (`codex app-server generate-ts`).
public enum CodexProtocol {
    // MARK: - Executable and launch

    public static func locateExecutable(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        ExecutableLocator.locate("codex", explicitPath: explicitPath, environment: environment, home: home)
    }

    /// `app-server --stdio`, plus any session-injected MCP servers as `-c` TOML overrides.
    public static func arguments(mcpServers: [MCPServerSpec] = [], adjustments: ProviderLaunchAdjustments = .none) -> [String] {
        var args = ["app-server", "--stdio"]
        for server in mcpServers {
            let key = "mcp_servers.\(tomlKey(server.name))"
            switch server.transport {
            case let .stdio(command, serverArgs, env):
                args += ["-c", "\(key).command=\(tomlString(command))"]
                if !serverArgs.isEmpty {
                    let encoded = serverArgs.map(tomlString).joined(separator: ", ")
                    args += ["-c", "\(key).args=[\(encoded)]"]
                }
                for (envKey, envValue) in env.sorted(by: { $0.key < $1.key }) {
                    args += ["-c", "\(key).env.\(tomlKey(envKey))=\(tomlString(envValue))"]
                }
            case let .http(url, headers):
                args += ["-c", "\(key).url=\(tomlString(url))"]
                for (headerKey, headerValue) in headers.sorted(by: { $0.key < $1.key }) {
                    args += ["-c", "\(key).http_headers.\(tomlKey(headerKey))=\(tomlString(headerValue))"]
                }
            }
        }
        return adjustments.arguments(before: args)
    }

    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        adjustments: ProviderLaunchAdjustments = .none
    ) -> [String: String] {
        adjustments.environment(over: ExecutableLocator.childEnvironment(base: base))
    }

    /// `initialize` params: opt into experimentalApi so Plan mode (`collaborationMode`) and
    /// structured `requestUserInput` work natively.
    static let initializeParams: JSONValue = [
        "clientInfo": ["name": "soprano-agents", "title": "Soprano Agents", "version": "1"],
        "capabilities": ["experimentalApi": true, "requestAttestation": false],
    ]

    /// `"0.144.6"` from `codex-cli 0.144.6`.
    public static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.first?.isNumber == true }
    }

    // MARK: - Auth and catalog

    /// Authenticated when `account/read` returns a non-null `account` or does not require OpenAI auth.
    public static func isAuthenticated(accountResponse: JSONValue) -> Bool {
        if let account = accountResponse["account"], account != .null { return true }
        return accountResponse["requiresOpenaiAuth"]?.boolValue == false
    }

    /// Human-readable plan label from `account/read` ("ChatGPT Pro", "API key", …).
    public static func accountPlan(from accountResponse: JSONValue) -> String? {
        guard let account = accountResponse["account"], account != .null else { return nil }
        switch account["type"]?.stringValue {
        case "chatgpt":
            guard let plan = account["planType"]?.nonEmptyString else { return "ChatGPT" }
            switch plan {
            case "free": return "ChatGPT Free"
            case "go": return "ChatGPT Go"
            case "plus": return "ChatGPT Plus"
            case "pro": return "ChatGPT Pro"
            case "prolite": return "ChatGPT Pro Lite"
            case "team": return "ChatGPT Team"
            case "business", "self_serve_business_usage_based": return "ChatGPT Business"
            case "enterprise", "enterprise_cbp_usage_based": return "ChatGPT Enterprise"
            case "edu": return "ChatGPT Edu"
            default: return "ChatGPT"
            }
        case "apiKey":
            return "API key"
        case "amazonBedrock":
            return "Bedrock"
        default:
            return nil
        }
    }

    /// Builds the model catalog from `model/list` entries: first `default` ("<displayName> · default"),
    /// then every visible model with its reasoning efforts and Fast Mode option when offered.
    public static func models(from entries: [JSONValue]) -> [ProviderModel] {
        let visible = entries.filter { $0["hidden"]?.boolValue != true }
        guard !visible.isEmpty else { return ProviderCatalog.fallback(.codex) }

        let defaultEntry = visible.first { $0["isDefault"]?.boolValue == true } ?? visible[0]
        var result: [ProviderModel] = []
        let defaultName = defaultEntry["displayName"]?.nonEmptyString
            ?? defaultEntry["model"]?.nonEmptyString
            ?? ProviderCatalog.defaultModelName(.codex)
        result.append(ProviderModel(
            slug: ModelSelection.configuredDefaultModel,
            name: "\(defaultName) · default",
            isDefault: true,
            options: modelOptions(for: defaultEntry)
        ))

        var seen: Set<String> = []
        for entry in visible {
            guard let slug = entry["model"]?.nonEmptyString ?? entry["id"]?.nonEmptyString, seen.insert(slug).inserted else { continue }
            let name = entry["displayName"]?.nonEmptyString ?? slug
            result.append(ProviderModel(slug: slug, name: name, options: modelOptions(for: entry)))
        }
        return result
    }

    static func modelOptions(for entry: JSONValue) -> [ModelOption] {
        var options: [ModelOption] = []
        let effortEntries = entry["supportedReasoningEfforts"]?.arrayValue ?? []
        var choices: [ModelOptionChoice] = []
        var seenEfforts: Set<String> = []
        for item in effortEntries {
            guard let id = item["reasoningEffort"]?.nonEmptyString, seenEfforts.insert(id).inserted else { continue }
            choices.append(ModelOptionChoice(
                id: id,
                label: ProviderCatalog.effortLabel(id),
                description: item["description"]?.nonEmptyString
            ))
        }
        if !choices.isEmpty {
            let defaultEffort = entry["defaultReasoningEffort"]?.nonEmptyString
                .flatMap { id in choices.contains(where: { $0.id == id }) ? id : nil }
                ?? (choices.contains(where: { $0.id == "medium" }) ? "medium" : choices[0].id)
            options.append(ModelOption(
                id: ModelOptionID.effort,
                label: "Reasoning",
                kind: .select,
                choices: choices,
                defaultValue: defaultEffort
            ))
        }

        let serviceTierIDs = (entry["serviceTiers"]?.arrayValue ?? []).compactMap { $0["id"]?.nonEmptyString }
        let speedTiers = (entry["additionalSpeedTiers"]?.arrayValue ?? []).compactMap(\.nonEmptyString)
        if serviceTierIDs.contains("fast") || speedTiers.contains("fast") {
            let defaultFast = entry["defaultServiceTier"]?.stringValue == "fast"
            options.append(ModelOption(
                id: ModelOptionID.fastMode,
                label: "Fast Mode",
                kind: .boolean,
                defaultValue: defaultFast ? "true" : "false"
            ))
        }
        return options
    }

    // MARK: - Modes and selections

    public static func modelValue(_ selection: ModelSelection) -> String? {
        selection.model == ModelSelection.configuredDefaultModel ? nil : selection.model
    }

    public static func approvalPolicy(for mode: RuntimeMode) -> String {
        switch mode {
        case .approvalRequired: "untrusted"
        case .autoAcceptEdits, .auto: "on-request"
        case .fullAccess: "never"
        }
    }

    public static func sandboxMode(for mode: RuntimeMode) -> String {
        switch mode {
        case .approvalRequired, .autoAcceptEdits, .auto: "workspace-write"
        case .fullAccess: "danger-full-access"
        }
    }

    public static func sandboxPolicy(for mode: RuntimeMode, cwd: String) -> JSONValue {
        switch mode {
        case .fullAccess:
            return ["type": "dangerFullAccess"]
        case .approvalRequired, .autoAcceptEdits, .auto:
            return [
                "type": "workspaceWrite",
                "writableRoots": [.string(cwd)],
                "networkAccess": true,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            ]
        }
    }

    // MARK: - Skills and commands

    /// Converts `skills/list` into composer `/` menu items (`/skill:<name> `) and a name → path
    /// map so sending `/skill:<name> …` attaches Codex's native `{type:"skill", name, path}` item.
    public static func skills(from response: JSONValue) -> (commands: [ProviderCommand], paths: [String: String]) {
        var commands: [ProviderCommand] = []
        var paths: [String: String] = [:]
        var seen: Set<String> = []
        for entry in response["data"]?.arrayValue ?? [] {
            for skill in entry["skills"]?.arrayValue ?? [] {
                guard skill["enabled"]?.boolValue != false,
                      let name = skill["name"]?.nonEmptyString,
                      seen.insert(name).inserted else { continue }
                let description = skill["shortDescription"]?.nonEmptyString
                    ?? skill["interface"]?["shortDescription"]?.nonEmptyString
                    ?? skill["description"]?.nonEmptyString
                if let path = skill["path"]?.nonEmptyString {
                    paths[name] = path
                }
                commands.append(ProviderCommand(
                    name: "skill:\(name)",
                    kind: .skill,
                    description: description,
                    source: "Skill",
                    insertText: "/skill:\(name) "
                ))
            }
        }
        return (commands, paths)
    }

    // MARK: - Prompts and turn params

    /// Builds Codex `UserInput` items: optional native skill item when the message begins with
    /// `/skill:<name>`, the prompt text (with attachment paths listed), and `localImage` blocks.
    public static func userInput(_ input: TurnInput, skillPaths: [String: String] = [:]) -> [JSONValue] {
        var items: [JSONValue] = []
        var bodyText = input.text
        if let extracted = extractLeadingSkill(from: bodyText, skillPaths: skillPaths) {
            if let path = extracted.path {
                items.append(["type": "skill", "name": .string(extracted.name), "path": .string(path)])
                bodyText = extracted.remainder
            } else {
                bodyText = "$\(extracted.name)\(extracted.remainder.isEmpty ? "" : " \(extracted.remainder)")"
            }
        }
        let text = ProviderPrompt.text(bodyText, attachments: input.attachments)
        if !text.isEmpty || items.isEmpty {
            items.append(["type": "text", "text": .string(text), "text_elements": []])
        }
        for attachment in input.attachments where attachment.kind == .image {
            items.append(["type": "localImage", "path": .string(attachment.path)])
        }
        return items
    }

    private static func extractLeadingSkill(from text: String, skillPaths: [String: String]) -> (name: String, path: String?, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/skill:") else { return nil }
        let afterPrefix = trimmed.dropFirst("/skill:".count)
        let splitIndex = afterPrefix.firstIndex(where: \.isWhitespace) ?? afterPrefix.endIndex
        let name = String(afterPrefix[..<splitIndex])
        guard !name.isEmpty else { return nil }
        let remainder = String(afterPrefix[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, skillPaths[name], remainder)
    }

    /// Builds `turn/start` params, including `collaborationMode` for Plan mode (and explicit reset
    /// back to `"default"` when leaving Plan mode).
    public static func turnStartParams(
        threadID: String,
        input: TurnInput,
        cwd: String,
        defaultModel: String?,
        defaultEffort: String?,
        previousModeWasPlan: Bool,
        skillPaths: [String: String] = [:]
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(userInput(input, skillPaths: skillPaths)),
            "cwd": .string(cwd),
            "approvalPolicy": .string(approvalPolicy(for: input.runtimeMode)),
            "sandboxPolicy": sandboxPolicy(for: input.runtimeMode, cwd: cwd),
        ]
        if let model = modelValue(input.modelSelection) {
            params["model"] = .string(model)
        }
        if let effort = input.modelSelection.effort, !effort.isEmpty {
            params["effort"] = .string(effort)
        }
        if input.modelSelection.fastMode {
            params["serviceTier"] = "fast"
        }
        if input.interactionMode == .plan || previousModeWasPlan {
            let resolvedModel = modelValue(input.modelSelection) ?? defaultModel ?? ""
            if !resolvedModel.isEmpty {
                let resolvedEffort = input.modelSelection.effort ?? defaultEffort
                params["collaborationMode"] = [
                    "mode": .string(input.interactionMode.rawValue),
                    "settings": [
                        "model": .string(resolvedModel),
                        "reasoning_effort": resolvedEffort.map(JSONValue.string) ?? .null,
                        "developer_instructions": .null,
                    ],
                ]
            }
        }
        return .object(params)
    }

    // MARK: - Approvals and user input

    public static func approvalDecisionValue(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .accept: "accept"
        case .acceptForSession: "acceptForSession"
        case .decline: "decline"
        case .cancel: "cancel"
        }
    }

    public static func approvalResponse(_ decision: ApprovalDecision) -> JSONValue {
        ["decision": .string(approvalDecisionValue(decision))]
    }

    public static func userInputResponse(_ answers: [String: [String]]) -> JSONValue {
        var mapped: [String: JSONValue] = [:]
        for (questionID, values) in answers {
            mapped[questionID] = ["answers": .array(values.map(JSONValue.string))]
        }
        return ["answers": .object(mapped)]
    }

    /// Canonical string representation of a JSON-RPC request id (number or string).
    public static func requestIDString(_ id: JSONValue) -> String {
        if let text = id.stringValue { return text }
        if let number = id.intValue { return String(number) }
        return id.jsonString()
    }

    // MARK: - TOML helpers for `-c` overrides

    static func tomlKey(_ raw: String) -> String {
        if raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), !raw.isEmpty {
            return raw
        }
        return tomlString(raw)
    }

    static func tomlString(_ raw: String) -> String {
        JSONValue.string(raw).jsonString()
    }
}
