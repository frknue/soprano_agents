import AppKit
import Testing
@testable import SopranoAgentsCore

struct OpencodeServerTests {
    /// Counts pairings; every endpoint it hands out points at a port nothing listens on.
    final class DeadPairing: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var pairings: Int { lock.withLock { count } }

        func pair(_ executable: String) async throws -> OpencodeServer.Endpoint {
            lock.withLock { count += 1 }
            return OpencodeServer.Endpoint(url: URL(string: "http://127.0.0.1:9")!, authorization: "Basic eA==")
        }
    }

    /// The service restarted (on another port): the event stream pairs again before giving up,
    /// like requests do, instead of handing out a stream that can only fail.
    @Test func anUnreachableEventStreamPairsAgainOnceAndThenFails() async throws {
        let pairing = DeadPairing()
        let server = OpencodeServer(executablePath: { "/bin/sh" }, pairing: { try await pairing.pair($0) })
        await #expect(throws: (any Error).self) { _ = try await server.events() }
        #expect(pairing.pairings == 2)
    }

    @Test func anUnreachableRequestPairsAgainOnceAndThenFails() async throws {
        let pairing = DeadPairing()
        let server = OpencodeServer(executablePath: { "/bin/sh" }, pairing: { try await pairing.pair($0) })
        await #expect(throws: ProviderError.self) { _ = try await server.request("GET", "/api/info") }
        #expect(pairing.pairings == 2)
    }
}
