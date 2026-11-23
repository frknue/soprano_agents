import Foundation

/// Antigravity driver: sessions on `agy acp` (`AntigravitySession`), status and catalog from a
/// throwaway ACP session, and text generation the same way. Everything runs in the app's own
/// Antigravity profile (`AntigravityProtocol.profileDirectory`).
public struct AntigravityDriver: ProviderDriver {
    public let kind = ProviderKind.antigravity
    static let probeTimeout: TimeInterval = 45
    static let generationTimeout: TimeInterval = 180

    private let executablePath: @Sendable () -> String?
    private let profile: String

    /// `executablePath` returns the settings override (`providers.antigravityPath`), read on every
    /// spawn; nil = PATH, then omp's downloaded copy.
    public init(executablePath: @escaping @Sendable () -> String? = { nil }, profile: String) {
        self.executablePath = executablePath
        self.profile = profile
    }

    public func makeSession() -> any ProviderSession {
        AntigravitySession(executablePath: executablePath, profile: profile)
    }

    /// `agy --version`; without the profile's Google sign-in → unauthenticated; else the catalog
    /// of a throwaway `session/new` in an empty folder (the version gets the plan, "1.5.14 · Google
    /// AI Pro"). 45 s budget.
    public func probe() async -> ProviderStatus {
        let fallback = ProviderCatalog.fallback(.antigravity)
        let explicit = executablePath()
        guard let executable = AntigravityProtocol.locateExecutable(explicitPath: explicit) else {
            return ProviderStatus(kind: .antigravity, health: .notInstalled, models: fallback, message: ProviderError.notInstalled(.antigravity, path: explicit).localizedDescription)
        }
        let version: String?
        do {
            let output = try await LineProcess.run(
                LineProcess.Configuration(executable: executable, arguments: ["--version"], environment: ExecutableLocator.childEnvironment(), directory: NSHomeDirectory()),
                timeout: Self.probeTimeout,
                label: "Antigravity status check"
            )
            guard output.status == 0 else {
                return ProviderStatus(kind: .antigravity, health: .error, models: fallback, message: ProviderError.processExited(.antigravity, status: output.status, stderr: output.stderr).localizedDescription)
            }
            version = AntigravityProtocol.version(fromVersionOutput: output.stdout)
        } catch {
            return ProviderStatus(kind: .antigravity, health: .error, models: fallback, message: error.localizedDescription)
        }
        guard AntigravityProtocol.isSignedIn(profile: profile) else {
            return ProviderStatus(kind: .antigravity, health: .unauthenticated, version: version, models: fallback, message: "Sign in with the Google account of your Google AI plan.")
        }
        do {
            let session = try await withOneShotSession(executable: executable, timeout: Self.probeTimeout, label: "Antigravity status check") { _, session in session }
            let plan = AntigravityProtocol.tier(session: session)
            let shown = [version, plan].compactMap { $0 }.joined(separator: " · ")
            return ProviderStatus(kind: .antigravity, health: .ready, version: shown.isEmpty ? nil : shown, models: AntigravityProtocol.models(session: session))
        } catch {
            return ProviderStatus(kind: .antigravity, health: .error, version: version, models: fallback, message: error.localizedDescription)
        }
    }

    /// A throwaway session in an empty folder: the model (unless "default") and the prompt plus
    /// the schema; permission requests are declined. Returns the first JSON object of the answer.
    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        let explicit = executablePath()
        guard let executable = AntigravityProtocol.locateExecutable(explicitPath: explicit) else {
            throw ProviderError.notInstalled(.antigravity, path: explicit)
        }
        let text = try await withOneShotSession(executable: executable, timeout: Self.generationTimeout, label: "Antigravity text generation") { client, session in
            let id = session["sessionId"]?.stringValue ?? ""
            if model != ModelSelection.configuredDefaultModel {
                _ = try await client.request("session/set_config_option", ["sessionId": .string(id), "configId": "model", "value": .string(model)])
            }
            // The answer is complete once the prompt's response comes through `incoming`, behind
            // its last chunk.
            let reader = Task { () throws -> String in
                var answer = ""
                for await message in client.incoming {
                    switch message {
                    case .notification("session/update", let params):
                        let update = params["update"] ?? .null
                        if update["sessionUpdate"]?.stringValue == "agent_message_chunk", let chunk = update["content"]?["text"]?.stringValue {
                            answer += chunk
                        }
                    case let .request(requestID, _, params):
                        let options = params["options"]?.arrayValue ?? []
                        try? await client.respond(to: requestID, result: AntigravityProtocol.permissionOutcome(.decline, options: options))
                    case let .response("session/prompt", _, error):
                        if let error { throw ProviderError.message(error) }
                        return answer
                    case let .closed(status, stderr):
                        throw ProviderError.processExited(.antigravity, status: status, stderr: stderr)
                    default:
                        break
                    }
                }
                throw ProviderError.notStarted
            }
            defer { reader.cancel() }
            let text = ProviderPrompt.generationPrompt(prompt, schema: schema)
            _ = try await client.request("session/prompt", ["sessionId": .string(id), "prompt": [["type": "text", "text": .string(text)]]], ordered: true)
            return try await reader.value
        }
        return try ProviderPrompt.firstJSONObject(in: text)
    }

    /// Runs `body` against a fresh `agy acp` in a temporary folder after `initialize` and
    /// `session/new`, then stops the process and removes the folder.
    private func withOneShotSession<T: Sendable>(
        executable: String,
        timeout: TimeInterval,
        label: String,
        _ body: @escaping @Sendable (AcpClient, JSONValue) async throws -> T
    ) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: AntigravityProtocol.arguments(profile: profile),
            environment: AntigravityProtocol.environment(profile: profile),
            directory: folder.path
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        let client = AcpClient(transport: process)
        defer { process.terminate() }
        return try await withProviderTimeout(timeout, label: label) {
            _ = try await client.request("initialize", AntigravityProtocol.initializeParams)
            let session = try await client.request("session/new", ["cwd": .string(folder.path), "mcpServers": []])
            return try await body(client, session)
        }
    }
}
