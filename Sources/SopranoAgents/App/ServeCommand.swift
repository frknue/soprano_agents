import AppKit
import SopranoAgentsCore

/// `SopranoAgents serve [--fixture demo] [--port 47299] [--theme <id>] [--appearance light|dark]`:
/// the phone web app and its API over a `DemoFixtures` engine on `http://127.0.0.1:<port>/`, for
/// working on the web app without the real app, providers or Tailscale. Remote state lives in a
/// fresh temporary folder; it prints the pairing code and a ready device token, then serves until
/// killed. Sending messages fails (fixture engines have no agents).
@MainActor
enum ServeCommand {
    struct Options: Equatable {
        var fixture = "demo"
        var port = 47299
        var theme: String?
        var dark = false
    }

    static let usage = "usage: SopranoAgents serve [--fixture \(DemoFixtures.scenarios.joined(separator: "|"))] [--port 47299] [--theme <id>] [--appearance light|dark]"

    nonisolated static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw SnapshotCommand.CaptureError(description: "\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--fixture": options.fixture = try value()
            case "--port":
                guard let port = Int(try value()), (1...65535).contains(port) else { throw SnapshotCommand.CaptureError(description: "--port must be 1–65535") }
                options.port = port
            case "--theme": options.theme = try value()
            case "--appearance":
                let appearance = try value()
                guard ["light", "dark"].contains(appearance) else { throw SnapshotCommand.CaptureError(description: "--appearance must be light or dark") }
                options.dark = appearance == "dark"
            default: throw SnapshotCommand.CaptureError(description: "unknown option \(arguments[index])")
            }
            index += 1
        }
        return options
    }

    static func run(arguments: [String]) -> Never {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("serve: \(error)\n\(usage)\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try start(options)
            } catch {
                FileHandle.standardError.write(Data("serve: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    /// Kept alive for the life of the process.
    @MainActor private static var running: (HTTPServer, RemoteAPI)?

    @MainActor
    static func start(_ options: Options) throws {
        ThemeCenter.shared.forcedAppearance = options.dark ? .dark : .light
        PaletteCenter.shared.apply(setting: options.theme ?? AppTheme.folioId)
        let built = try DemoFixtures.build(options.fixture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-serve-\(UUID().uuidString)", isDirectory: true)
        let store = RemoteStore(url: directory.appendingPathComponent("remote.json"))
        let code = store.pairingCode
        let token = store.pair(code: code, name: "serve harness") ?? ""
        let api = RemoteAPI(engine: built.engine, store: store, terminals: RemoteTerminals(engine: built.engine))
        let server = HTTPServer(port: UInt16(options.port)) { request in await api.handle(request) }
        try server.start { result in
            switch result {
            case .success:
                print("Serving fixture \"\(options.fixture)\" at http://127.0.0.1:\(options.port)/")
                print("Pairing link: http://127.0.0.1:\(options.port)/#pair=\(code)")
                print("Device token: \(token)")
                fflush(stdout)
            case let .failure(error):
                FileHandle.standardError.write(Data("serve: \(error)\n".utf8))
                exit(1)
            }
        }
        running = (server, api)
    }
}
