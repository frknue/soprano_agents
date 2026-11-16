import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

/// The phone web app's API against a real engine: auth and pairing, routes called directly, and
/// the event and terminal streams over a real loopback server.
@MainActor
struct RemoteAPITests {
    private struct Fixture {
        let engine: AgentEngine
        let store: RemoteStore
        let terminals: RemoteTerminals
        let api: RemoteAPI
        let token: String
        let threadID: String
    }

    private func fixture(webRoot: URL? = nil) -> Fixture {
        let engine = EngineHarness.engine()
        let threadID = EngineHarness.idleThread(in: engine)
        let archived = AgentThread(projectID: nil, title: "Old", modelSelection: .default(for: .omp), archivedAt: Date())
        engine.insertThread(archived)
        let store = RemoteStore(url: EngineHarness.temporaryDirectory().appendingPathComponent("remote.json"))
        let token = store.pair(code: store.pairingCode, name: "Test phone")!
        let terminals = RemoteTerminals(engine: engine)
        terminals.shell = { "/bin/sh" }
        let api = RemoteAPI(engine: engine, store: store, terminals: terminals, webRoot: webRoot)
        return Fixture(engine: engine, store: store, terminals: terminals, api: api, token: token, threadID: threadID)
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: String = "") -> HTTPRequest {
        let (decodedPath, query) = HTTPRequest.splitTarget(path)
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: decodedPath, query: query, headers: headers, body: Data(body.utf8))
    }

    private func response(_ reply: HTTPReply) -> HTTPResponse? {
        if case let .response(response) = reply { return response }
        return nil
    }

    private func json(_ response: HTTPResponse?) -> [String: Any] {
        guard let body = response?.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }

    @Test func apiRoutesNeedAPairedTokenAndThePairingCodeBuysOne() async {
        let f = fixture()

        let anonymous = response(await f.api.handle(request("GET", "/api/state")))
        let wrongCode = response(await f.api.handle(request("POST", "/api/pair", body: #"{"code":"nope","name":"x"}"#)))
        let paired = response(await f.api.handle(request("POST", "/api/pair", body: "{\"code\":\"\(f.store.pairingCode)\",\"name\":\"iPhone\"}")))
        let token = json(paired)["token"] as? String

        #expect(anonymous?.status == 401)
        #expect(wrongCode?.status == 403)
        #expect(paired?.status == 200)
        #expect(token != nil && token != f.token)
        #expect(f.store.devices.map(\.name) == ["Test phone", "iPhone"])
        let saved = String(decoding: (try? Data(contentsOf: f.store.url)) ?? Data(), as: UTF8.self)
        #expect(!saved.contains(token ?? "-"))

        f.store.revoke(deviceID: f.store.devices[0].id)
        let revoked = response(await f.api.handle(request("GET", "/api/state", token: f.token)))
        #expect(revoked?.status == 401)
    }

    @Test func revokingAPhoneDropsItsPushSubscriptionsButKeepsOtherPhones() async {
        let f = fixture()
        let other = f.store.pair(code: f.store.pairingCode, name: "iPad")!
        func subscribe(_ token: String, _ endpoint: String) async -> Int? {
            let body = "{\"endpoint\":\"\(endpoint)\",\"keys\":{\"p256dh\":\"k\",\"auth\":\"a\"}}"
            return response(await f.api.handle(request("POST", "/api/push/subscriptions", token: token, body: body)))?.status
        }

        #expect(await subscribe(f.token, "https://web.push.apple.com/phone") == 204)
        #expect(await subscribe(other, "https://web.push.apple.com/ipad") == 204)
        f.store.revoke(deviceID: f.store.devices.first { $0.name == "Test phone" }!.id)

        #expect(f.store.subscriptions.map(\.endpoint) == ["https://web.push.apple.com/ipad"])
    }

    @Test func theStateListsUnarchivedThreadsAsSummaries() async {
        let f = fixture()

        let state = json(response(await f.api.handle(request("GET", "/api/state", token: f.token))))
        let threads = state["threads"] as? [[String: Any]] ?? []

        #expect(threads.map { $0["id"] as? String } == [f.threadID])
        #expect(threads.first?["status"] as? String == "idle")
        #expect(threads.first?["section"] as? String == "idle")
        #expect((state["projects"] as? [Any])?.count == 1)
        #expect((state["runtimeModes"] as? [Any])?.count == RuntimeMode.allCases.count)
    }

    @Test func routesActOnTheEngine() async {
        let f = fixture()

        let pin = response(await f.api.handle(request("PATCH", "/api/threads/\(f.threadID)", token: f.token, body: #"{"pinned":true,"title":"Renamed"}"#)))
        let detail = json(response(await f.api.handle(request("GET", "/api/threads/\(f.threadID)", token: f.token))))
        let missing = response(await f.api.handle(request("GET", "/api/threads/nope", token: f.token)))
        let badMode = response(await f.api.handle(request("POST", "/api/threads/\(f.threadID)/messages", token: f.token, body: #"{"text":"hi","mode":"later"}"#)))

        #expect(pin?.status == 204)
        #expect(f.engine.thread(f.threadID)?.pinnedAt != nil)
        #expect((detail["summary"] as? [String: Any])?["title"] as? String == "Renamed")
        #expect((detail["thread"] as? [String: Any])?["id"] as? String == f.threadID)
        #expect(missing?.status == 404)
        #expect(badMode?.status == 400)
    }

    @Test func staticFilesStayInsideTheWebRootAndThemeCSSComesFromThePalette() async throws {
        let root = EngineHarness.temporaryDirectory().appendingPathComponent("Web")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<h1>app</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.deletingLastPathComponent().appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let f = fixture(webRoot: root)

        let index = response(await f.api.handle(request("GET", "/")))
        let escape = response(await f.api.handle(HTTPRequest(method: "GET", path: "/../secret.txt", query: [:], headers: [:], body: Data())))
        let theme = response(await f.api.handle(request("GET", "/theme.css")))

        #expect(index?.status == 200)
        let indexText = String(decoding: index?.body ?? Data(), as: UTF8.self)
        let themeText = String(decoding: theme?.body ?? Data(), as: UTF8.self)
        #expect(indexText == "<h1>app</h1>")
        #expect(escape?.status == 404)
        #expect(themeText.contains("--primary: "))
    }

    @Test func theEventStreamStartsWithTheStateAndReportsThreadChanges() async throws {
        let f = fixture()
        let (server, port) = try await serve(f)
        defer { server.stop() }
        let lines = try await eventLines(port: port, path: "/api/events", token: f.token)

        var seen: [String] = []
        for try await line in lines where line.hasPrefix("event: ") {
            seen.append(String(line.dropFirst("event: ".count)))
            if seen == ["state"] { f.engine.setPinned(f.threadID, true) }
            if seen.contains("thread") { break }
        }

        #expect(seen == ["state", "threads", "thread"])
    }

    @Test func revokingAPhoneEndsItsOpenEventStreamBeforeTheNextChange() async throws {
        let f = fixture()
        let (server, port) = try await serve(f)
        defer { server.stop() }
        let lines = try await eventLines(port: port, path: "/api/events", token: f.token)

        var seen: [String] = []
        do {
            for try await line in lines where line.hasPrefix("event: ") {
                seen.append(String(line.dropFirst("event: ".count)))
                if seen == ["state"] {
                    f.store.revoke(deviceID: f.store.devices[0].id)
                    f.engine.setPinned(f.threadID, true)
                }
            }
        } catch {
            // The server closing the stream may surface as an error instead of its end.
        }

        #expect(seen == ["state"])
    }

    @Test func aPhotoUploadedOverTheNetworkIsSentWithTheMessageAndServedBack() async throws {
        let f = fixture()
        let (server, port) = try await serve(f)
        defer { server.stop() }
        // Several MB, as a phone photo: arrives in many reads.
        let photo = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var upload = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/attachments")!)
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(f.token)", forHTTPHeaderField: "Authorization")
        upload.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        upload.setValue("../Holiday%20photo.jpg", forHTTPHeaderField: "X-Filename")
        let (body, uploadResponse) = try await URLSession.shared.upload(for: upload, from: photo)
        let uploaded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let id = try #require(uploaded?["id"] as? String)

        let sent = response(await f.api.handle(request("POST", "/api/threads/\(f.threadID)/messages", token: f.token, body: "{\"text\":\"\",\"attachments\":[\"\(id)\"]}")))
        let again = response(await f.api.handle(request("POST", "/api/threads/\(f.threadID)/messages", token: f.token, body: "{\"text\":\"x\",\"attachments\":[\"\(id)\"]}")))
        let served = response(await f.api.handle(request("GET", "/api/attachments/\(id)", token: f.token)))
        let anonymous = response(await f.api.handle(request("GET", "/api/attachments/\(id)")))
        let attachment = f.engine.thread(f.threadID)?.turns.first?.userMessage.attachments.first

        #expect((uploadResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(uploaded?["kind"] as? String == "image")
        #expect(uploaded?["name"] as? String == "Holiday photo.jpg")
        #expect(sent?.status == 204)
        #expect(attachment?.id == id)
        #expect(again?.status == 400)
        #expect(served?.status == 200 && served?.body == photo)
        #expect(served?.headers.first { $0.0 == "Content-Type" }?.1 == "image/jpeg")
        #expect(anonymous?.status == 401)
    }

    @Test func uploadNamesLoseFoldersAndLeadingDots() {
        #expect(RemoteAPI.safeFileName("../../etc/passwd") == "passwd")
        #expect(RemoteAPI.safeFileName("..hidden") == "hidden")
        #expect(RemoteAPI.safeFileName("  ") == "attachment")
        #expect(RemoteAPI.safeFileName("a\\b\\shot.png") == "shot.png")
    }

    @Test func aPhoneTerminalRunsInTheThreadFolderAndEchoesWhatIsTyped() async throws {
        let f = fixture()
        let (server, port) = try await serve(f)
        defer {
            server.stop()
            f.terminals.closeAll()
        }
        let created = json(response(await f.api.handle(request("POST", "/api/threads/\(f.threadID)/terminals", token: f.token, body: #"{"cols":80,"rows":24}"#))))
        let id = try #require(created["id"] as? String)
        let lines = try await eventLines(port: port, path: "/api/terminals/\(id)/output", token: f.token)
        let input = response(await f.api.handle(request("POST", "/api/terminals/\(id)/input", token: f.token, body: #"{"data":"echo sa-$((40+2)); pwd\n"}"#)))

        var output = ""
        let folder = try #require(f.engine.thread(f.threadID).map { f.engine.workingDirectory(for: $0) })
        for try await line in lines where line.hasPrefix("data: ") {
            let event = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
            if let data = (event?["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                output += String(decoding: data, as: UTF8.self)
            }
            if output.contains("sa-42"), output.contains(URL(fileURLWithPath: folder).lastPathComponent) { break }
        }

        #expect(input?.status == 204)
        #expect(output.contains("sa-42"))
        #expect(f.terminals.list(threadID: f.threadID).map(\.title) == ["Phone 1"])
        #expect(response(await f.api.handle(request("DELETE", "/api/terminals/\(id)", token: f.token)))?.status == 204)
        #expect(f.terminals.list(threadID: f.threadID).isEmpty)
    }

    // MARK: - Network helpers

    private func serve(_ f: Fixture) async throws -> (HTTPServer, Int) {
        let api = f.api
        for _ in 0..<20 {
            // Below macOS's ephemeral range (49152–65535), where outgoing connections bind.
            let port = Int.random(in: 40_000..<49_000)
            let server = HTTPServer(port: UInt16(port), admit: RemoteAPI.admission(tokens: f.store.tokens)) { request in await api.handle(request) }
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let resumed = Resumed()
                do {
                    try server.start { result in
                        if resumed.claim() { continuation.resume(returning: (try? result.get()) != nil) }
                    }
                } catch {
                    if resumed.claim() { continuation.resume(returning: false) }
                }
            }
            if result { return (server, port) }
            server.stop()
        }
        throw RemoteTestError(message: "No free port")
    }

    private func eventLines(port: Int, path: String, token: String) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return bytes.lines
    }
}

private struct RemoteTestError: Error {
    var message: String
}

/// Resumes a continuation once from whichever callback comes first.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
