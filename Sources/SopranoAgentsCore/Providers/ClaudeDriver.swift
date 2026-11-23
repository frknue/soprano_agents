import Foundation

/// Claude Code driver: sessions on `claude --print --output-format stream-json --input-format
/// stream-json` (`ClaudeSession`), status and model catalog via `claude --version`,
/// `claude auth status`, and a short-lived `initialize` control handshake, command discovery via
/// `initialize`, and one-shot `generateJSON` via `--output-format json --json-schema`.
public struct ClaudeDriver: ProviderDriver {
    public let kind = ProviderKind.claude
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
        ClaudeSession(executablePath: executablePath, launchAdjustments: launchAdjustments)
    }

    public func probe() async -> ProviderStatus {
        let fallback = ProviderCatalog.fallback(.claude)
        let explicit = executablePath()
        guard let executable = ClaudeProtocol.locateExecutable(explicitPath: explicit) else {
            return ProviderStatus(
                kind: .claude,
                health: .notInstalled,
                models: fallback,
                message: ProviderError.notInstalled(.claude, path: explicit).localizedDescription
            )
        }
        let adjustments = launchAdjustments()
        let env = ClaudeProtocol.environment(adjustments: adjustments)

        let version: String?
        do {
            let output = try await LineProcess.run(
                LineProcess.Configuration(executable: executable, arguments: ["--version"], environment: env, directory: NSHomeDirectory()),
                timeout: Self.probeTimeout,
                label: "Claude Code status check"
            )
            guard output.status == 0 else {
                return ProviderStatus(
                    kind: .claude,
                    health: .error,
                    models: fallback,
                    message: ProviderError.processExited(.claude, status: output.status, stderr: output.stderr).localizedDescription
                )
            }
            version = ClaudeProtocol.version(fromVersionOutput: output.stdout)
        } catch {
            return ProviderStatus(kind: .claude, health: .error, models: fallback, message: error.localizedDescription)
        }

        // Check authentication before opening an initialize handshake.
        if let auth = try? await LineProcess.run(
            LineProcess.Configuration(executable: executable, arguments: ["auth", "status"], environment: env, directory: NSHomeDirectory()),
            timeout: 15,
            label: "Claude Code auth check"
        ), !ClaudeProtocol.isAuthenticated(authOutput: auth.stdout) {
            return ProviderStatus(
                kind: .claude,
                health: .unauthenticated,
                version: version,
                models: fallback,
                message: "Sign in with `claude auth login` or add an account in Settings › Accounts."
            )
        }

        do {
            let initBody = try await runInitialize(executable: executable, adjustments: adjustments, directory: nil, timeout: Self.probeTimeout)
            let models = ClaudeProtocol.models(from: initBody["models"]?.arrayValue ?? [])
            let plan = ClaudeProtocol.accountPlan(from: initBody["account"])
            let resolvedVersion = initBody["claude_code_version"]?.nonEmptyString ?? version
            let shownVersion = [resolvedVersion, plan].compactMap { $0 }.joined(separator: " · ")
            return ProviderStatus(
                kind: .claude,
                health: .ready,
                version: shownVersion.isEmpty ? nil : shownVersion,
                models: models
            )
        } catch {
            return ProviderStatus(kind: .claude, health: .error, version: version, models: fallback, message: error.localizedDescription)
        }
    }

    public func commands(directory: String) async -> [ProviderCommand]? {
        let explicit = executablePath()
        guard let executable = ClaudeProtocol.locateExecutable(explicitPath: explicit) else { return nil }
        let adjustments = launchAdjustments()
        guard let initBody = try? await runInitialize(executable: executable, adjustments: adjustments, directory: directory, timeout: 15) else {
            return nil
        }
        return ClaudeProtocol.commands(from: initBody["commands"])
    }

    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        let explicit = executablePath()
        guard let executable = ClaudeProtocol.locateExecutable(explicitPath: explicit) else {
            throw ProviderError.notInstalled(.claude, path: explicit)
        }
        let adjustments = launchAdjustments()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-claude-gen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = try await LineProcess.run(
            LineProcess.Configuration(
                executable: executable,
                arguments: ClaudeProtocol.generationArguments(schema: schema, model: model, adjustments: adjustments),
                environment: ClaudeProtocol.environment(adjustments: adjustments),
                directory: folder.path
            ),
            input: ProviderPrompt.generationPrompt(prompt, schema: schema),
            timeout: Self.generationTimeout,
            label: "Claude Code text generation"
        )
        guard output.status == 0 else {
            throw ProviderError.processExited(.claude, status: output.status, stderr: output.stderr)
        }
        if let envelope = try? ProviderPrompt.firstJSONObject(in: output.stdout) {
            if let structured = envelope["structured_output"], structured.objectValue != nil {
                return structured
            }
            if let resultText = envelope["result"]?.nonEmptyString {
                return try ProviderPrompt.firstJSONObject(in: resultText)
            }
            if envelope["type"] == nil {
                return envelope
            }
        }
        return try ProviderPrompt.firstJSONObject(in: output.stdout)
    }

    // MARK: - Helpers

    private func runInitialize(
        executable: String,
        adjustments: ProviderLaunchAdjustments,
        directory: String?,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        var tempFolder: URL?
        let workDir: String
        if let directory, FileManager.default.fileExists(atPath: directory) {
            workDir = directory
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-claude-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            tempFolder = folder
            workDir = folder.path
        }
        defer {
            if let tempFolder { try? FileManager.default.removeItem(at: tempFolder) }
        }

        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: ClaudeProtocol.probeArguments(adjustments: adjustments),
            environment: ClaudeProtocol.environment(adjustments: adjustments),
            directory: workDir
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        defer { process.terminate() }

        return try await withProviderTimeout(timeout, label: "Claude Code initialize") {
            let requestID = "probe-init-1"
            try process.send(ClaudeProtocol.controlRequest(id: requestID, request: ["subtype": "initialize"]).jsonString())
            for await event in process.incoming {
                switch event {
                case let .line(line):
                    guard let frame = try? JSONValue.parse(line),
                          frame["type"]?.stringValue == "control_response",
                          let response = frame["response"],
                          response["request_id"]?.stringValue == requestID else { continue }
                    if response["subtype"]?.stringValue == "error" {
                        let message = response["error"]?.nonEmptyString ?? "Claude Code initialize failed."
                        throw ProviderError.rpc(method: "initialize", code: 0, message: message)
                    }
                    return response["response"] ?? .null
                case let .exited(status, stderr):
                    throw ProviderError.processExited(.claude, status: status, stderr: stderr)
                }
            }
            throw ProviderError.notStarted
        }
    }
}
