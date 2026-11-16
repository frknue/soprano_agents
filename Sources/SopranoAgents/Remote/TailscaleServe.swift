import Foundation
import SopranoAgentsCore

/// Publishes the remote server on the tailnet with `tailscale serve` (TLS by Tailscale, reachable
/// only from the user's own tailnet devices) and finds its URL. Never replaces a serve config on
/// the HTTPS port that points somewhere else.
enum TailscaleServe {
    enum Status: Equatable, Sendable {
        /// Published: the web app's URL.
        case published(URL)
        case notInstalled
        /// Tailscale is installed but not connected (logged out, stopped).
        case notConnected(String)
        /// The HTTPS port already serves something else.
        case conflict(String)
        case failed(String)

        var url: URL? {
            if case let .published(url) = self { return url }
            return nil
        }
    }

    private static let appBinary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    static func executable() -> String? {
        ExecutableLocator.locate("tailscale") ?? (FileManager.default.isExecutableFile(atPath: appBinary) ? appBinary : nil)
    }

    /// Serves `http://127.0.0.1:<localPort>` at `https://<device>:<httpsPort>/` (in the background,
    /// kept across restarts by Tailscale).
    static func publish(httpsPort: Int, localPort: Int) async -> Status {
        guard let tailscale = executable() else { return .notInstalled }
        let target = "http://127.0.0.1:\(localPort)"
        let host: String
        switch await dnsName(tailscale) {
        case let .success(name): host = name
        case let .failure(message): return .notConnected(message)
        }
        let url = URL(string: httpsPort == 443 ? "https://\(host)/" : "https://\(host):\(httpsPort)/")!
        switch await currentProxy(tailscale, host: host, httpsPort: httpsPort) {
        case .some(target):
            return .published(url)
        case let .some(other):
            return .conflict("Tailscale already serves \(other) on HTTPS port \(httpsPort). Pick another port in Settings › Phone (remote.httpsPort) or remove it with `tailscale serve --https=\(httpsPort) off`.")
        case nil:
            break
        }
        let result = await run(tailscale, ["serve", "--bg", "--yes", "--https=\(httpsPort)", target])
        guard result.status == 0 else {
            return .failed(result.output.isEmpty ? "tailscale serve failed (exit \(result.status))." : result.output)
        }
        return .published(url)
    }

    /// Turns the HTTPS port's config off, only when it still points at this server.
    static func unpublish(httpsPort: Int, localPort: Int) async {
        guard let tailscale = executable(), case let .success(host) = await dnsName(tailscale),
              await currentProxy(tailscale, host: host, httpsPort: httpsPort) == "http://127.0.0.1:\(localPort)" else { return }
        _ = await run(tailscale, ["serve", "--https=\(httpsPort)", "off"])
    }

    enum NameResult {
        case success(String)
        case failure(String)
    }

    /// The device's MagicDNS name (`macbook.tail1234.ts.net`) while connected.
    static func dnsName(_ tailscale: String) async -> NameResult {
        let result = await run(tailscale, ["status", "--json"])
        guard result.status == 0, let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else {
            return .failure(result.output.isEmpty ? "Tailscale is not running." : result.output)
        }
        let state = object["BackendState"] as? String ?? ""
        guard state == "Running" else { return .failure("Tailscale is \(state.isEmpty ? "not connected" : state.lowercased()).") }
        guard let name = (object["Self"] as? [String: Any])?["DNSName"] as? String, !name.isEmpty else {
            return .failure("This Mac has no MagicDNS name; turn on MagicDNS for the tailnet.")
        }
        return .success(name.hasSuffix(".") ? String(name.dropLast()) : name)
    }

    /// What `/` on the HTTPS port proxies to now ("http://127.0.0.1:47261"), "<other config>" for
    /// a different handler, nil when the port is free.
    static func currentProxy(_ tailscale: String, host: String, httpsPort: Int) async -> String? {
        let result = await run(tailscale, ["serve", "status", "--json"])
        guard result.status == 0, let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return nil }
        return proxy(in: object, host: host, httpsPort: httpsPort)
    }

    /// Reads `serve status --json`: `Web["<host>:<port>"].Handlers["/"].Proxy`; a port with
    /// other handlers or a TCP forward reads as a description of that config.
    static func proxy(in status: [String: Any], host: String, httpsPort: Int) -> String? {
        let web = status["Web"] as? [String: Any] ?? [:]
        if let site = web["\(host):\(httpsPort)"] as? [String: Any] {
            let handlers = site["Handlers"] as? [String: Any] ?? [:]
            if handlers.count == 1, let root = handlers["/"] as? [String: Any], let proxy = root["Proxy"] as? String {
                return proxy
            }
            return "another web config (\(handlers.keys.sorted().joined(separator: ", ")))"
        }
        if let tcp = (status["TCP"] as? [String: Any])?["\(httpsPort)"] as? [String: Any], let forward = tcp["TCPForward"] as? String {
            return "a TCP forward to \(forward)"
        }
        return nil
    }

    struct RunResult: Sendable {
        var status: Int32
        var output: String
    }

    /// Runs the CLI off the main thread (20 s limit); `output` is stdout and stderr, trimmed.
    static func run(_ executable: String, _ arguments: [String]) async -> RunResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ExecutableLocator.childEnvironment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return RunResult(status: -1, output: error.localizedDescription)
            }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return RunResult(status: process.terminationStatus, output: output)
        }.value
    }
}
