import Foundation

/// Google's Antigravity CLI as an ACP agent (`agy acp`): launch, profile, catalog, modes,
/// permissions and prompts. Wire facts recorded from agy 1.5.14.
///
/// Profile: the app keeps its own Antigravity profile (`--gemini-dir <data>/antigravity`, app
/// data under `antigravity-acp`), so its Google sign-in, conversations and settings never touch
/// the user's own `~/.gemini` or omp's. `agy acp … --login` signs in there: it prints a Google
/// link, the user pastes the code the callback page shows, and the token lands in
/// `antigravity-acp/antigravity-oauth-token`. agy 1.5 keeps Google sign-ins in one shared
/// keychain entry unless it believes it runs over SSH, so every launch sets `SSH_CONNECTION`
/// (file storage beside the profile), like T3 Code does.
public enum AntigravityProtocol {
    /// Joined beneath `--gemini-dir` by agy.
    static let appDataDirectory = "antigravity-acp"
    /// Variables that would override the profile's Google sign-in with another credential.
    static let removedEnvironment: Set<String> = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI",
    ]

    // MARK: - Profile and launch

    /// The app's Antigravity profile: `<data>/antigravity`.
    public static func profileDirectory(dataDirectory: URL) -> String {
        dataDirectory.appendingPathComponent("antigravity", isDirectory: true).path
    }

    /// Where `--login` stores the Google sign-in.
    public static func tokenPath(profile: String) -> String {
        (profile as NSString).appendingPathComponent("\(appDataDirectory)/antigravity-oauth-token")
    }

    public static func isSignedIn(profile: String) -> Bool {
        FileManager.default.fileExists(atPath: tokenPath(profile: profile))
    }

    /// `agy`: the explicit path (`providers.antigravityPath`, never second-guessed), else PATH and
    /// the tool directories, else the newest copy omp downloaded (`~/.omp/antigravity-cli/bin/<v>/agy`).
    public static func locateExecutable(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return ExecutableLocator.locate("agy", explicitPath: explicitPath, environment: environment, home: home)
        }
        if let found = ExecutableLocator.locate("agy", environment: environment, home: home) { return found }
        return managedExecutable(home: home)
    }

    /// The highest version under omp's managed agy folder.
    static func managedExecutable(home: String) -> String? {
        let base = "\(home)/.omp/antigravity-cli/bin"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        let sorted = versions.sorted { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
        for version in sorted.reversed() {
            let candidate = "\(base)/\(version)/agy"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func versionKey(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? -1 }
    }

    /// `acp --gemini-dir <profile> --app-data-dir antigravity-acp`.
    public static func arguments(profile: String) -> [String] {
        ["acp", "--gemini-dir", profile, "--app-data-dir", appDataDirectory]
    }

    /// The child environment: the app's (PATH extended), without Google credential overrides,
    /// pointed at the profile with file-based sign-in storage and no self-update.
    public static func environment(profile: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ExecutableLocator.childEnvironment(base: base)
        for key in removedEnvironment { environment[key] = nil }
        for (key, value) in launchVariables(profile: profile, base: base) { environment[key] = value }
        return environment
    }

    static func launchVariables(profile: String, base: [String: String]) -> [(String, String)] {
        [
            ("GEMINI_HOME", profile),
            ("SSH_CONNECTION", base["SSH_CONNECTION"] ?? "127.0.0.1 0 127.0.0.1 0"),
            ("AGY_ACP_FORCE_FILE_STORAGE", "1"),
            ("AGY_CLI_DISABLE_AUTO_UPDATE", "1"),
        ]
    }

    /// The shell line that signs in (a terminal, so the user can open the link and paste the
    /// code): `mkdir -p` the profile, then `VAR=… agy acp … --login`.
    public static func loginCommand(executable: String, profile: String, base: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let variables = launchVariables(profile: profile, base: base).map { "\($0.0)=\(shellQuoted($0.1))" }
        let command = ([shellQuoted(executable)] + (arguments(profile: profile) + ["--login"]).map(shellQuoted)).joined(separator: " ")
        return "mkdir -p \(shellQuoted(profile)) && \(variables.joined(separator: " ")) \(command)"
    }

    static func shellQuoted(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=".contains($0) }), !value.isEmpty { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Serializes `MCPServerSpec` items into ACP v1's `mcpServers` parameter array.
    public static func mcpServers(_ specs: [MCPServerSpec]) -> JSONValue {
        .array(specs.map { spec in
            switch spec.transport {
            case let .stdio(command, args, env):
                let envList = env.keys.sorted().map { key -> JSONValue in
                    ["name": .string(key), "value": .string(env[key] ?? "")]
                }
                return [
                    "name": .string(spec.name),
                    "command": .string(command),
                    "args": .array(args.map(JSONValue.string)),
                    "env": .array(envList),
                ]
            case let .http(url, headers):
                let headerList = headers.keys.sorted().map { key -> JSONValue in
                    ["name": .string(key), "value": .string(headers[key] ?? "")]
                }
                return [
                    "type": "http",
                    "name": .string(spec.name),
                    "url": .string(url),
                    "headers": .array(headerList),
                ]
            }
        })
    }

    /// `initialize` params: ACP v1, no client file system or terminal (agy uses its own tools).
    static let initializeParams: JSONValue = [
        "protocolVersion": 1,
        "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        "clientInfo": ["name": "soprano-agents", "title": "Soprano Agents", "version": "1"],
    ]

    /// `"1.5.14"` from `agy --version`.
    static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).map(String.init).first { $0.first?.isNumber == true }
    }

    // MARK: - Catalog

    /// The probe catalog from a `session/new` answer: first `default` (agy's own default model,
    /// named "<name> · default"), then every `model` config option value. Reasoning efforts per
    /// model come from `models.availableModels` (`<model>-<effort>` ids); a model without them
    /// gets no option.
    public static func models(session: JSONValue) -> [ProviderModel] {
        let option = configOption(session["configOptions"], id: "model")
        let values = choices(option)
        let available = (session["models"]?["availableModels"]?.arrayValue ?? []).compactMap { $0["modelId"]?.stringValue }
        let level = configOption(session["configOptions"], id: "thought_level")?["currentValue"]?.stringValue
        var models: [ProviderModel] = []
        let current = option?["currentValue"]?.stringValue
        if let current, let name = values.first(where: { $0.value == current })?.name {
            models.append(ProviderModel(
                slug: ModelSelection.configuredDefaultModel,
                name: "\(name) · default",
                isDefault: true,
                options: effortOptions(efforts(for: current, available: available), level: level)
            ))
        } else {
            models.append(ProviderModel(slug: ModelSelection.configuredDefaultModel, name: ProviderCatalog.defaultModelName(.antigravity), isDefault: true))
        }
        for value in values {
            models.append(ProviderModel(slug: value.value, name: value.name, options: effortOptions(efforts(for: value.value, available: available), level: level)))
        }
        return models
    }

    /// The account's plan (`_meta.antigravity.tier.name`, "Google AI Pro").
    static func tier(session: JSONValue) -> String? {
        session["_meta"]?["antigravity"]?["tier"]?["name"]?.nonEmptyString
    }

    static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// Efforts of `model` in agy's order: the suffixes of `<model>-<effort>` ids.
    static func efforts(for model: String, available: [String]) -> [String] {
        let found = Set(available.compactMap { id -> String? in
            guard id.hasPrefix(model + "-") else { return nil }
            let suffix = String(id.dropFirst(model.count + 1))
            return effortOrder.contains(suffix) ? suffix : nil
        })
        return effortOrder.filter(found.contains)
    }

    static func effortOptions(_ efforts: [String], level: String?) -> [ModelOption] {
        guard !efforts.isEmpty else { return [] }
        let defaultID = level.flatMap { efforts.contains($0) ? $0 : nil } ?? (efforts.contains("high") ? "high" : efforts.last!)
        return [ProviderCatalog.effortOption(efforts, default: defaultID)]
    }

    static func configOption(_ options: JSONValue?, id: String) -> JSONValue? {
        options?.arrayValue?.first { $0["id"]?.stringValue == id }
    }

    /// A select option's values (grouped options flattened).
    static func choices(_ option: JSONValue?) -> [(value: String, name: String)] {
        (option?["options"]?.arrayValue ?? []).flatMap { entry -> [JSONValue] in
            entry["options"]?.arrayValue ?? [entry]
        }.compactMap { entry in
            guard let value = entry["value"]?.nonEmptyString else { return nil }
            return (value, entry["name"]?.nonEmptyString ?? value)
        }
    }

    // MARK: - Selection and modes

    /// The `model` config value for a selection; nil for agy's default.
    static func modelValue(_ selection: ModelSelection) -> String? {
        selection.model == ModelSelection.configuredDefaultModel ? nil : selection.model
    }

    /// Runtime mode → agy's session mode: approval-required asks before edits and commands
    /// (`default`), auto-accept-edits → `accept-edits`, auto and full access → `auto` (full
    /// access also approves every request agy still sends).
    static func modeID(_ mode: RuntimeMode) -> String {
        switch mode {
        case .approvalRequired: "default"
        case .autoAcceptEdits: "accept-edits"
        case .auto, .fullAccess: "auto"
        }
    }

    // MARK: - Prompts

    /// `session/prompt` content: the text (attachment paths listed, `ProviderPrompt.text`) and
    /// each image attachment up to 10 MB as an image block.
    static func prompt(_ input: TurnInput) -> JSONValue {
        var blocks: [JSONValue] = [["type": "text", "text": .string(ProviderPrompt.text(input.text, attachments: input.attachments))]]
        for attachment in input.attachments where attachment.kind == .image && attachment.byteSize <= 10 * 1024 * 1024 {
            guard let data = FileManager.default.contents(atPath: attachment.path) else { continue }
            blocks.append(["type": "image", "mimeType": .string(attachment.mimeType), "data": .string(data.base64EncodedString())])
        }
        return .array(blocks)
    }

    /// `session/prompt`'s `stopReason` → the turn's outcome.
    static func outcome(stopReason: String?) -> (ProviderTurnOutcome, String?) {
        switch stopReason {
        case "cancelled": (.interrupted, nil)
        case "refusal": (.failed, "Antigravity refused to continue this turn.")
        case "max_tokens": (.completed, nil)
        case "max_turn_requests": (.completed, nil)
        default: (.completed, nil)
        }
    }

    // MARK: - Permissions

    /// Decisions an ACP permission request offers: Cancel always (it stops the turn), Decline
    /// for `reject_*`, Always allow for `allow_always`, Approve for `allow_once`.
    static func approvalOptions(_ options: [JSONValue]) -> [ApprovalDecision] {
        let kinds = Set(options.compactMap { $0["kind"]?.stringValue })
        var decisions: [ApprovalDecision] = [.cancel]
        if kinds.contains("reject_once") || kinds.contains("reject_always") { decisions.append(.decline) }
        if kinds.contains("allow_always") { decisions.append(.acceptForSession) }
        if kinds.contains("allow_once") || !kinds.contains("allow_always") { decisions.append(.accept) }
        return decisions
    }

    /// The answer to a permission request: the offered option of the decision's kind, else the
    /// closest one; `cancel` (or no matching option) answers `cancelled`.
    static func permissionOutcome(_ decision: ApprovalDecision, options: [JSONValue]) -> JSONValue {
        let preferred: [String] = switch decision {
        case .accept: ["allow_once", "allow_always"]
        case .acceptForSession: ["allow_always", "allow_once"]
        case .decline: ["reject_once", "reject_always"]
        case .cancel: []
        }
        for kind in preferred {
            if let id = options.first(where: { $0["kind"]?.stringValue == kind })?["optionId"]?.stringValue {
                return ["outcome": ["outcome": "selected", "optionId": .string(id)]]
            }
        }
        return ["outcome": ["outcome": "cancelled"]]
    }
}
