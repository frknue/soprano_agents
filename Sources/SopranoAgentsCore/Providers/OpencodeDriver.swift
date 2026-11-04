import Foundation

/// OpenCode driver: sessions on OpenCode's background service (`OpencodeSession`), catalog
/// probing, text generation and command lists over its v2 HTTP API. One `OpencodeServer`
/// (connection, pairing) is shared by everything the driver makes.
public struct OpencodeDriver: ProviderDriver {
    public let kind = ProviderKind.opencode
    static let probeTimeout: TimeInterval = 45
    static let generationTimeout: TimeInterval = 180

    private let server: OpencodeServer
    /// Side questions of this app run, shared by every session the driver makes.
    private let sideQuestions = OpencodeSideQuestionStore()

    /// `executablePath` returns the settings override (`providers.opencodePath`), read on every
    /// connect; nil = search PATH.
    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        server = OpencodeServer(executablePath: executablePath)
    }

    public func makeSession() -> any ProviderSession {
        OpencodeSession(server: server, sideQuestions: sideQuestions)
    }

    /// `opencode --version` ("opencode v2.2.5"), then the server's catalog (`GET /api/model`,
    /// `GET /api/model/default`; connecting starts the service when it is not running). 45 s
    /// budget. No models → unauthenticated.
    public func probe() async -> ProviderStatus {
        let fallback = ProviderCatalog.fallback(.opencode)
        let executable: String
        do {
            executable = try server.executable()
        } catch {
            return ProviderStatus(kind: .opencode, health: .notInstalled, models: fallback, message: error.localizedDescription)
        }
        let version: String?
        do {
            let output = try await LineProcess.run(
                LineProcess.Configuration(
                    executable: executable,
                    arguments: ["--version"],
                    environment: ExecutableLocator.childEnvironment(),
                    directory: NSHomeDirectory()
                ),
                timeout: Self.probeTimeout,
                label: "opencode status check"
            )
            guard output.status == 0 else {
                return ProviderStatus(kind: .opencode, health: .error, models: fallback, message: ProviderError.processExited(.opencode, status: output.status, stderr: output.stderr).localizedDescription)
            }
            version = OpencodeProtocol.version(fromVersionOutput: output.stdout)
        } catch {
            return ProviderStatus(kind: .opencode, health: .error, models: fallback, message: error.localizedDescription)
        }
        do {
            let (list, configured) = try await withProviderTimeout(Self.probeTimeout, label: "OpenCode status check") { [server] in
                let home = NSHomeDirectory()
                let list = try await server.list("/api/model", directory: home, retryWhileEmpty: true)
                let configured = try? await server.request("GET", "/api/model/default", query: ["location[directory]": home])
                return (list, configured?["data"])
            }
            let models = OpencodeProtocol.models(list: list, defaultModel: configured)
            guard models.count > 1 else {
                return ProviderStatus(kind: .opencode, health: .unauthenticated, version: version, models: models, message: "OpenCode has no usable models. Run `opencode auth` to connect a provider.")
            }
            return ProviderStatus(kind: .opencode, health: .ready, version: version, models: models)
        } catch {
            return ProviderStatus(kind: .opencode, health: .error, version: version, models: fallback, message: error.localizedDescription)
        }
    }

    /// `GET /api/command` and `GET /api/skill` in `directory`, 20 s budget.
    public func commands(directory: String) async -> [ProviderCommand]? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        return try? await withProviderTimeout(20, label: "OpenCode command list") { [server] in
            let commands = try await server.list("/api/command", directory: directory, retryWhileEmpty: true)
            let skills = try? await server.list("/api/skill", directory: directory)
            return OpencodeProtocol.commands(commands, skills: skills)
        }
    }

    /// `POST /api/experimental/generate/text {prompt, model?}` (no session, no tools) with the
    /// prompt plus the schema and a JSON-only instruction, 180 s timeout. "default" leaves the
    /// model to OpenCode. Returns the first JSON object of the answer.
    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        var body: [String: JSONValue] = ["prompt": .string(ProviderPrompt.generationPrompt(prompt, schema: schema))]
        if let spec = OpencodeProtocol.modelSpec(model) {
            body["model"] = ["id": .string(spec.id), "providerID": .string(spec.provider)]
        }
        let answer = try await server.request("POST", "/api/experimental/generate/text", body: .object(body), timeout: Self.generationTimeout)
        guard let text = answer["data"]?["text"]?.stringValue else {
            throw ProviderError.invalidOutput("OpenCode returned no text.")
        }
        return try ProviderPrompt.firstJSONObject(in: text)
    }
}
