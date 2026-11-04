import Foundation

/// OpenCode v2 API payloads: pure translation between the app's types and the server's JSON.
/// No I/O. Shapes are those of OpenCode 2.2 (`GET /openapi.json`).
public enum OpencodeProtocol {
    // MARK: - CLI

    /// `opencode --version` output ("opencode v2.2.5") → "2.2.5".
    public static func version(fromVersionOutput output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let token = line.split(separator: " ").last.map(String.init), !token.isEmpty else { return nil }
        return token.hasPrefix("v") ? String(token.dropFirst()) : token
    }

    // MARK: - Models

    /// `providerID/modelID` → (provider, id), split at the first `/` (model ids may contain
    /// more slashes, e.g. `opengateway/deepseek/deepseek-v4`). nil for
    /// `ModelSelection.configuredDefaultModel` and malformed slugs.
    public static func modelSpec(_ slug: String) -> (provider: String, id: String)? {
        guard slug != ModelSelection.configuredDefaultModel, let slash = slug.firstIndex(of: "/") else { return nil }
        let provider = String(slug[..<slash])
        let id = String(slug[slug.index(after: slash)...])
        guard !provider.isEmpty, !id.isEmpty else { return nil }
        return (provider, id)
    }

    /// The variant a selection asks for: its effort, else OpenCode's `default` variant.
    public static let defaultVariant = "default"

    /// `Model.Ref` `{id, providerID, variant}` for `provider`/`id` and the selection's effort.
    public static func modelRef(provider: String, id: String, effort: String?) -> JSONValue {
        ["id": .string(id), "providerID": .string(provider), "variant": .string(effort ?? defaultVariant)]
    }

    /// The probe catalog from `GET /api/model` (`data`) and `GET /api/model/default` (`data`):
    /// first `slug: "default"` = OpenCode's configured model, named "<name> · configured",
    /// then every enabled model as `providerID/modelID`, named "<name> · <providerID>".
    /// Models with variants get a "Reasoning" option: "default" (OpenCode's own choice) then
    /// the variant ids.
    public static func models(list: JSONValue?, defaultModel: JSONValue?) -> [ProviderModel] {
        var models: [ProviderModel] = []
        if let current = defaultModel, current.objectValue != nil {
            let name = current["name"]?.nonEmptyString ?? current["id"]?.stringValue ?? ProviderCatalog.defaultModelName(.opencode)
            models.append(ProviderModel(slug: ModelSelection.configuredDefaultModel, name: "\(name) · configured", isDefault: true, options: variantOptions(current)))
        } else {
            models.append(ProviderModel(slug: ModelSelection.configuredDefaultModel, name: ProviderCatalog.defaultModelName(.opencode), isDefault: true))
        }
        for model in list?.arrayValue ?? [] {
            guard model["enabled"]?.boolValue != false,
                  let provider = model["providerID"]?.nonEmptyString,
                  let id = model["id"]?.nonEmptyString else { continue }
            let name = model["name"]?.nonEmptyString ?? id
            models.append(ProviderModel(slug: "\(provider)/\(id)", name: "\(name) · \(provider)", options: variantOptions(model)))
        }
        return models
    }

    static func variantOptions(_ model: JSONValue) -> [ModelOption] {
        let variants = (model["variants"]?.arrayValue ?? []).compactMap { $0["id"]?.nonEmptyString }.filter { $0 != defaultVariant }
        guard !variants.isEmpty else { return [] }
        return [ProviderCatalog.effortOption([defaultVariant] + variants, default: defaultVariant)]
    }

    /// Context window per slug (`limit.context`), the configured model under "default".
    public static func contextWindows(list: JSONValue?, defaultModel: JSONValue?) -> [String: Int] {
        var windows: [String: Int] = [:]
        for model in list?.arrayValue ?? [] {
            guard let provider = model["providerID"]?.nonEmptyString, let id = model["id"]?.nonEmptyString,
                  let window = model["limit"]?["context"]?.intValue, window > 0 else { continue }
            windows["\(provider)/\(id)"] = window
        }
        if let window = defaultModel?["limit"]?["context"]?.intValue, window > 0 {
            windows[ModelSelection.configuredDefaultModel] = window
        }
        return windows
    }

    // MARK: - Permissions

    /// The session's permission rules for a runtime mode. OpenCode checks them after the agent's
    /// own rules (the last match wins), so they only tighten or loosen what they name; denies the
    /// user configured for other actions stay.
    /// - Supervised: ask before editing files, running commands and leaving the workspace.
    /// - Auto-accept edits: edit freely; ask before commands and leaving the workspace.
    /// - Auto: no rules (OpenCode's configuration decides).
    /// - Full access: allow edits, commands, reads, the web and other directories.
    public static func permissions(_ mode: RuntimeMode) -> JSONValue {
        func rules(_ actions: [String], _ effect: String) -> [JSONValue] {
            actions.map { ["action": .string($0), "resource": "*", "effect": .string(effect)] }
        }
        switch mode {
        case .approvalRequired:
            return .array(rules(["edit", "shell", "external_directory"], "ask"))
        case .autoAcceptEdits:
            return .array(rules(["edit"], "allow") + rules(["shell", "external_directory"], "ask"))
        case .auto:
            return []
        case .fullAccess:
            return .array(rules(["edit", "shell", "external_directory", "read", "webfetch", "websearch"], "allow"))
        }
    }

    /// `session.permissions` reply for a decision: once, always (this session), or reject.
    /// Decline rejects with feedback, so the agent carries on without the action; Cancel rejects
    /// without it, which stops the run.
    public static func permissionReply(_ decision: ApprovalDecision) -> JSONValue {
        switch decision {
        case .accept: ["decision": "once"]
        case .acceptForSession: ["decision": "always"]
        case .decline: ["decision": "reject", "message": .string(declineMessage)]
        case .cancel: ["decision": "reject"]
        }
    }

    static let declineMessage = "The user declined this. Do not retry it; continue without it or ask how to proceed."

    /// `permission.asked {id, action, resources, metadata?, message?}` → an approval: shell →
    /// command (the command line), edit → file change (the files), read → file read, anything
    /// else → other ("<action>: <resources>").
    public static func approval(_ request: JSONValue, cwd: String?) -> ApprovalRequest? {
        guard let id = request["id"]?.nonEmptyString else { return nil }
        let action = request["action"]?.stringValue ?? ""
        let resources = (request["resources"]?.arrayValue ?? []).compactMap(\.stringValue)
        let kind: ApprovalKind
        let detail: String
        switch action {
        case "shell", "bash":
            kind = .command
            detail = resources.joined(separator: "\n")
        case "edit", "write":
            kind = .fileChange
            let files = (request["metadata"]?["files"]?.arrayValue ?? []).compactMap { $0["file"]?.nonEmptyString }
            detail = (files.isEmpty ? resources : files).map { displayPath($0, cwd: cwd) }.joined(separator: "\n")
        case "read":
            kind = .fileRead
            detail = resources.map { displayPath($0, cwd: cwd) }.joined(separator: "\n")
        default:
            kind = .other
            detail = resources.isEmpty ? action : "\(action): \(resources.joined(separator: ", "))"
        }
        return ApprovalRequest(id: id, kind: kind, detail: detail.isEmpty ? action : detail, reason: request["message"]?.nonEmptyString)
    }

    // MARK: - Forms

    /// `form.created` `form {id, title, fields}` → questions: string fields with options are
    /// single choice (free text when `custom`), multiselect fields multiple choice, booleans
    /// Yes/No, numbers and options-less strings free text. Hidden and external fields are left
    /// out. nil when nothing is left to ask.
    public static func userInput(form: JSONValue) -> UserInputRequest? {
        guard let id = form["id"]?.nonEmptyString else { return nil }
        let questions = (form["fields"]?.arrayValue ?? []).compactMap { field -> UserInputQuestion? in
            guard let key = field["key"]?.nonEmptyString, field["hidden"]?.boolValue != true else { return nil }
            let title = field["title"]?.nonEmptyString
            let text = field["description"]?.nonEmptyString ?? title ?? form["title"]?.nonEmptyString ?? key
            let header = field["description"]?.nonEmptyString == nil ? "" : title ?? ""
            let options = (field["options"]?.arrayValue ?? []).compactMap { option -> UserInputOption? in
                guard let label = option["label"]?.nonEmptyString ?? option["value"]?.nonEmptyString else { return nil }
                return UserInputOption(label: label, description: option["description"]?.nonEmptyString)
            }
            let custom = field["custom"]?.boolValue ?? false
            switch field["type"]?.stringValue {
            case "string":
                return UserInputQuestion(id: key, header: header, question: text, options: options, allowsOther: options.isEmpty || custom)
            case "multiselect":
                return UserInputQuestion(id: key, header: header, question: text, options: options, allowsMultiple: true, allowsOther: custom)
            case "boolean":
                return UserInputQuestion(id: key, header: header, question: text, options: [UserInputOption(label: "Yes"), UserInputOption(label: "No")], allowsOther: false)
            case "number", "integer":
                return UserInputQuestion(id: key, header: header, question: text, options: [], allowsOther: true)
            default:
                return nil
            }
        }
        guard !questions.isEmpty else { return nil }
        return UserInputRequest(id: id, questions: questions)
    }

    /// `Form.Reply` `{answer: {key: value}}` for the user's answers (question id = field key):
    /// option labels become their values; strings join several answers with newlines,
    /// multiselects send the list, booleans `Yes` → true, numbers parse. Unanswered and
    /// unparsable fields are left out.
    public static func formReply(form: JSONValue, answers: [String: [String]]) -> JSONValue {
        var answer: [String: JSONValue] = [:]
        for field in form["fields"]?.arrayValue ?? [] {
            guard let key = field["key"]?.nonEmptyString else { continue }
            let values = (answers[key] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !values.isEmpty else { continue }
            let options = field["options"]?.arrayValue ?? []
            func value(of label: String) -> String {
                options.first { $0["label"]?.stringValue == label }?["value"]?.stringValue ?? label
            }
            switch field["type"]?.stringValue {
            case "multiselect":
                answer[key] = .array(values.map { .string(value(of: $0)) })
            case "boolean":
                answer[key] = .bool(values[0].caseInsensitiveCompare("Yes") == .orderedSame)
            case "number":
                if let number = Double(values[0].trimmingCharacters(in: .whitespaces)) { answer[key] = .number(number) }
            case "integer":
                if let number = Int(values[0].trimmingCharacters(in: .whitespaces)) { answer[key] = .number(Double(number)) }
            default:
                answer[key] = .string(values.map(value(of:)).joined(separator: "\n"))
            }
        }
        return ["answer": .object(answer)]
    }

    // MARK: - Messages

    /// What a turn's text asks OpenCode for.
    public enum Message: Sendable, Hashable {
        /// `POST /api/session/{id}/prompt`.
        case prompt(JSONValue)
        /// `POST /api/session/{id}/command` (a slash command OpenCode lists).
        case command(JSONValue)
    }

    /// `/name args` of a listed command → `command {name, text: args, files}`; `/skill:<id> rest`
    /// of a listed skill → a prompt with the skill attached; anything else → `prompt {text,
    /// files}`. Images go along as `file://` attachments; every attachment's path is listed in
    /// the text. `delivery` "steer" delivers into a running execution (and starts one when idle).
    public static func message(_ input: TurnInput, commands: Set<String>, skills: Set<String>, delivery: String? = nil) -> Message {
        let files: [JSONValue] = input.attachments.filter { $0.kind == .image }.map { attachment in
            ["uri": .string(URL(fileURLWithPath: attachment.path).absoluteString), "name": .string(attachment.name)]
        }
        var body: [String: JSONValue] = [:]
        if !files.isEmpty { body["files"] = .array(files) }
        if let delivery { body["delivery"] = .string(delivery) }

        let trimmed = input.text.drop { $0.isWhitespace }
        if trimmed.hasPrefix("/") {
            let head = trimmed.dropFirst().prefix { !$0.isWhitespace }
            let rest = trimmed.dropFirst(head.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("skill:"), skills.contains(String(head.dropFirst("skill:".count))) {
                body["text"] = .string(ProviderPrompt.text(rest.isEmpty ? input.text : rest, attachments: input.attachments))
                body["skills"] = [["id": .string(String(head.dropFirst("skill:".count)))]]
                return .prompt(.object(body))
            }
            if commands.contains(String(head)) {
                body["name"] = .string(String(head))
                body["text"] = .string(ProviderPrompt.text(rest, attachments: input.attachments))
                return .command(.object(body))
            }
        }
        body["text"] = .string(ProviderPrompt.text(input.text, attachments: input.attachments))
        return .prompt(.object(body))
    }

    /// `GET /api/command` and `GET /api/skill` lists → menu entries: commands insert
    /// `/<name> ` (names with a `:` come from MCP servers), skills `/skill:<id> `.
    public static func commands(_ commands: JSONValue?, skills: JSONValue?) -> [ProviderCommand] {
        let commandEntries = (commands?.arrayValue ?? []).compactMap { entry -> ProviderCommand? in
            guard let name = entry["name"]?.nonEmptyString else { return nil }
            return ProviderCommand(
                name: name,
                kind: .command,
                description: entry["description"]?.nonEmptyString,
                source: name.contains(":") ? ProviderCommand.badge(forSource: "mcp") : nil,
                insertText: "/\(name) "
            )
        }
        let skillEntries = (skills?.arrayValue ?? []).compactMap { entry -> ProviderCommand? in
            guard let id = entry["id"]?.nonEmptyString else { return nil }
            return ProviderCommand(
                name: "skill:\(id)",
                kind: .skill,
                description: entry["description"]?.nonEmptyString,
                source: ProviderCommand.badge(forSource: "skill"),
                insertText: "/skill:\(id) "
            )
        }
        return commandEntries + skillEntries
    }

    // MARK: - Usage

    /// A step's `tokens {input, output, reasoning, cache{read, write}}` as the context fill
    /// (input + output + cache read + cache write; the next request carries all of it).
    public static func contextUsage(_ tokens: JSONValue?, contextWindow: Int?) -> TokenUsage? {
        guard let tokens, tokens.objectValue != nil else { return nil }
        let used = [tokens["input"], tokens["output"], tokens["cache"]?["read"], tokens["cache"]?["write"]]
            .compactMap { $0?.intValue }
            .reduce(0, +)
        guard used > 0 else { return nil }
        return TokenUsage(usedTokens: used, contextWindow: contextWindow)
    }

    // MARK: - Side questions

    /// The `POST /api/session/{id}/generate` prompt for a side question: answered from the
    /// conversation without tools, with the topic's earlier exchanges for a follow-up.
    public static func sideQuestionPrompt(_ question: String, earlier: [SideQuestionExchange]) -> String {
        var prompt = "Answer this side question about our conversation so far. Answer from what you already know; do not use tools, and do not continue the task.\n"
        let answered = earlier.filter { !$0.answer.isEmpty }
        if !answered.isEmpty {
            prompt += "\nEarlier in this side discussion:\n"
            for exchange in answered {
                prompt += "\nQuestion: \(exchange.question)\nAnswer: \(exchange.answer)\n"
            }
        }
        prompt += "\nQuestion: \(question)"
        return prompt
    }

    // MARK: - Paths

    /// A path OpenCode reported, relative to `cwd` when inside it. OpenCode reports tool files
    /// relative to its project root, which for an unversioned folder is not the workspace: a
    /// relative path is read against the workspace, else against the home folder (the
    /// service's own folder) when the file is there.
    static func displayPath(_ path: String, cwd: String?, home: String = NSHomeDirectory()) -> String {
        guard !path.hasPrefix("/") else { return OmpEventMapper.relative(path, to: cwd) }
        let candidates = [cwd, home].compactMap { $0 }.map { URL(fileURLWithPath: $0).appendingPathComponent(path).standardizedFileURL.path }
        let resolved = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates.first ?? path
        return OmpEventMapper.relative(resolved, to: cwd)
    }

    /// A `FileDiff.Info` patch (`Index:`/`===`/`---`/`+++` headers, then hunks) → its hunks.
    static func hunks(_ patch: String?) -> String? {
        guard let patch, let start = patch.range(of: "@@") else { return nil }
        let hunks = patch[start.lowerBound...].trimmingCharacters(in: .newlines)
        return hunks.isEmpty ? nil : hunks
    }
}
