import AppKit
import Testing
@testable import SopranoAgents

struct AntigravitySignInCommandTests {
    @Test func signInUsesTheAgyOmpDownloadedWhenNoneIsOnPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("google sign-in \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".omp/antigravity-cli/bin/1.5.14", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agy = bin.appendingPathComponent("agy")
        FileManager.default.createFile(atPath: agy.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)

        let command = SettingsController.antigravitySignInCommand(agyPath: nil, profile: "/data/antigravity", environment: ["PATH": ""], home: home.path)

        #expect(command?.contains("'\(agy.path)' acp --gemini-dir /data/antigravity --app-data-dir antigravity-acp --login") == true)
    }

    @Test func signInIsUnavailableWhenTheConfiguredAgyIsMissing() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("google-sign-in-\(UUID().uuidString)").path

        #expect(SettingsController.antigravitySignInCommand(agyPath: "\(home)/agy", profile: "/data/antigravity", environment: ["PATH": ""], home: home) == nil)
    }
}
