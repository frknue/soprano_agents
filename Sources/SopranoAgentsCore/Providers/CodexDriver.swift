import Foundation

/// Codex driver: sessions on `codex app-server --stdio` (`CodexSession`), status and model
/// catalog via `initialize` + `account/read` + `model/list`, skill discovery via `skills/list`,
/// and one-shot `generateJSON` via an ephemeral app-server thread with `outputSchema`.
public struct CodexDriver: ProviderDriver {
    public let kind = ProviderKind.codex
    static let probeTimeout: TimeInterval = 30
    static let generationTimeout: TimeInterval = 180

    private let executablePath: @Sendable () -> String?
    private let launchAdjustments: @Sendable () -> ProviderLaunchAdjustments

    public init(
        executablePath: @escaping @Sendable () -> String? = { nil },
        launchAdjustments: @escaping @Sendable () -> ProviderLaunchAdjustments = { .none }
    ) {
        self.executablePath = executablePath
        self.launchAdjustments = launchAdjustments
    }

    public func makeSession() -> any ProviderSession {
        CodexSession(executablePath: executablePath, launchAdjustments: launchAdjustments)
    }

    /// `codex --version`, then a short-lived `codex app-server --stdio` for `account/read` and
    /// `model/list`.
    public func probe() async -> ProviderStatus {
        let fallback = ProviderCatalog.fallback(.codex)
        let explicit = executablePath()
        guard let executable = CodexProtocol.locateExecutable(explicitPath: explicit) else {
            return ProviderStatus(
                kind: .codex,
                health: .notInstalled,
                models: fallback,
                message: ProviderError.notInstalled(.codex, path: explicit).localizedDescription
            )
        }
        let adjustments = launchAdjustments()
        let version: String?
        do {
            let output = try await LineProcess.run(
                LineProcess.Configuration(
                    executable: executable,
                    arguments: ["--version"],
                    environment: CodexProtocol.environment(adjustments: adjustments),
                    directory: NSHomeDirectory()
                ),
                timeout: Self.probeTimeout,
                label: "Codex status check"
            )
            guard output.status == 0 else {
                return ProviderStatus(
                    kind: .codex,
                    health: .error,
                    models: fallback,
                    message: ProviderError.processExited(.codex, status: output.status, stderr: output.stderr).localizedDescription
                )
            }
            version = CodexProtocol.version(fromVersionOutput: output.stdout)
        } catch {
            return ProviderStatus(kind: .codex, health: .error, models: fallback, message: error.localizedDescription)
        }

        do {
            return try await withAppServer(executable: executable, adjustments: adjustments, directory: nil, timeout: Self.probeTimeout, label: "Codex status check") { client in
                let account = try await client.request("account/read", ["refreshToken": false])
                guard CodexProtocol.isAuthenticated(accountResponse: account) else {
                    return ProviderStatus(
                        kind: .codex,
                        health: .unauthenticated,
                        version: version,
                        models: fallback,
                        message: "Sign in with `codex login` or add an account in Settings › Accounts."
                    )
                }
                let entries = try await Self.fetchAllModels(client)
                let models = CodexProtocol.models(from: entries)
                let plan = CodexProtocol.accountPlan(from: account)
                let shownVersion = [version, plan].compactMap { $0 }.joined(separator: " · ")
                return ProviderStatus(
                    kind: .codex,
                    health: .ready,
                    version: shownVersion.isEmpty ? nil : shownVersion,
                    models: models
                )
            }
        } catch {
            return ProviderStatus(kind: .codex, health: .error, version: version, models: fallback, message: error.localizedDescription)
        }
    }

    /// Reads Codex skills available in `directory` without starting a persistent session.
    public func commands(directory: String) async -> [ProviderCommand]? {
        let explicit = executablePath()
        guard let executable = CodexProtocol.locateExecutable(explicitPath: explicit) else { return nil }
        let adjustments = launchAdjustments()
        return try? await withAppServer(executable: executable, adjustments: adjustments, directory: directory, timeout: 15, label: "Codex skills list") { client in
            let response = try await client.request("skills/list", ["cwds": [.string(directory)]])
            return CodexProtocol.skills(from: response).commands
        }
    }

    /// One-shot structured JSON generation using an ephemeral Codex app-server thread with
    /// `sandbox: "read-only"`, `approvalPolicy: "never"`, and `outputSchema`.
    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        let explicit = executablePath()
        guard let executable = CodexProtocol.locateExecutable(explicitPath: explicit) else {
            throw ProviderError.notInstalled(.codex, path: explicit)
        }
        let adjustments = launchAdjustments()
        let text = try await withAppServer(executable: executable, adjustments: adjustments, directory: nil, timeout: Self.generationTimeout, label: "Codex text generation") { client in
            var startParams: [String: JSONValue] = [
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
            ]
            if model != ModelSelection.configuredDefaultModel {
                startParams["model"] = .string(model)
            }
            let started = try await client.request("thread/start", .object(startParams))
            guard let threadID = started["thread"]?["id"]?.nonEmptyString else {
                throw ProviderError.invalidOutput("Codex did not return a thread id for text generation.")
            }

            let reader = Task { () throws -> String in
                var streamed = ""
                var finalText: String?
                for await message in client.incoming {
                    switch message {
                    case let .notification("item/agentMessage/delta", params):
                        if let delta = params["delta"]?.stringValue { streamed += delta }
                    case let .notification("item/completed", params):
                        if params["item"]?["type"]?.stringValue == "agentMessage",
                           let text = params["item"]?["text"]?.nonEmptyString {
                            finalText = text
                        }
                    case let .notification("turn/completed", params):
                        let turn = params["turn"] ?? .null
                        if turn["status"]?.stringValue == "failed" {
                            let message = turn["error"]?["message"]?.nonEmptyString ?? "Codex text generation failed."
                            throw ProviderError.message(message)
                        }
                        return finalText ?? streamed
                    case let .request(rpcID, _, _):
                        try? await client.respond(to: rpcID, result: CodexProtocol.approvalResponse(.decline))
                    case let .closed(status, stderr):
                        throw ProviderError.processExited(.codex, status: status, stderr: stderr)
                    default:
                        break
                    }
                }
                throw ProviderError.notStarted
            }
            defer { reader.cancel() }

            let promptText = ProviderPrompt.generationPrompt(prompt, schema: schema)
            var turnParams: [String: JSONValue] = [
                "threadId": .string(threadID),
                "input": [["type": "text", "text": .string(promptText), "text_elements": []]],
                "approvalPolicy": "never",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
                "effort": "low",
                "outputSchema": schema,
            ]
            if model != ModelSelection.configuredDefaultModel {
                turnParams["model"] = .string(model)
            }
            _ = try await client.request("turn/start", .object(turnParams))
            return try await reader.value
        }
        return try ProviderPrompt.firstJSONObject(in: text)
    }

    // MARK: - Helpers

    private static func fetchAllModels(_ client: AcpClient) async throws -> [JSONValue] {
        var all: [JSONValue] = []
        var cursor: String?
        for _ in 0..<10 {
            var params: [String: JSONValue] = ["limit": 100]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await client.request("model/list", .object(params))
            all += page["data"]?.arrayValue ?? []
            guard let next = page["nextCursor"]?.nonEmptyString else { break }
            cursor = next
        }
        return all
    }

    private func withAppServer<T: Sendable>(
        executable: String,
        adjustments: ProviderLaunchAdjustments,
        directory: String?,
        timeout: TimeInterval,
        label: String,
        _ body: @escaping @Sendable (AcpClient) async throws -> T
    ) async throws -> T {
        var tempFolder: URL?
        let workDir: String
        if let directory, FileManager.default.fileExists(atPath: directory) {
            workDir = directory
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-codex-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            tempFolder = folder
            workDir = folder.path
        }
        defer {
            if let tempFolder { try? FileManager.default.removeItem(at: tempFolder) }
        }
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: CodexProtocol.arguments(adjustments: adjustments),
            environment: CodexProtocol.environment(adjustments: adjustments),
            directory: workDir
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        let client = AcpClient(transport: process, kind: .codex)
        defer { process.terminate() }
        return try await withProviderTimeout(timeout, label: label) {
            _ = try await client.request("initialize", CodexProtocol.initializeParams)
            try await client.notify("initialized")
            return try await body(client)
        }
    }
}
