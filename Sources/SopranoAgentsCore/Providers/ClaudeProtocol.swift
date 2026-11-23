import Foundation

/// Anthropic's Claude Code CLI (`claude --print --output-format stream-json --input-format
/// stream-json`): launch flags, auth/plan parsing, model catalog, permission/plan modes, MCP
/// config serialization, control protocol builders and user message encoding.
/// Wire contract verified against Claude Code `2.1.325`.
public enum ClaudeProtocol {
    // MARK: - Executable and launch

    public static func locateExecutable(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        ExecutableLocator.locate("claude", explicitPath: explicitPath, environment: environment, home: home)
    }

    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        adjustments: ProviderLaunchAdjustments = .none
    ) -> [String: String] {
        var env = ExecutableLocator.childEnvironment(base: base)
        // Avoid nested Claude Code session detection when launched from an existing Claude shell.
        env["CLAUDECODE"] = nil
        return adjustments.environment(over: env)
    }

    /// Launch arguments for a live interactive stream-json session.
    public static func sessionArguments(
        config: SessionConfig,
        mcpConfigPath: String? = nil,
        adjustments: ProviderLaunchAdjustments = .none
    ) -> [String] {
        var args = [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--forward-subagent-text",
            "--allow-dangerously-skip-permissions",
            "--permission-mode", permissionMode(for: config.runtimeMode, interactionMode: .standard),
        ]
        if let resumeID = config.resumeID, !resumeID.isEmpty {
            args += ["--resume", resumeID]
        }
        if let model = modelValue(config.modelSelection) {
            args += ["--model", model]
        }
        if let effort = config.modelSelection.effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if let promptFile = config.systemPromptFile, !promptFile.isEmpty {
            args += ["--append-system-prompt-file", promptFile]
        }
        if let mcpConfigPath, !mcpConfigPath.isEmpty {
            args += ["--mcp-config", mcpConfigPath]
        }
        return adjustments.arguments(before: args)
    }

    /// Arguments for a short-lived probe / command-discovery stream-json process.
    public static func probeArguments(adjustments: ProviderLaunchAdjustments = .none) -> [String] {
        adjustments.arguments(before: [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--permission-prompt-tool", "stdio",
            "--no-session-persistence",
        ])
    }

    /// Arguments for one-shot structured JSON generation (`generateJSON`).
    public static func generationArguments(
        schema: JSONValue,
        model: String,
        adjustments: ProviderLaunchAdjustments = .none
    ) -> [String] {
        var args = [
            "--print",
            "--output-format", "json",
            "--no-session-persistence",
            "--tools", "",
            "--effort", "low",
            "--json-schema", schema.jsonString(),
        ]
        if model != ModelSelection.configuredDefaultModel {
            args += ["--model", model]
        }
        return adjustments.arguments(before: args)
    }

    /// Serializes `MCPServerSpec` items into Claude Code's `--mcp-config` JSON format.
    public static func mcpConfigJSON(_ servers: [MCPServerSpec]) -> JSONValue {
        var mapped: [String: JSONValue] = [:]
        for server in servers {
            switch server.transport {
            case let .stdio(command, args, env):
                var entry: [String: JSONValue] = [
                    "type": "stdio",
                    "command": .string(command),
                    "args": .array(args.map(JSONValue.string)),
                ]
                if !env.isEmpty {
                    entry["env"] = .object(env.mapValues(JSONValue.string))
                }
                mapped[server.name] = .object(entry)
            case let .http(url, headers):
                var entry: [String: JSONValue] = [
                    "type": "http",
                    "url": .string(url),
                ]
                if !headers.isEmpty {
                    entry["headers"] = .object(headers.mapValues(JSONValue.string))
                }
                mapped[server.name] = .object(entry)
            }
        }
        return ["mcpServers": .object(mapped)]
    }

    /// `"2.1.325"` from `"2.1.325 (Claude Code)"`.
    public static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.first?.isNumber == true }
    }

    // MARK: - Auth and catalog

    /// Parses `claude auth status` JSON output (tolerating any trailing non-JSON lines).
    public static func isAuthenticated(authOutput: String) -> Bool {
        guard let json = try? ProviderPrompt.firstJSONObject(in: authOutput) else { return false }
        return json["loggedIn"]?.boolValue == true
    }

    /// Readable subscription/plan label from `initialize`'s `account` object or `claude auth status`.
    public static func accountPlan(from account: JSONValue?) -> String? {
        guard let account, account != .null else { return nil }
        if let sub = account["subscriptionType"]?.nonEmptyString {
            switch sub.lowercased() {
            case "max": return "Claude Max"
            case "pro": return "Claude Pro"
            case "team": return "Claude Team"
            case "enterprise": return "Claude Enterprise"
            default: return sub
            }
        }
        if let provider = account["apiProvider"]?.nonEmptyString, provider != "firstParty" {
            return provider
        }
        return nil
    }

    /// Builds the model catalog from `initialize`'s `models` array.
    public static func models(from entries: [JSONValue]) -> [ProviderModel] {
        guard !entries.isEmpty else { return ProviderCatalog.fallback(.claude) }
        var result: [ProviderModel] = []
        var seen: Set<String> = []

        if let defaultEntry = entries.first(where: { $0["value"]?.stringValue == "default" }) {
            let desc = defaultEntry["description"]?.nonEmptyString ?? defaultEntry["resolvedModel"]?.nonEmptyString
            let label = desc.map { "\($0) · default" } ?? ProviderCatalog.defaultModelName(.claude)
            result.append(ProviderModel(
                slug: ModelSelection.configuredDefaultModel,
                name: label,
                isDefault: true,
                options: modelOptions(for: defaultEntry)
            ))
            seen.insert(ModelSelection.configuredDefaultModel)
        } else if let first = entries.first {
            let label = (first["displayName"]?.nonEmptyString ?? ProviderCatalog.defaultModelName(.claude)) + " · default"
            result.append(ProviderModel(
                slug: ModelSelection.configuredDefaultModel,
                name: label,
                isDefault: true,
                options: modelOptions(for: first)
            ))
            seen.insert(ModelSelection.configuredDefaultModel)
        }

        for entry in entries {
            guard let slug = entry["value"]?.nonEmptyString,
                  slug != ModelSelection.configuredDefaultModel,
                  seen.insert(slug).inserted else { continue }
            let name = entry["displayName"]?.nonEmptyString ?? slug
            result.append(ProviderModel(slug: slug, name: name, options: modelOptions(for: entry)))
        }
        return result
    }

    static func modelOptions(for entry: JSONValue) -> [ModelOption] {
        var options: [ModelOption] = []
        let levels = (entry["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.nonEmptyString)
        if !levels.isEmpty {
            let defaultEffort = levels.contains("high") ? "high" : (levels.contains("medium") ? "medium" : levels[0])
            options.append(ProviderCatalog.effortOption(levels, default: defaultEffort))
        }
        if entry["supportsFastMode"]?.boolValue == true {
            options.append(ModelOption(
                id: ModelOptionID.fastMode,
                label: "Fast Mode",
                kind: .boolean,
                defaultValue: "false"
            ))
        }
        return options
    }

    /// Converts `initialize` / `commands_changed` command arrays into composer `/` menu items.
    public static func commands(from list: JSONValue?) -> [ProviderCommand] {
        (list?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.nonEmptyString else { return nil }
            let description = entry["description"]?.nonEmptyString
            let hint = entry["argumentHint"]?.nonEmptyString
            let isSkill = description?.hasSuffix("(user)") == true || description?.hasSuffix("(project)") == true
            return ProviderCommand(
                name: name,
                kind: isSkill ? .skill : .command,
                description: description,
                argumentHint: hint,
                source: isSkill ? "Skill" : "Built-in",
                insertText: "/\(name) "
            )
        }
    }

    // MARK: - Modes and selections

    public static func modelValue(_ selection: ModelSelection) -> String? {
        selection.model == ModelSelection.configuredDefaultModel ? nil : selection.model
    }

    public static func permissionMode(for runtimeMode: RuntimeMode, interactionMode: InteractionMode) -> String {
        if interactionMode == .plan { return "plan" }
        return switch runtimeMode {
        case .approvalRequired: "default"
        case .autoAcceptEdits: "acceptEdits"
        case .auto: "auto"
        case .fullAccess: "bypassPermissions"
        }
    }

    // MARK: - Wire frame builders

    public static func controlRequest(id: String, request: JSONValue) -> JSONValue {
        ["type": "control_request", "request_id": .string(id), "request": request]
    }

    public static func controlSuccess(requestID: String, response: JSONValue) -> JSONValue {
        [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": .string(requestID),
                "response": response,
            ],
        ]
    }

    /// Encodes a `TurnInput` as a Claude Code `stream-json` `user` frame (plain text or text +
    /// base64 image blocks up to 10 MB).
    public static func userMessageFrame(_ input: TurnInput) -> JSONValue {
        let text = ProviderPrompt.text(input.text, attachments: input.attachments)
        let images = input.attachments.filter { $0.kind == .image && $0.byteSize <= 10 * 1024 * 1024 }
        if images.isEmpty {
            return ["type": "user", "message": ["role": "user", "content": .string(text)]]
        }
        var blocks: [JSONValue] = []
        if !text.isEmpty {
            blocks.append(["type": "text", "text": .string(text)])
        }
        for image in images {
            guard let data = FileManager.default.contents(atPath: image.path) else { continue }
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": .string(image.mimeType),
                    "data": .string(data.base64EncodedString()),
                ],
            ])
        }
        return ["type": "user", "message": ["role": "user", "content": .array(blocks)]]
    }

    /// Builds the `can_use_tool` response for an approval decision.
    public static func permissionResponse(
        decision: ApprovalDecision,
        originalInput: JSONValue,
        suggestions: JSONValue?
    ) -> JSONValue {
        switch decision {
        case .accept:
            return ["behavior": "allow", "updatedInput": originalInput]
        case .acceptForSession:
            var payload: [String: JSONValue] = ["behavior": "allow", "updatedInput": originalInput]
            if let suggestions, let array = suggestions.arrayValue, !array.isEmpty {
                payload["updatedPermissions"] = .array(array)
            }
            return .object(payload)
        case .decline:
            return ["behavior": "deny", "message": "User declined this tool call."]
        case .cancel:
            return ["behavior": "deny", "message": "User cancelled.", "interrupt": true]
        }
    }

    /// Builds the `can_use_tool` response for `AskUserQuestion`: maps question id → question text
    /// into `updatedInput.answers` (Claude's expected shape).
    public static func askUserQuestionResponse(
        answers: [String: [String]],
        questionTextByID: [String: String],
        originalInput: JSONValue
    ) -> JSONValue {
        if answers.isEmpty {
            return ["behavior": "deny", "message": "User dismissed the question."]
        }
        var answerMap: [String: JSONValue] = [:]
        for (id, values) in answers {
            let key = questionTextByID[id] ?? id
            answerMap[key] = .string(values.joined(separator: ", "))
        }
        var updated = originalInput.objectValue ?? [:]
        updated["answers"] = .object(answerMap)
        return ["behavior": "allow", "updatedInput": .object(updated)]
    }
}
