import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import SopranoAgentsCore

/// Phone access as a whole (`remote.*` settings): runs `RemoteServer` + `RemoteAPI`, publishes
/// them with `TailscaleServe`, keeps the app reachable (login item, awake on AC power) and
/// pushes thread alerts to paired devices (`WebPushPoster`). Settings › Phone reads `state` and
/// calls the pairing actions. One per app launch (`RemoteAccess.current`); tests and the
/// snapshot harness have none.
@MainActor
final class RemoteAccess {
    enum ServerState: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    struct State: Equatable {
        var server: ServerState = .off
        /// nil while unknown (checking, or remote access off).
        var tailscale: TailscaleServe.Status?
        var loginItemProblem: String?

        /// The web app's URL once published.
        var url: URL? { tailscale?.url }
    }

    static private(set) var current: RemoteAccess?

    let store: RemoteStore
    let terminals: RemoteTerminals
    private let api: RemoteAPI
    private var server: HTTPServer?
    private var settings = AppSettings.Remote()
    private var publishTask: Task<Void, Never>?
    /// The last Tailscale change (publish or unpublish); the next one waits for it.
    private var tailscaleWork: Task<Void, Never>?
    /// The server being started, or the wait before retrying a failed start.
    private var startTask: Task<Void, Never>?
    /// Finishes once the last stopped server has let go of its port.
    private var portReleased: Task<Void, Never>?

    /// How the server is published on the tailnet; tests replace it.
    struct Publisher {
        var publish: @Sendable (_ httpsPort: Int, _ localPort: Int) async -> TailscaleServe.Status
        var unpublish: @Sendable (_ httpsPort: Int, _ localPort: Int) async -> Void

        static let tailscale = Publisher(
            publish: { await TailscaleServe.publish(httpsPort: $0, localPort: $1) },
            unpublish: { await TailscaleServe.unpublish(httpsPort: $0, localPort: $1) }
        )
    }

    var publisher = Publisher.tailscale
    /// Waits between publish attempts until one succeeds; the last repeats. Tailscale may still be
    /// starting (login items launch in any order) or the user may fix a conflict later.
    var retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60)]
    private var sleepAssertion: IOPMAssertionID?
    private var powerTimer: Timer?
    private let observers = ObserverList<Void>()
    private(set) var state = State() {
        didSet { if state != oldValue { observers.notify(()) } }
    }

    init(engine: AgentEngine, dataDirectory: URL) {
        store = RemoteStore(url: dataDirectory.appendingPathComponent("remote.json"))
        terminals = RemoteTerminals(engine: engine)
        api = RemoteAPI(engine: engine, store: store, terminals: terminals)
        store.addObserver(self) { [weak self] in self?.observers.notify(()) }
        Self.current = self
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.add(owner) { _ in handler() }
    }

    var isEnabled: Bool { settings.enabled }
    var pushEnabled: Bool { settings.enabled && settings.push }

    /// The link a phone opens to pair; nil until the URL is known.
    var pairingLink: URL? {
        guard let url = state.url else { return nil }
        return URL(string: url.absoluteString + "#pair=" + store.pairingCode)
    }


    /// The snapshot harness's Settings › Phone: published at a sample tailnet URL with one paired
    /// device, no server, nothing on disk outside a temporary folder.
    static func installFixture() {
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [:], git: FixtureGitService(), store: InMemoryThreadStore(), dataDirectory: FileManager.default.temporaryDirectory
        ))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-remote-fixture-\(UUID().uuidString)")
        let access = RemoteAccess(engine: engine, dataDirectory: directory)
        _ = access.store.pair(code: access.store.pairingCode, name: "iPhone")
        access.settings.enabled = true
        access.state = State(server: .running, tailscale: .published(URL(string: "https://macbook.tail1234.ts.net/")!))
        fixture = (access, engine)
    }

    private static var fixture: (RemoteAccess, AgentEngine)?
    // MARK: - Settings

    func apply(_ next: AppSettings.Remote) {
        let previous = settings
        settings = next
        let active = server != nil || startTask != nil
        if !next.enabled {
            if previous.enabled || active { stop(unpublishing: previous) }
        } else if !active || previous.port != next.port || previous.httpsPort != next.httpsPort || !previous.enabled {
            if active { stop(unpublishing: previous) }
            start()
        }
        updateLoginItem()
        updateSleepAssertion()
    }

    /// Retries publishing (Settings › Phone "Retry").
    func republish() {
        guard settings.enabled, state.server == .running else { return }
        publish()
    }

    func rotatePairingCode() {
        store.rotatePairingCode()
    }

    func revoke(deviceID: String) {
        store.revoke(deviceID: deviceID)
    }

    /// Stops the server and turns its Tailscale Serve config off (app quit keeps it: the next
    /// launch serves the same port again).
    func shutdown() {
        startTask?.cancel()
        startTask = nil
        if let server {
            let previous = portReleased
            portReleased = Task {
                await previous?.value
                await withCheckedContinuation { continuation in server.stop { continuation.resume() } }
            }
        }
        server = nil
        api.closeStreams()
        terminals.closeAll()
        releaseSleepAssertion()
    }

    // MARK: - Server

    /// Starts the server once a previous one has let go of the port; a failed start (the port is
    /// still taken) is retried like publishing (`retryDelays`).
    private func start(attempt: Int = 0) {
        state.server = .starting
        state.tailscale = nil
        let api = api
        let port = settings.port
        let released = portReleased
        startTask = Task { [weak self] in
            await released?.value
            guard !Task.isCancelled, let self, self.settings.enabled, self.settings.port == port else { return }
            let admit = RemoteAPI.admission(tokens: self.store.tokens)
            let server = HTTPServer(port: UInt16(clamping: port), admit: admit) { request in await api.handle(request) }
            self.server = server
            do {
                try server.start { [weak self] result in
                    Task { @MainActor in self?.serverStateChanged(result, server: server, attempt: attempt) }
                }
            } catch {
                self.serverStateChanged(.failure(error), server: server, attempt: attempt)
            }
        }
    }

    private func serverStateChanged(_ result: Result<Void, Error>, server: HTTPServer, attempt: Int) {
        guard self.server === server else { return }
        switch result {
        case .success:
            state.server = .running
            publish()
        case let .failure(error):
            state.server = .failed("Port \(settings.port): \(error.localizedDescription)")
            self.server = nil
            let previous = portReleased
            portReleased = Task {
                await previous?.value
                await withCheckedContinuation { continuation in server.stop { continuation.resume() } }
            }
            guard !retryDelays.isEmpty else { return }
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            let port = settings.port
            startTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.settings.enabled, self.settings.port == port, self.server == nil else { return }
                self.start(attempt: attempt + 1)
            }
        }
    }

    /// Publishes, retrying (`retryDelays`) until it succeeds or remote access stops. Starts only
    /// after the previous Tailscale change (an unpublish) has finished.
    private func publish() {
        publishTask?.cancel()
        let httpsPort = settings.httpsPort
        let port = settings.port
        let publisher = publisher
        let delays = retryDelays
        let previous = tailscaleWork
        let task = Task { [weak self] in
            await previous?.value
            var attempt = 0
            while !Task.isCancelled {
                let status = await publisher.publish(httpsPort, port)
                guard !Task.isCancelled, let self, self.settings.enabled, self.settings.port == port else { return }
                self.state.tailscale = status
                if status.url != nil || delays.isEmpty { return }
                try? await Task.sleep(for: delays[min(attempt, delays.count - 1)])
                attempt += 1
            }
        }
        publishTask = task
        tailscaleWork = task
    }

    /// Turns the old config off once any publish still running (a cancelled one may be mid-CLI
    /// call) has finished, so it can't come back after the unpublish.
    private func stop(unpublishing settings: AppSettings.Remote) {
        publishTask?.cancel()
        publishTask = nil
        shutdown()
        state = State(server: .off, tailscale: nil, loginItemProblem: state.loginItemProblem)
        let (httpsPort, port) = (settings.httpsPort, settings.port)
        let publisher = publisher
        let previous = tailscaleWork
        tailscaleWork = Task {
            await previous?.value
            await publisher.unpublish(httpsPort, port)
        }
    }

    // MARK: - Login item

    /// Registers the installed app (not dev builds) to open at login while remote access and
    /// `launchAtLogin` are on.
    private func updateLoginItem() {
        guard Bundle.main.bundleIdentifier == "com.soprano.agents" else { return }
        let service = SMAppService.mainApp
        let wanted = settings.enabled && settings.launchAtLogin
        do {
            if wanted, service.status != .enabled {
                try service.register()
            } else if !wanted, service.status == .enabled {
                try service.unregister()
            }
            state.loginItemProblem = service.status == .requiresApproval
                ? "Allow Soprano Agents in System Settings › General › Login Items."
                : nil
        } catch {
            state.loginItemProblem = error.localizedDescription
        }
    }

    // MARK: - Sleep

    /// Holds "prevent idle system sleep" while remote access and `preventSleep` are on and the
    /// Mac runs on AC power (checked every minute).
    private func updateSleepAssertion() {
        let wanted = settings.enabled && settings.preventSleep
        if wanted, powerTimer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { RemoteAccess.current?.updateSleepAssertion() }
            }
            RunLoop.main.add(timer, forMode: .common)
            powerTimer = timer
        } else if !wanted {
            powerTimer?.invalidate()
            powerTimer = nil
        }
        if wanted, Self.isOnACPower() {
            guard sleepAssertion == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Soprano Agents phone access" as CFString,
                &id
            )
            if result == kIOReturnSuccess { sleepAssertion = id }
        } else {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        guard let id = sleepAssertion else { return }
        IOPMAssertionRelease(id)
        sleepAssertion = nil
    }

    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }
}

/// Sends thread alerts to every subscribed device while `remote.push` is on; drops
/// subscriptions the push service reports gone.
@MainActor
final class WebPushPoster: ThreadNotificationPosting {
    private let access: RemoteAccess

    init(access: RemoteAccess) {
        self.access = access
    }

    private struct Payload: Encodable {
        var title: String
        var body: String
        var threadID: String
    }

    func post(threadID: String, alert: ThreadAlert, body: String, sound: Bool) {
        guard access.pushEnabled, !access.store.subscriptions.isEmpty,
              let payload = try? RemoteJSON.encoder.encode(Payload(title: alert.title, body: body, threadID: threadID)) else { return }
        let sender = WebPushSender(keys: access.store.vapidKeys)
        let store = access.store
        for subscription in store.subscriptions {
            Task {
                if await sender.send(payload, to: subscription) == .gone {
                    store.removeSubscription(endpoint: subscription.endpoint)
                }
            }
        }
    }
}
