import Foundation

/// Resolves which Chromium CDP browser profile a thread or MCP call should connect to based on:
/// 1. Explicit requested profile id
/// 2. Ordered `BrowserMatchRule` entries (path prefixes, project names, git remote substrings)
/// 3. Optional external `resolverCommand` printing a loopback CDP URL (`http://127.0.0.1:<port>`)
/// 4. `defaultProfile` or the first configured profile
public enum BrowserProfileResolver {
    public typealias CommandRunner = @Sendable (_ argv: [String], _ cwd: String?) -> String?

    public static func resolve(
        cwd: String?,
        requestedProfile: String? = nil,
        settings: BrowserSettings,
        home: String = NSHomeDirectory(),
        runResolver: CommandRunner? = nil
    ) -> ResolvedBrowserProfile? {
        if let requested = requestedProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            if let profile = settings.profiles.first(where: { $0.id.caseInsensitiveCompare(requested) == .orderedSame }) {
                return ResolvedBrowserProfile(profile: profile, cdpURL: profile.cdpURL, source: .explicit)
            }
            if let url = runExternalResolver(
                command: settings.resolverCommand,
                cwd: cwd,
                profile: requested,
                home: home,
                runner: runResolver ?? defaultCommandRunner
            ) {
                let matched = profileMatching(url: url, in: settings.profiles)
                return ResolvedBrowserProfile(profile: matched, cdpURL: url, source: .resolver)
            }
            return nil
        }

        if let cwd, !cwd.isEmpty {
            let standardizedCwd = URL(fileURLWithPath: expandTilde(cwd, home: home)).standardizedFileURL.path
            let projectName = URL(fileURLWithPath: standardizedCwd).lastPathComponent.lowercased()
            let remotes = gitRemoteURLs(startingAt: standardizedCwd)

            for rule in settings.rules {
                guard let profile = settings.profiles.first(where: { $0.id == rule.profileID }) else { continue }
                if matches(rule: rule, cwd: standardizedCwd, projectName: projectName, remotes: remotes, home: home) {
                    return ResolvedBrowserProfile(profile: profile, cdpURL: profile.cdpURL, source: .rule)
                }
            }
        }

        if let url = runExternalResolver(
            command: settings.resolverCommand,
            cwd: cwd,
            profile: nil,
            home: home,
            runner: runResolver ?? defaultCommandRunner
        ) {
            let matched = profileMatching(url: url, in: settings.profiles)
            return ResolvedBrowserProfile(profile: matched, cdpURL: url, source: .resolver)
        }

        if let defaultID = settings.defaultProfile,
           let profile = settings.profiles.first(where: { $0.id == defaultID }) {
            return ResolvedBrowserProfile(profile: profile, cdpURL: profile.cdpURL, source: .fallback)
        }

        if let first = settings.profiles.first {
            return ResolvedBrowserProfile(profile: first, cdpURL: first.cdpURL, source: .fallback)
        }

        return nil
    }

    /// Generates an omp `--config` YAML overlay pointing omp's built-in browser tool at `cdpURL`.
    public static func ompBrowserOverlay(cdpURL: String) -> String {
        let escaped = cdpURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        browser:
          cdpUrl: "\(escaped)"
        """
    }

    /// Validates that a URL points strictly to a loopback HTTP/WS CDP endpoint (`127.0.0.1`,
    /// `localhost`, or `[::1]`) with a valid port.
    public static func validatedLocalCDPEndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              let port = components.port,
              (1...65535).contains(port)
        else { return nil }
        let normalizedHost = host == "::1" ? "[::1]" : host
        return "http://\(normalizedHost):\(port)"
    }

    /// Reads remote URLs directly from `.git/config` (supporting worktree `.git` pointer files)
    /// without spawning a `git` subprocess.
    public static func gitRemoteURLs(startingAt path: String) -> [String] {
        var current = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<16 {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let configURL: URL
                if isDir.boolValue {
                    configURL = dotGit.appendingPathComponent("config")
                } else if let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                          let gitdir = parseGitDirPointer(pointer, relativeTo: current) {
                    // For worktrees, commondir points to the main repository's .git/config.
                    let commonDirFile = gitdir.appendingPathComponent("commondir")
                    if let rel = try? String(contentsOf: commonDirFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       !rel.isEmpty {
                        configURL = URL(fileURLWithPath: rel, relativeTo: gitdir).standardizedFileURL.appendingPathComponent("config")
                    } else {
                        configURL = gitdir.appendingPathComponent("config")
                    }
                } else {
                    return []
                }
                guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
                return parseRemoteURLs(fromGitConfig: content)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return []
    }

    static func parseRemoteURLs(fromGitConfig content: String) -> [String] {
        var inRemoteSection = false
        var urls: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inRemoteSection = line.lowercased().hasPrefix("[remote ")
                continue
            }
            guard inRemoteSection else { continue }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "url" {
                    let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { urls.append(value) }
                }
            }
        }
        return urls
    }

    // MARK: Private

    private static func matches(
        rule: BrowserMatchRule,
        cwd: String,
        projectName: String,
        remotes: [String],
        home: String
    ) -> Bool {
        for rawPrefix in rule.pathPrefixes {
            let prefix = URL(fileURLWithPath: expandTilde(rawPrefix, home: home)).standardizedFileURL.path
            if cwd == prefix || cwd.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") {
                return true
            }
        }
        for name in rule.projectNames {
            if !name.isEmpty, projectName == name.lowercased() {
                return true
            }
        }
        for needle in rule.gitRemoteSubstrings {
            let lowered = needle.lowercased()
            if !lowered.isEmpty, remotes.contains(where: { $0.lowercased().contains(lowered) }) {
                return true
            }
        }
        return false
    }

    private static func profileMatching(url: String, in profiles: [BrowserProfile]) -> BrowserProfile? {
        guard let port = URLComponents(string: url)?.port else { return nil }
        return profiles.first { $0.port == port }
    }

    private static func parseGitDirPointer(_ content: String, relativeTo folder: URL) -> URL? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("gitdir:") {
                let raw = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("/") { return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL }
                return URL(fileURLWithPath: raw, relativeTo: folder).standardizedFileURL
            }
        }
        return nil
    }

    private static func runExternalResolver(
        command: [String]?,
        cwd: String?,
        profile: String?,
        home: String,
        runner: CommandRunner
    ) -> String? {
        guard let command, !command.isEmpty else { return nil }
        let expanded = command.enumerated().map { index, token -> String in
            var value = token
            if let cwd { value = value.replacingOccurrences(of: "{cwd}", with: cwd) }
            if let profile { value = value.replacingOccurrences(of: "{profile}", with: profile) }
            if index == 0 { return expandTilde(value, home: home) }
            return value
        }
        guard let output = runner(expanded, cwd) else { return nil }
        return validatedLocalCDPEndpoint(output)
    }

    private static let defaultCommandRunner: CommandRunner = { argv, cwd in
        guard let executable = argv.first, FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }
}
