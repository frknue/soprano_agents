import Foundation

/// The agent CLIs Soprano Agents drives. One thread talks to exactly one provider.
/// Declaration order is display order (model picker, settings): omp first.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// `omp --mode rpc-ui` (oh-my-pi's JSONL RPC with host-rendered tool UI: approvals, `ask`).
    case omp
    /// OpenAI's Codex CLI as an app-server (`codex app-server --stdio`, JSON-RPC 2.0 over stdio).
    case codex
    /// Anthropic's Claude Code CLI (`claude --output-format stream-json --input-format stream-json`).
    case claude
    /// Google's Antigravity CLI as an ACP agent (`agy acp`, JSON-RPC over stdio) with its own
    /// agent and tools, signed in with a Google AI plan.
    case antigravity
    /// OpenCode's v2 HTTP API on its background service (`opencode serve --service`), with the
    /// server-sent event stream.
    case opencode

    public var displayName: String {
        switch self {
        case .omp: "omp"
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        }
    }

    /// The CLI's executable name.
    public var executableName: String {
        switch self {
        case .omp: "omp"
        case .codex: "codex"
        case .claude: "claude"
        case .antigravity: "agy"
        case .opencode: "opencode"
        }
    }

    /// Default chat model before the live catalog is known:
    /// `ModelSelection.configuredDefaultModel`, whatever the CLI itself is configured to use.
    public var defaultModel: String { ModelSelection.configuredDefaultModel }

    /// Declarative feature matrix for this provider. Used by the engine and UI instead of
    /// hardcoding provider identity checks.
    public var capabilities: ProviderCapabilities {
        switch self {
        case .omp:
            ProviderCapabilities(
                supportsSteer: true,
                supportsRollback: true,
                supportsPlanMode: false,
                supportsNativeSubagents: true,
                supportsNativeSideQuestions: true,
                supportsMCPInjection: true,
                supportsSystemPromptAppend: true,
                supportsHostTools: true
            )
        case .codex:
            ProviderCapabilities(
                supportsSteer: true,
                supportsRollback: true,
                supportsPlanMode: true,
                supportsNativeSubagents: true,
                supportsNativeSideQuestions: false,
                supportsMCPInjection: true,
                supportsSystemPromptAppend: true,
                supportsHostTools: false
            )
        case .claude:
            ProviderCapabilities(
                supportsSteer: true,
                supportsRollback: true,
                supportsPlanMode: true,
                supportsNativeSubagents: true,
                supportsNativeSideQuestions: false,
                supportsMCPInjection: true,
                supportsSystemPromptAppend: true,
                supportsHostTools: false
            )
        case .antigravity:
            ProviderCapabilities(
                supportsSteer: false,
                supportsRollback: false,
                supportsPlanMode: false,
                supportsNativeSubagents: false,
                supportsNativeSideQuestions: false,
                supportsMCPInjection: true,
                supportsSystemPromptAppend: true,
                supportsHostTools: false
            )
        case .opencode:
            ProviderCapabilities(
                supportsSteer: true,
                supportsRollback: true,
                supportsPlanMode: false,
                supportsNativeSubagents: true,
                supportsNativeSideQuestions: true,
                supportsMCPInjection: true,
                supportsSystemPromptAppend: false,
                supportsHostTools: false
            )
        }
    }
}

/// Capabilities a provider session supports natively.
public struct ProviderCapabilities: Sendable, Hashable {
    public var supportsSteer: Bool
    public var supportsRollback: Bool
    public var supportsPlanMode: Bool
    public var supportsNativeSubagents: Bool
    public var supportsNativeSideQuestions: Bool
    public var supportsMCPInjection: Bool
    public var supportsSystemPromptAppend: Bool
    public var supportsHostTools: Bool

    public init(
        supportsSteer: Bool = false,
        supportsRollback: Bool = false,
        supportsPlanMode: Bool = false,
        supportsNativeSubagents: Bool = false,
        supportsNativeSideQuestions: Bool = false,
        supportsMCPInjection: Bool = false,
        supportsSystemPromptAppend: Bool = false,
        supportsHostTools: Bool = false
    ) {
        self.supportsSteer = supportsSteer
        self.supportsRollback = supportsRollback
        self.supportsPlanMode = supportsPlanMode
        self.supportsNativeSubagents = supportsNativeSubagents
        self.supportsNativeSideQuestions = supportsNativeSideQuestions
        self.supportsMCPInjection = supportsMCPInjection
        self.supportsSystemPromptAppend = supportsSystemPromptAppend
        self.supportsHostTools = supportsHostTools
    }
}

/// High-level collaboration/interaction mode for providers that support Plan mode (Codex, Claude).
public enum InteractionMode: String, Codable, Sendable, CaseIterable, Hashable {
    case standard = "default"
    case plan = "plan"

    public var title: String {
        switch self {
        case .standard: "Build"
        case .plan: "Plan"
        }
    }

    public var summary: String {
        switch self {
        case .standard: "Edit files and execute commands according to permissions."
        case .plan: "Design and plan changes before editing code."
        }
    }

    public var symbolName: String {
        switch self {
        case .standard: "hammer"
        case .plan: "list.bullet.clipboard"
        }
    }
}

/// OS-agnostic MCP server definition passed to provider sessions (stdio or HTTP/SSE).
public struct MCPServerSpec: Codable, Sendable, Hashable, Identifiable {
    public enum Transport: Codable, Sendable, Hashable {
        case stdio(command: String, args: [String] = [], env: [String: String] = [:])
        case http(url: String, headers: [String: String] = [:])
    }

    public var id: String { name }
    public var name: String
    public var transport: Transport

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }
}

/// How much the agent may do without asking. Four modes with fixed labels.
public enum RuntimeMode: String, Codable, Sendable, CaseIterable, Hashable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto
    case fullAccess = "full-access"

    public var title: String {
        switch self {
        case .approvalRequired: "Supervised"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }

    public var summary: String {
        switch self {
        case .approvalRequired: "Ask before running commands or changing files."
        case .autoAcceptEdits: "Edit files freely; ask before running commands."
        case .auto: "Let the agent decide when to ask."
        case .fullAccess: "Run commands and edit files without asking."
        }
    }

    /// SF Symbol shown in the permissions chip and menu.
    public var symbolName: String {
        switch self {
        case .approvalRequired: "lock"
        case .autoAcceptEdits: "pencil.line"
        case .auto: "sparkles"
        case .fullAccess: "shield.slash"
        }
    }
}

/// One selectable value of a model option (e.g. reasoning effort "high").
public struct ModelOptionChoice: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

/// A provider-supplied option for a model: a select (reasoning effort) or a boolean (fast mode).
public struct ModelOption: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case select
        case boolean
    }

    /// Stable id; also the key in `ModelSelection.options`. Known ids: `effort`, `fastMode`.
    public var id: String
    public var label: String
    public var kind: Kind
    public var choices: [ModelOptionChoice]
    /// Default choice id for selects, "true"/"false" for booleans.
    public var defaultValue: String

    public init(id: String, label: String, kind: Kind, choices: [ModelOptionChoice] = [], defaultValue: String) {
        self.id = id
        self.label = label
        self.kind = kind
        self.choices = choices
        self.defaultValue = defaultValue
    }
}

/// A model a provider offers.
public struct ProviderModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String { slug }
    /// Id sent to the provider (`anthropic/claude-opus-5-5`, or `default` for omp's configured model).
    public var slug: String
    /// Display name ("Claude Opus 5.5 · anthropic").
    public var name: String
    public var isDefault: Bool
    public var options: [ModelOption]

    public init(slug: String, name: String, isDefault: Bool = false, options: [ModelOption] = []) {
        self.slug = slug
        self.name = name
        self.isDefault = isDefault
        self.options = options
    }

    public func option(_ id: String) -> ModelOption? {
        options.first { $0.id == id }
    }
}

/// What the app knows about an installed provider CLI after probing it.
public struct ProviderStatus: Codable, Sendable, Hashable, Identifiable {
    public enum Health: String, Codable, Sendable, Hashable {
        case unknown
        case ready
        case notInstalled
        case unauthenticated
        case error
    }

    public var id: ProviderKind { kind }
    public var kind: ProviderKind
    public var health: Health
    /// CLI version ("18.14.0").
    public var version: String?
    public var models: [ProviderModel]
    /// Human-readable problem when `health` is not `ready`.
    public var message: String?

    public init(
        kind: ProviderKind,
        health: Health = .unknown,
        version: String? = nil,
        models: [ProviderModel] = [],
        message: String? = nil
    ) {
        self.kind = kind
        self.health = health
        self.version = version
        self.models = models
        self.message = message
    }

    public var defaultModel: ProviderModel? {
        models.first(where: \.isDefault) ?? models.first
    }
}

/// Provider + model + option values for a thread or a single turn.
public struct ModelSelection: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var model: String
    /// Option id → value (`effort` → `high`, `fastMode` → `true`). Missing = the model's default.
    public var options: [String: String]

    public init(provider: ProviderKind, model: String, options: [String: String] = [:]) {
        self.provider = provider
        self.model = model
        self.options = options
    }

    public static func `default`(for provider: ProviderKind) -> ModelSelection {
        ModelSelection(provider: provider, model: provider.defaultModel)
    }

    public var effort: String? {
        get { options[ModelOptionID.effort] }
        set { options[ModelOptionID.effort] = newValue }
    }

    public var fastMode: Bool {
        get { options[ModelOptionID.fastMode] == "true" }
        set { options[ModelOptionID.fastMode] = newValue ? "true" : nil }
    }
}

extension ModelSelection {
    /// Model id meaning "the CLI's own configured default" (omp: no `--model`, no `set_model`;
    /// OpenCode: the server's default model). Real models are `provider/id`
    /// (`anthropic/claude-opus-5-5`, `claude-agent/opus`).
    public static let configuredDefaultModel = "default"
}

public enum ModelOptionID {
    public static let effort = "effort"
    public static let fastMode = "fastMode"
}
