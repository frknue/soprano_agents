import AppKit
import Network
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

/// What keeps an unpaired client out: bodies refused from the head, single-use pairing codes,
/// push only to push services, and headers that keep served content from running as the app.
@MainActor
struct RemoteHardeningTests {
    private func store() -> RemoteStore {
        RemoteStore(url: EngineHarness.temporaryDirectory().appendingPathComponent("remote.json"))
    }

    private func status(_ result: HTTPServer.ParseResult) -> Int? {
        switch result {
        case .incomplete: nil
        case let .failed(response): response.status
        case .request: 200
        }
    }

    @Test func anUnpairedUploadIsRefusedFromItsHeadBeforeAnyBodyArrives() {
        let store = store()
        let token = store.pair(code: store.pairingCode, name: "Phone")!
        let admit = RemoteAPI.admission(tokens: store.tokens)
        let head = "POST /api/attachments HTTP/1.1\r\nContent-Length: 20000000\r\n"

        let anonymous = HTTPServer.parse(Data((head + "\r\n").utf8), admit: admit)
        let wrong = HTTPServer.parse(Data((head + "Authorization: Bearer nope\r\n\r\n").utf8), admit: admit)
        let paired = HTTPServer.parse(Data((head + "Authorization: Bearer \(token)\r\n\r\n").utf8), admit: admit)

        #expect(status(anonymous) == 401)
        #expect(status(wrong) == 401)
        #expect(status(paired) == nil) // waits for the body
    }

    @Test func pairingAndStaticRequestsGetOnlySmallBodies() {
        let admit = RemoteAPI.admission(tokens: store().tokens)
        let pair = HTTPServer.parse(Data("POST /api/pair HTTP/1.1\r\nContent-Length: 5000\r\n\r\n".utf8), admit: admit)
        let page = HTTPServer.parse(Data("POST /index.html HTTP/1.1\r\nContent-Length: 10\r\n\r\n".utf8), admit: admit)

        #expect(status(pair) == 413)
        #expect(status(page) == 413)
    }

    @Test func endlessChunkedFramingIsRefusedInsteadOfBuffered() {
        let admit = RemoteAPI.admission(tokens: store().tokens)
        let head = "POST /api/pair HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let longSizeLine = head + String(repeating: "0", count: 2000)
        let endlessTrailer = head + "0\r\nX-Trailer: " + String(repeating: "a", count: 20000)
        let manyEmptyExtensions = head + String(repeating: "1;" + String(repeating: "e", count: 900) + "\r\na\r\n", count: 40)

        #expect(status(HTTPServer.parse(Data(longSizeLine.utf8), admit: admit)) == 400)
        #expect(status(HTTPServer.parse(Data(endlessTrailer.utf8), admit: admit)) == 400)
        #expect(status(HTTPServer.parse(Data(manyEmptyExtensions.utf8), admit: admit)) == 413)
        // Short framing still waits for the rest.
        #expect(status(HTTPServer.parse(Data((head + "0\r\nX-T: 1").utf8), admit: admit)) == nil)
    }

    @Test func theStoreFileIsOwnerOnlyAndReloadsPairedDevices() throws {
        let url = EngineHarness.temporaryDirectory().appendingPathComponent("remote.json")
        let first = RemoteStore(url: url)
        let token = try #require(first.pair(code: first.pairingCode, name: "Phone"))

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let reloaded = RemoteStore(url: url)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasPrefix(".remote-") }

        #expect(permissions == 0o600)
        #expect(reloaded.tokens.contains(token: token))
        #expect(leftovers.isEmpty)
    }

    @Test func aPairingCodeWorksOnceAndARevokedTokenIsRefusedFromTheHead() {
        let store = store()
        let code = store.pairingCode
        let token = store.pair(code: code, name: "Phone")

        #expect(token != nil)
        #expect(store.pair(code: code, name: "Someone else") == nil)
        #expect(store.pairingCode != code)
        #expect(store.tokens.contains(token: token!))
        store.revoke(deviceID: store.devices[0].id)
        #expect(!store.tokens.contains(token: token!))
    }

    @Test func pushSubscriptionsMustPointAtAPushService() {
        #expect(RemoteAPI.isPushService("https://web.push.apple.com/QK2…"))
        #expect(RemoteAPI.isPushService("https://fcm.googleapis.com/fcm/send/abc"))
        #expect(!RemoteAPI.isPushService("https://192.168.1.10/hook"))
        #expect(!RemoteAPI.isPushService("https://web.push.apple.com.evil.example/x"))
        #expect(!RemoteAPI.isPushService("https://web.push.apple.com:8443/x"))
        #expect(!RemoteAPI.isPushService("http://web.push.apple.com/x"))
    }

    @Test func pagesCarryTheContentPolicyAndUploadsNeverRenderAsPages() async throws {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        let root = EngineHarness.temporaryDirectory().appendingPathComponent("Web")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<h1>app</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let store = store()
        let token = store.pair(code: store.pairingCode, name: "Phone")!
        let api = RemoteAPI(engine: engine, store: store, terminals: RemoteTerminals(engine: engine), webRoot: root)
        func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data()) async -> HTTPResponse? {
            var all = headers
            all["authorization"] = "Bearer \(token)"
            if case let .response(response) = await api.handle(HTTPRequest(method: method, path: path, query: [:], headers: all, body: body)) { return response }
            return nil
        }
        func header(_ response: HTTPResponse?, _ name: String) -> String? {
            response?.headers.first { $0.0 == name }?.1
        }

        let page = await send("GET", "/")
        let upload = await send("POST", "/api/attachments", headers: ["x-filename": "evil.html", "content-type": "text/html"], body: Data("<script>alert(1)</script>".utf8))
        let id = try #require((try? JSONSerialization.jsonObject(with: upload?.body ?? Data()) as? [String: Any])?["id"] as? String)
        let served = await send("GET", "/api/attachments/\(id)")
        let serialized = String(decoding: served?.serialized ?? Data(), as: UTF8.self)

        #expect(header(page, "Content-Security-Policy")?.contains("script-src 'self'") == true)
        #expect(header(served, "Content-Type") == "application/octet-stream")
        #expect(header(served, "Content-Security-Policy")?.contains("sandbox") == true)
        #expect(serialized.contains("X-Content-Type-Options: nosniff"))
        withExtendedLifetime(threadID) {}
    }

    @Test func clientsTricklingUnpairedRequestsLoseTheirSlotsAtTheDeadline() async throws {
        let tokens = store().tokens
        let limits = HTTPServer.Limits(maxConnections: 2, idleTimeout: 10, requestDeadline: 0.4)
        var started: (HTTPServer, Int)?
        for _ in 0..<20 where started == nil {
            // Below macOS's ephemeral range (49152–65535), where outgoing connections bind.
            let port = Int.random(in: 40_000..<49_000)
            let server = HTTPServer(port: UInt16(port), admit: RemoteAPI.admission(tokens: tokens), limits: limits) { _ in .response(.noContent) }
            let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = Once()
                do {
                    try server.start { result in once.run { continuation.resume(returning: (try? result.get()) != nil) } }
                } catch {
                    once.run { continuation.resume(returning: false) }
                }
            }
            if ready { started = (server, port) } else { server.stop() }
        }
        let (server, port) = try #require(started)
        defer { server.stop() }

        // Two clients fill every slot with a pairing body sent one byte every 50 ms: the idle
        // timeout alone would keep them for as long as they keep sending.
        let tricklers = (0..<2).map { _ in Trickler(port: port) }
        defer { tricklers.forEach { $0.stop() } }
        try await Task.sleep(for: .milliseconds(150))
        let blocked = await Self.get(port: port)
        try await Task.sleep(for: .milliseconds(500))
        let served = await Self.get(port: port)

        #expect(blocked == nil)
        #expect(served == 204)
    }

    /// GET / with a short timeout: its status, or nil when the connection was refused or dropped.
    nonisolated private static func get(port: Int) async -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
    }
}

/// A client that opens a connection, sends a pairing request head and then one body byte every
/// 50 ms until stopped.
private final class Trickler: @unchecked Sendable {
    private let connection: NWConnection
    private let timer: DispatchSourceTimer
    private let queue = DispatchQueue(label: "trickler")

    init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        timer = DispatchSource.makeTimerSource(queue: queue)
        connection.start(queue: queue)
        connection.send(content: Data("POST /api/pair HTTP/1.1\r\nContent-Length: 4000\r\n\r\n".utf8), completion: .idempotent)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [connection] in connection.send(content: Data("a".utf8), completion: .idempotent) }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        connection.cancel()
    }
}

/// Runs its closure the first time only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
