import Foundation
import SopranoAgentsCore

/// Built-in stdio MCP subcommands (`SopranoAgents mcp browser ...`), invoked by provider sessions
/// (Codex, Claude Code, Antigravity, OpenCode) without launching AppKit or WebKit.
enum MCPCommand {
    static func run(arguments: [String]) -> Never {
        guard let subcommand = arguments.first else {
            fputs("Usage: SopranoAgents mcp <browser|team>\n", stderr)
            exit(2)
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "browser":
            runBrowser(arguments: rest)
        case "team":
            runTeam(arguments: rest)
        default:
            fputs("Unknown mcp subcommand: \(subcommand)\n", stderr)
            exit(2)
        }
    }

    private static func runTeam(arguments: [String]) -> Never {
        var endpoint: String?
        var token: String?
        var threadID: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--endpoint":
                index += 1
                if index < arguments.count { endpoint = arguments[index] }
            case "--token":
                index += 1
                if index < arguments.count { token = arguments[index] }
            case "--thread":
                index += 1
                if index < arguments.count { threadID = arguments[index] }
            default:
                break
            }
            index += 1
        }
        guard let endpoint, let token, let threadID else {
            fputs("Usage: SopranoAgents mcp team --endpoint <url> --token <token> --thread <id>\n", stderr)
            exit(2)
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await TeamMCPStdioRunner.run(endpoint: endpoint, token: token, threadID: threadID)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func runBrowser(arguments: [String]) -> Never {
        var cdpURL: String?
        var settingsPath: String?
        var cwd: String?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--cdp-url":
                index += 1
                if index < arguments.count { cdpURL = arguments[index] }
            case "--settings-json":
                index += 1
                if index < arguments.count { settingsPath = arguments[index] }
            case "--cwd":
                index += 1
                if index < arguments.count { cwd = arguments[index] }
            default:
                break
            }
            index += 1
        }

        var settings = BrowserSettings()
        if let settingsPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let decoded = try? JSONDecoder().decode(BrowserSettings.self, from: data) {
            settings = decoded
        }

        let ledgerDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/soprano-agents/browser-ledger", isDirectory: true)

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await BrowserMCPStdioRunner.run(
                defaultEndpoint: cdpURL,
                settings: settings,
                cwd: cwd,
                ledgerDirectory: ledgerDirectory
            )
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
