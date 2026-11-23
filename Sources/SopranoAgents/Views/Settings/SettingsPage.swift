import AppKit
import SopranoAgentsCore

/// The pages of the settings screen, in navigation order.
enum SettingsPage: String, CaseIterable, Sendable {
    case general
    case providers
    case accounts
    case resources
    case textGeneration = "text-generation"
    case worktrees
    case notifications
    case phone
    case keybindings
    case archive
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .accounts: "Accounts"
        case .resources: "Resources & MCP"
        case .textGeneration: "Text generation"
        case .worktrees: "Worktrees"
        case .notifications: "Notifications"
        case .phone: "Phone"
        case .keybindings: "Keybindings"
        case .archive: "Archive"
        case .about: "About"
        }
    }

    /// SF Symbol for the navigation and the command palette.
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .providers: "cpu"
        case .accounts: "person.2"
        case .resources: "puzzlepiece.extension"
        case .textGeneration: "text.bubble"
        case .worktrees: Icon.gitBranch
        case .notifications: "bell"
        case .phone: "iphone"
        case .keybindings: "keyboard"
        case .archive: "archivebox"
        case .about: "info.circle"
        }
    }

    /// Row titles on the page and extra search terms; the command palette's Settings group
    /// matches them and opens the page.
    var searchRows: [(title: String, terms: String)] {
        switch self {
        case .general:
            [("Theme", "color scheme appearance dark light soprano"), ("Chat width", "wide full width column layout messages composer"),
             ("Follow-up behavior", "queue steer running turn send"), ("Project folders", "projects directories open project git repositories")]
        case .providers:
            ProviderKind.allCases.map { ($0.displayName, "provider agent cli \($0.executableName) version status path executable") }
                + [("Default agent", "provider new thread omp opencode"), ("Default model", "new thread reasoning"),
                   ("Permissions", "runtime mode approval full access supervised")]
        case .accounts:
            [("Claude accounts", "account usage limits login sign in omp claude anthropic prefer"),
             ("Codex accounts", "account usage limits login sign in omp codex openai chatgpt prefer")]
        case .resources:
            [("Shared resource folders", "skills commands rules agents.md extra directories omp dotfiles"),
             ("MCP servers", "mcp tools browser asana devtools import mcp.json")]
        case .textGeneration:
            [("Text generation agent", "provider omp opencode"), ("Text generation model", "thread titles commit messages branch names"),
             ("Generate thread titles", "title")]
        case .worktrees:
            [("Worktree location", "folder directory path"), ("Branch prefix", "worktree branch naming")]
        case .notifications:
            [("Thread notifications", "notification alert completion input approval desktop dock badge"), ("Notification sound", "sound")]
        case .phone:
            [("Phone access", "remote mobile iphone web app pwa tailscale serve tailnet"), ("Pair a phone", "pairing link qr code device"),
             ("Paired devices", "revoke forget"), ("Push notifications", "push phone alerts"),
             ("Open at login", "launch login item start"), ("Keep awake", "sleep power"), ("Ports", "port https")]
        case .keybindings:
            [("Keyboard shortcuts", "keybindings shortcuts chords prefix record")]
        case .archive:
            [("Archived threads", "restore unarchive delete history")]
        case .about:
            [("Version", "about release"), ("Settings file", "settings.json config")]
        }
    }
}
