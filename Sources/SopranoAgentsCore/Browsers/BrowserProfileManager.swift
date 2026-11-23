import Foundation

/// Launches and probes external Chromium-family browsers (Chrome, Chrome Beta, Chromium, Brave,
/// Edge) with `--remote-debugging-port=<port>` and `--user-data-dir=<dir>`. Strictly external CDP:
/// never uses WebKit.
public enum BrowserProfileManager {
    public enum BrowserError: Error, LocalizedError, Sendable {
        case binaryNotFound
        case launchFailed(String)
        case invalidEndpoint(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                "No Chromium-family browser was found. Install Chrome, Chrome Beta, Chromium or Brave, or set binaryPath on the profile."
            case let .launchFailed(reason):
                "Could not launch browser profile: \(reason)"
            case let .invalidEndpoint(url):
                "Invalid local CDP endpoint: \(url)"
            }
        }
    }

    /// Standard Chromium-family browser binary candidates (macOS and Linux).
    public static let defaultBinaryCandidates: [String] = [
        "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/usr/bin/google-chrome-beta",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/brave-browser",
    ]

    public static func locateChromiumBinary(
        preferred: String? = nil,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = preferred.hasPrefix("~/") ? home + String(preferred.dropFirst()) : preferred
            if isExecutable(expanded) { return expanded }
        }
        return defaultBinaryCandidates.first(where: isExecutable)
    }

    /// Queries `http://127.0.0.1:<port>/json/version` to check if a profile's Chromium instance is
    /// currently running and accepting CDP connections.
    public static func probe(profile: BrowserProfile, timeout: TimeInterval = 1.0) async -> BrowserProfileStatus {
        guard let url = URL(string: "\(profile.cdpURL)/json/version") else {
            return BrowserProfileStatus(profileID: profile.id, port: profile.port, isRunning: false)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return BrowserProfileStatus(profileID: profile.id, port: profile.port, isRunning: false)
            }
            return BrowserProfileStatus(
                profileID: profile.id,
                port: profile.port,
                isRunning: true,
                browserVersion: object["Browser"] as? String,
                webSocketDebuggerURL: object["webSocketDebuggerUrl"] as? String
            )
        } catch {
            return BrowserProfileStatus(profileID: profile.id, port: profile.port, isRunning: false)
        }
    }

    public static func probeAll(settings: BrowserSettings) async -> [BrowserProfileStatus] {
        await withTaskGroup(of: (Int, BrowserProfileStatus).self) { group in
            for (index, profile) in settings.profiles.enumerated() {
                group.addTask { (index, await probe(profile: profile)) }
            }
            var results: [(Int, BrowserProfileStatus)] = []
            for await entry in group { results.append(entry) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Launches the profile's Chromium binary with `--remote-debugging-port` and `--user-data-dir`
    /// if not already running, optionally opening `initialURL`.
    @discardableResult
    public static func launch(
        profile: BrowserProfile,
        initialURL: String? = nil,
        home: String = NSHomeDirectory()
    ) async throws -> BrowserProfileStatus {
        let current = await probe(profile: profile, timeout: 0.6)
        if current.isRunning {
            if let initialURL, !initialURL.isEmpty {
                await openTab(url: initialURL, cdpURL: profile.cdpURL)
            }
            return current
        }

        guard let binary = locateChromiumBinary(preferred: profile.binaryPath, home: home) else {
            throw BrowserError.binaryNotFound
        }

        let userDataDir = profile.resolvedUserDataDirectory(home: home)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: userDataDir, isDirectory: true),
            withIntermediateDirectories: true
        )

        var args = [
            "--remote-debugging-port=\(profile.port)",
            "--user-data-dir=\(userDataDir)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        args.append(contentsOf: profile.extraArgs)
        if let initialURL, !initialURL.isEmpty {
            args.append(initialURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw BrowserError.launchFailed(error.localizedDescription)
        }

        // Wait up to 4 seconds for Chromium's CDP port to come online.
        for _ in 0..<20 {
            let status = await probe(profile: profile, timeout: 0.4)
            if status.isRunning { return status }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await probe(profile: profile, timeout: 0.6)
    }

    /// Opens a visible tab in an already-running Chromium profile via CDP's `/json/new` HTTP endpoint.
    @discardableResult
    public static func openTab(url: String, cdpURL: String) async -> Bool {
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let endpoint = URL(string: "\(cdpURL)/json/new?\(encoded)")
        else { return false }
        var request = URLRequest(url: endpoint, timeoutInterval: 2.0)
        request.httpMethod = "PUT"
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            return true
        }
        // Older Chromium builds accept GET on /json/new.
        request.httpMethod = "GET"
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            return true
        }
        return false
    }
}
