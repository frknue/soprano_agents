import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

/// Phone access as a whole: publishing on the tailnet retries until Tailscale is ready, stops
/// when remote access is turned off, and never overlaps an unpublish.
@MainActor
struct RemoteAccessTests {
    /// Answers publish attempts from a script and logs every call in order.
    private final class ScriptedPublisher: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [TailscaleServe.Status]
        private var calls: [String] = []
        private let unpublishDelay: Duration

        init(_ answers: [TailscaleServe.Status], unpublishDelay: Duration = .zero) {
            self.answers = answers
            self.unpublishDelay = unpublishDelay
        }

        var log: [String] { lock.withLock { calls } }
        var publishes: Int { log.filter { $0 == "publish" }.count }

        private func record(_ call: String) {
            lock.withLock { calls.append(call) }
        }

        var publisher: RemoteAccess.Publisher {
            RemoteAccess.Publisher(
                publish: { _, _ in
                    self.record("publish")
                    return self.lock.withLock { self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0] }
                },
                unpublish: { _, _ in
                    try? await Task.sleep(for: self.unpublishDelay)
                    self.record("unpublished")
                }
            )
        }
    }

    private let url = URL(string: "https://mac.tail.ts.net/")!

    private func access(_ script: ScriptedPublisher) -> RemoteAccess {
        let access = RemoteAccess(engine: EngineHarness.engine(), dataDirectory: EngineHarness.temporaryDirectory())
        access.publisher = script.publisher
        access.retryDelays = [.milliseconds(10)]
        return access
    }

    private func settings(enabled: Bool = true) -> AppSettings.Remote {
        var settings = AppSettings.Remote()
        settings.enabled = enabled
        // Below macOS's ephemeral range (49152–65535), where outgoing connections bind.
        settings.port = Int.random(in: 40_000..<49_000)
        settings.preventSleep = false
        settings.launchAtLogin = false
        return settings
    }

    @Test func publishingRetriesUntilTailscaleConnectsWithoutTheUser() async {
        let script = ScriptedPublisher([.notConnected("Tailscale is starting."), .notConnected("Tailscale is starting."), .published(url)])
        let access = access(script)
        defer { access.apply(settings(enabled: false)) }

        access.apply(settings())

        #expect(await EngineHarness.eventually { access.state.url == self.url })
        #expect(script.publishes == 3)
    }

    @Test func turningRemoteAccessOffStopsTheRetries() async {
        let script = ScriptedPublisher([.notConnected("Tailscale is stopped.")])
        let access = access(script)
        let on = settings()

        access.apply(on)
        #expect(await EngineHarness.eventually { script.publishes >= 2 })
        var off = on
        off.enabled = false
        access.apply(off)
        let stoppedAt = script.publishes
        try? await Task.sleep(for: .milliseconds(100))

        #expect(script.publishes <= stoppedAt + 1)
        #expect(access.state.tailscale == nil)
        #expect(await EngineHarness.eventually { script.log.last == "unpublished" })
    }

    @Test func turningItBackOnQuicklyPublishesOnlyAfterTheSlowUnpublishFinished() async {
        let script = ScriptedPublisher([.published(url)], unpublishDelay: .milliseconds(200))
        let access = access(script)
        let on = settings()
        var off = on
        off.enabled = false
        defer { access.apply(off) }

        access.apply(on)
        #expect(await EngineHarness.eventually { access.state.url == self.url })
        access.apply(off)
        access.apply(on)

        #expect(await EngineHarness.eventually { access.state.url == self.url && script.publishes == 2 })
        #expect(script.log == ["publish", "unpublished", "publish"])
    }
}
