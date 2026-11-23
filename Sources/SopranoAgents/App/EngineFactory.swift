import AppKit
import SopranoAgentsCore

/// Where the app keeps its data. Dev and installed builds use their bundle name, so they never
/// share threads; `SOPRANO_AGENTS_DATA_DIR` (absolute) overrides it.
enum AppPaths {
    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SOPRANO_AGENTS_DATA_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Soprano Agents"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(name, isDirectory: true)
    }
}

/// Executable overrides from settings.json, readable from the drivers' background tasks.
final class ExecutablePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var ompPath: String?
    private var codexPath: String?
    private var opencodePath: String?
    private var antigravityPath: String?

    func update(_ settings: EngineSettings) {
        lock.withLock {
            ompPath = settings.ompPath
            codexPath = settings.codexPath
            opencodePath = settings.opencodePath
            antigravityPath = settings.antigravityPath
        }
    }

    /// `providers.ompPath`, or nil to search PATH.
    var omp: String? {
        lock.withLock { ompPath }
    }

    /// `providers.codexPath`, or nil to search PATH.
    var codex: String? {
        lock.withLock { codexPath }
    }

    /// `providers.opencodePath`, or nil to search PATH.
    var opencode: String? {
        lock.withLock { opencodePath }
    }

    /// `providers.antigravityPath`, or nil to search PATH and omp's downloads.
    var antigravity: String? {
        lock.withLock { antigravityPath }
    }
}

/// The accounts each new provider process starts with, read from the vendored `AccountLaunchState`
/// that `AccountsController` publishes into: omp's `--config` overlay and Codex's `CODEX_HOME`.
enum AccountLaunchBridge {
    static func ompAdjustments(state: AccountLaunchState = .shared) -> ProviderLaunchAdjustments {
        let adjustments = state.adjustments(forProfile: "omp")
        return ProviderLaunchAdjustments(environment: adjustments.environment, arguments: adjustments.arguments)
    }

    static func codexAdjustments(state: AccountLaunchState = .shared) -> ProviderLaunchAdjustments {
        let adjustments = state.adjustments(forProfile: "codex")
        return ProviderLaunchAdjustments(environment: adjustments.environment, arguments: adjustments.arguments)
    }
}

/// Builds the engine the app runs with: JSON-file store, git CLI, the omp, Codex, Antigravity
/// and OpenCode drivers, omp's usage statistics and omp's typing aids.
@MainActor
enum EngineFactory {
    /// The executable overrides the drivers read on every spawn; the app delegate keeps them current.
    static let executablePaths = ExecutablePaths()

    static func live(settings: EngineSettings) -> AgentEngine {
        let dataDirectory = AppPaths.dataDirectory()
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        executablePaths.update(settings)
        let paths = executablePaths
        let environment = EngineEnvironment(
            drivers: [
                .omp: OmpDriver(
                    executablePath: { paths.omp },
                    launchAdjustments: { AccountLaunchBridge.ompAdjustments() }
                ),
                .codex: CodexDriver(
                    executablePath: { paths.codex },
                    launchAdjustments: { AccountLaunchBridge.codexAdjustments() }
                ),
                .antigravity: AntigravityDriver(
                    executablePath: { paths.antigravity },
                    profile: AntigravityProtocol.profileDirectory(dataDirectory: dataDirectory)
                ),
                .opencode: OpencodeDriver(executablePath: { paths.opencode }),
            ],
            git: LiveGitService(),
            store: JSONFileThreadStore(directory: dataDirectory),
            dataDirectory: dataDirectory,
            usage: OmpUsageStatistics(executablePath: { paths.omp }),
            textAssistants: [
                .omp: OmpTextAssistant(
                    executablePath: { paths.omp },
                    launchAdjustments: { AccountLaunchBridge.ompAdjustments() }
                ),
            ],
            ompAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".omp/agent/agents", isDirectory: true)
        )
        return AgentEngine(environment: environment, settings: settings)
    }
}
