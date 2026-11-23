import AppKit
import Testing
@testable import SopranoAgentsCore

struct AntigravityProtocolTests {
    /// The `session/new` answer of the recorded tool turn.
    private static func newSession() throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/antigravity-tool-turn.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("<< ") }
        let answer = try lines.map { try JSONValue.parse(String($0.dropFirst(3))) }.first { $0["result"]?["sessionId"] != nil }
        return try #require(answer?["result"])
    }

    @Test func theCatalogOffersAgysDefault_EveryModel_AndEachModelsOwnEfforts() throws {
        let models = AntigravityProtocol.models(session: try Self.newSession())
        #expect(models.first?.slug == ModelSelection.configuredDefaultModel)
        #expect(models.first?.name == "Gemini 4 Neon · default")
        #expect(models.dropFirst().map(\.slug) == [
            "gemini-4-neon", "gemini-4-argon", "gemini-4-hydrogen", "gemini-pro-orchestrator-neon",
            "gemini-pro-orchestrator-g1-pro", "gemini-3.8-flash", "claude-opus-5-5", "claude-sonnet-5-5", "gpt-oss-120b-medium",
        ])
        let efforts = { (slug: String) in models.first { $0.slug == slug }?.options.first?.choices.map(\.id) ?? [] }
        #expect(efforts("gemini-4-neon") == ["low", "medium", "high", "xhigh"])
        #expect(efforts("gemini-3.8-flash") == ["low", "medium", "high"])
        #expect(efforts("gpt-oss-120b-medium") == [])
        #expect(models.first { $0.slug == "gemini-3.8-flash" }?.options.first?.defaultValue == "high")
    }

    @Test func thePlanComesFromTheSessionsTier() throws {
        #expect(AntigravityProtocol.tier(session: try Self.newSession()) == "Google AI Pro")
        #expect(AntigravityProtocol.tier(session: ["sessionId": "s"]) == nil)
    }

    @Test func decisionsPickTheOfferedOptionOfTheirKind() {
        let options: [JSONValue] = [
            ["optionId": "allow", "kind": "allow_once"],
            ["optionId": "deny", "kind": "reject_once"],
        ]
        func picked(_ decision: ApprovalDecision) -> JSONValue? { AntigravityProtocol.permissionOutcome(decision, options: options)["outcome"] }
        #expect(picked(.accept) == ["outcome": "selected", "optionId": "allow"])
        #expect(picked(.acceptForSession) == ["outcome": "selected", "optionId": "allow"])
        #expect(picked(.decline) == ["outcome": "selected", "optionId": "deny"])
        #expect(picked(.cancel) == ["outcome": "cancelled"])
    }

    @Test func theChildRunsInTheProfileWithoutOtherGoogleCredentials() {
        let environment = AntigravityProtocol.environment(profile: "/data/antigravity", base: ["PATH": "/usr/bin", "GEMINI_API_KEY": "key", "HOME": "/Users/me"])
        #expect(environment["GEMINI_API_KEY"] == nil)
        #expect(environment["GEMINI_HOME"] == "/data/antigravity")
        #expect(environment["SSH_CONNECTION"] != nil)
        #expect(environment["AGY_ACP_FORCE_FILE_STORAGE"] == "1")
        #expect(AntigravityProtocol.arguments(profile: "/data/antigravity") == ["acp", "--gemini-dir", "/data/antigravity", "--app-data-dir", "antigravity-acp"])
    }

    @Test func theSignInCommandQuotesAProfileWithSpaces() {
        let profile = "/Users/me/Library/Application Support/Soprano Agents/antigravity"
        let command = AntigravityProtocol.loginCommand(executable: "/opt/agy", profile: profile, base: [:])
        #expect(command == "mkdir -p '\(profile)' && GEMINI_HOME='\(profile)' SSH_CONNECTION='127.0.0.1 0 127.0.0.1 0' AGY_ACP_FORCE_FILE_STORAGE=1 AGY_CLI_DISABLE_AUTO_UPDATE=1 /opt/agy acp --gemini-dir '\(profile)' --app-data-dir antigravity-acp --login")
    }

    @Test func withoutAgyOnPathTheNewestOmpDownloadIsUsed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["1.5.9", "1.5.14"] {
            let folder = home.appendingPathComponent(".omp/antigravity-cli/bin/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let agy = folder.appendingPathComponent("agy")
            FileManager.default.createFile(atPath: agy.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        }
        let found = AntigravityProtocol.locateExecutable(explicitPath: nil, environment: ["PATH": ""], home: home.path)
        #expect(found == home.appendingPathComponent(".omp/antigravity-cli/bin/1.5.14/agy").path)
        #expect(AntigravityProtocol.locateExecutable(explicitPath: "\(home.path)/missing", environment: ["PATH": ""], home: home.path) == nil)
    }

    @Test func aStoppedTurnIsInterruptedAndARefusalFails() {
        #expect(AntigravityProtocol.outcome(stopReason: "cancelled").0 == .interrupted)
        #expect(AntigravityProtocol.outcome(stopReason: "refusal").0 == .failed)
        #expect(AntigravityProtocol.outcome(stopReason: "end_turn").0 == .completed)
    }

    @Test func editsBecomeUnifiedHunksWithContext() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 5\n", with: "line five\n")
        #expect(LineDiff.hunks(old: old, new: new) == "@@ -2,7 +2,7 @@\n line 2\n line 3\n line 4\n-line 5\n+line five\n line 6\n line 7\n line 8")
        #expect(LineDiff.hunks(old: "", new: "a\nb\n") == "@@ -0,0 +1,2 @@\n+a\n+b")
        #expect(LineDiff.hunks(old: "same\n", new: "same\n") == nil)
    }
}
