import AppKit
import Testing
@testable import SopranoAgents

/// What the remote server reads: HTTP requests, `tailscale serve status --json`, and the
/// `remote.*` settings.
struct RemoteParsingTests {
    @Test func aRequestIsParsedOnlyOnceItsWholeBodyArrived() {
        let head = "POST /api/threads/a%20b/messages?turn=3 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t0k\r\nContent-Length: 10\r\n\r\n"

        guard case .incomplete = HTTPServer.parse(Data("POST /api/x HTTP/1.1\r\nHost".utf8)) else { Issue.record("head"); return }
        guard case .incomplete = HTTPServer.parse(Data((head + "{\"text\"").utf8)) else { Issue.record("body"); return }
        guard case let .request(request) = HTTPServer.parse(Data((head + "{\"text\":1}").utf8)) else { Issue.record("request"); return }

        #expect(request.method == "POST")
        #expect(request.segments == ["api", "threads", "a b", "messages"])
        #expect(request.query == ["turn": "3"])
        #expect(request.bearerToken == "t0k")
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"text\":1}")
    }

    @Test func aChunkedBodyIsJoinedOnceItsLastChunkArrived() {
        let head = "POST /api/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"

        guard case .incomplete = HTTPServer.parse(Data((head + "4\r\n{\"a\"\r\n").utf8)) else { Issue.record("partial"); return }
        guard case let .request(request) = HTTPServer.parse(Data((head + "4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n").utf8)) else { Issue.record("complete"); return }

        #expect(String(decoding: request.body, as: UTF8.self) == "{\"a\":1}")
    }

    @Test func aHugeChunkSizeIsRefusedWithoutOverflowing() {
        let request = "POST /api/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n"
        guard case let .failed(response) = HTTPServer.parse(Data(request.utf8)) else { Issue.record("not refused"); return }

        #expect(response.status == 413)
    }

    @Test func malformedOrOversizedRequestsAreRefused() {
        guard case let .failed(malformed) = HTTPServer.parse(Data("NONSENSE\r\n\r\n".utf8)) else { Issue.record("malformed"); return }
        let big = "POST / HTTP/1.1\r\nContent-Length: \(HTTPServer.maxBodyBytes + 1)\r\n\r\n"
        guard case let .failed(tooLarge) = HTTPServer.parse(Data(big.utf8)) else { Issue.record("too large"); return }

        #expect(malformed.status == 400)
        #expect(tooLarge.status == 413)
    }

    @Test func serveStatusTellsOurProxyFromSomethingElseOnThePort() {
        let ours: [String: Any] = ["Web": ["mac.tail.ts.net:443": ["Handlers": ["/": ["Proxy": "http://127.0.0.1:47261"]]]]]
        let other: [String: Any] = ["Web": ["mac.tail.ts.net:443": ["Handlers": ["/": ["Path": "/srv"], "/api": ["Proxy": "http://127.0.0.1:3000"]]]]]
        let tcp: [String: Any] = ["TCP": ["443": ["TCPForward": "127.0.0.1:22"]]]

        #expect(TailscaleServe.proxy(in: ours, host: "mac.tail.ts.net", httpsPort: 443) == "http://127.0.0.1:47261")
        #expect(TailscaleServe.proxy(in: ours, host: "mac.tail.ts.net", httpsPort: 8443) == nil)
        #expect(TailscaleServe.proxy(in: other, host: "mac.tail.ts.net", httpsPort: 443) == "another web config (/, /api)")
        #expect(TailscaleServe.proxy(in: tcp, host: "mac.tail.ts.net", httpsPort: 443) == "a TCP forward to 127.0.0.1:22")
        #expect(TailscaleServe.proxy(in: [:], host: "mac.tail.ts.net", httpsPort: 443) == nil)
    }

    @Test func remoteSettingsResolveWithWarningsForBadValues() throws {
        let resolved = try SettingsResolver.resolve(text: """
        { "remote": { "enabled": false, "port": 5000, "httpsPort": 70000, "push": "yes", "launchAtLogin": false, "colour": 1 } }
        """)
        let remote = resolved.settings.remote

        #expect(!remote.enabled && remote.port == 5000 && !remote.launchAtLogin)
        #expect(remote.httpsPort == 443 && remote.push && remote.preventSleep)
        #expect(resolved.issues.map(\.message) == [
            "Unknown setting \"remote.colour\".",
            "remote.push must be true or false.",
            "remote.httpsPort must be a port number (1–65535).",
        ])
    }
}
