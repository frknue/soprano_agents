import AppKit
import SopranoAgentsCore
import UniformTypeIdentifiers

/// The phone web app's HTTP API over `AgentEngine` (contract: `docs/ARCHITECTURE.md` →
/// "Remote access"). Serves the static web app and `/theme.css` without auth, everything under
/// `/api/` (except pairing) only for a paired device's bearer token. Pushes engine changes to
/// every open `/api/events` stream, coalesced.
@MainActor
final class RemoteAPI {
    private let engine: AgentEngine
    private let store: RemoteStore
    private let terminals: RemoteTerminals
    private let webRoot: URL?
    private var streams: [EventStream] = []
    /// Phone uploads not sent yet, by attachment id (memory only).
    private var uploads: [String: Attachment] = [:]
    /// Every open stream (events and terminal output) with the device that opened it.
    private var deviceStreams: [(deviceID: String, stream: EventStream)] = []
    private var dirtyList = false
    private var dirtyProjects = false
    private var dirtyProviders = false
    private var dirtyThreads: Set<String> = []
    private var dirtyItems: [String: (threadID: String, turnID: String)] = [:]
    private var flush: Task<Void, Never>?
    private var ping: Task<Void, Never>?

    static let coalesceDelay: Duration = .milliseconds(120)

    init(engine: AgentEngine, store: RemoteStore, terminals: RemoteTerminals, webRoot: URL? = RemoteAPI.bundledWebRoot) {
        self.engine = engine
        self.store = store
        self.terminals = terminals
        self.webRoot = webRoot
        engine.addObserver(self) { [weak self] event in self?.engineChanged(event) }
        terminals.onChange = { [weak self] threadID in self?.terminalsChanged(threadID) }
        store.addObserver(self) { [weak self] in self?.closeRevokedStreams() }
    }

    /// A revoked device loses its open streams at once.
    private func closeRevokedStreams() {
        let paired = Set(store.devices.map(\.id))
        for entry in deviceStreams where !paired.contains(entry.deviceID) { entry.stream.close() }
        deviceStreams.removeAll { !paired.contains($0.deviceID) }
    }

    private func track(_ stream: EventStream, device: PairedDevice) {
        deviceStreams.append((device.id, stream))
        stream.onClose { [weak self] in self?.deviceStreams.removeAll { $0.stream === stream } }
    }

    /// The web app inside the resource bundle.
    static var bundledWebRoot: URL? {
        AppResources.bundle.url(forResource: "Web", withExtension: nil)
    }

    /// What the server reads of a request before any handler runs (`HTTPServer.Admission`):
    /// static files and pairing get small bodies; every other `/api/` route needs a paired
    /// device's token first, so an unpaired client can't make the app read large bodies.
    nonisolated static func admission(tokens: TokenIndex) -> HTTPServer.Admission {
        { method, path, headers in
            guard path == "/api" || path.hasPrefix("/api/") else { return .allow(maxBody: 0) }
            if path == "/api/pair" { return .allow(maxBody: 4 << 10) }
            guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer "),
                  tokens.contains(token: value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)) else {
                return .reject(.error(401, "This device is not paired. Open the pairing link from Soprano Agents › Settings › Phone."))
            }
            return .allow(maxBody: method == "POST" && path == "/api/attachments" ? HTTPServer.maxBodyBytes : HTTPServer.smallBodyBytes)
        }
    }

    /// Push services the app delivers to (Apple, Google, Mozilla, Microsoft); a subscription
    /// elsewhere would make the Mac send requests to an address a device picked.
    static func isPushService(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host?.lowercased(),
              url.port == nil || url.port == 443 else { return false }
        let services = ["push.apple.com", "fcm.googleapis.com", "push.services.mozilla.com", "notify.windows.com"]
        return services.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The web app's pages: scripts only from this origin, no plugins, frames or foreign posts.
    static let contentSecurityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
        + "img-src 'self' blob: data:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "
        + "frame-ancestors 'none'; form-action 'none'; worker-src 'self'; manifest-src 'self'"

    /// Ends every event stream (remote access turned off).
    func closeStreams() {
        for stream in streams { stream.close() }
        for entry in deviceStreams { entry.stream.close() }
        streams.removeAll()
        deviceStreams.removeAll()
        ping?.cancel()
        ping = nil
    }

    // MARK: - Routing

    func handle(_ request: HTTPRequest) async -> HTTPReply {
        let segments = request.segments
        guard segments.first == "api" else { return .response(staticFile(request)) }
        if segments == ["api", "pair"] {
            guard request.method == "POST" else { return .response(.error(405, "Use POST.")) }
            return .response(pair(request))
        }
        guard let token = request.bearerToken, let device = store.device(forToken: token) else {
            return .response(.error(401, "This device is not paired. Open the pairing link from Soprano Agents › Settings › Phone."))
        }
        do {
            return try await route(request, Array(segments.dropFirst()), device: device)
        } catch let error as RouteError {
            return .response(.error(error.status, error.message))
        } catch {
            return .response(.error(400, error.localizedDescription))
        }
    }

    private struct RouteError: Error {
        var status: Int
        var message: String
        static let notFound = RouteError(status: 404, message: "Not found.")
        static func badRequest(_ message: String) -> RouteError { RouteError(status: 400, message: message) }
    }

    /// Matches `METHOD a/:x/b` patterns against the request; `:name` segments are captured in order.
    private struct Route {
        let method: String
        let path: [String]

        func match(_ method: String, _ pattern: String) -> [String]? {
            guard method == self.method else { return nil }
            let parts = pattern.split(separator: "/").map(String.init)
            guard parts.count == path.count else { return nil }
            var captures: [String] = []
            for (part, segment) in zip(parts, path) {
                if part.hasPrefix(":") { captures.append(segment) } else if part != segment { return nil }
            }
            return captures
        }
    }

    private func route(_ request: HTTPRequest, _ path: [String], device: PairedDevice) async throws -> HTTPReply {
        let route = Route(method: request.method, path: path)
        if route.match("GET", "state") != nil {
            return .response(.json(state()))
        }
        if route.match("GET", "events") != nil {
            return .eventStream { [weak self] stream in
                self?.track(stream, device: device)
                self?.open(stream)
            }
        }
        if route.match("POST", "threads") != nil {
            return .response(.json(["threadID": try await launch(decode(NewThreadBody.self, request))]))
        }
        if let p = route.match("GET", "threads/:id") {
            let thread = try thread(p[0])
            return .response(.json(ThreadDetail(thread: thread, summary: ThreadSummary(thread, engine: engine))))
        }
        if let p = route.match("PATCH", "threads/:id") {
            let body = try decode(ThreadPatch.self, request)
            let id = try thread(p[0]).id
            if let title = body.title { engine.rename(id, title: title) }
            if let pinned = body.pinned { engine.setPinned(id, pinned) }
            if let settled = body.settled { engine.setSettled(id, settled) }
            if let archived = body.archived { engine.setArchived(id, archived) }
            return .response(.noContent)
        }
        if let p = route.match("POST", "threads/:id/visited") {
            engine.markVisited(try thread(p[0]).id)
            return .response(.noContent)
        }
        if let p = route.match("POST", "threads/:id/messages") {
            let body = try decode(MessageBody.self, request)
            let attachments = try pendingAttachments(body.attachments)
            try await engine.send(try thread(p[0]).id, text: body.text ?? "", attachments: attachments, mode: try body.sendMode())
            forget(attachments)
            return .response(.noContent)
        }
        if route.match("POST", "attachments") != nil {
            return .response(.json(try upload(request)))
        }
        if let p = route.match("GET", "attachments/:id") {
            guard let attachment = attachment(p[0]), let data = try? Data(contentsOf: URL(fileURLWithPath: attachment.path)) else {
                throw RouteError.notFound
            }
            // Images keep their type for thumbnails (the sandbox policy keeps an SVG's scripts
            // inert); anything else downloads as bytes and never runs as a page of this origin.
            let type = attachment.kind == .image ? attachment.mimeType : "application/octet-stream"
            var response = HTTPResponse.file(data, contentType: type, cache: "private, max-age=86400")
            response.headers.append(("Content-Security-Policy", "default-src 'none'; sandbox"))
            response.headers.append(("Content-Disposition", "attachment"))
            return .response(response)
        }
        if let p = route.match("POST", "threads/:id/interrupt") {
            await engine.interrupt(try thread(p[0]).id)
            return .response(.noContent)
        }
        if let p = route.match("POST", "threads/:id/approvals/:approval") {
            let body = try decode(ApprovalBody.self, request)
            await engine.respond(try thread(p[0]).id, approvalID: p[1], decision: body.decision)
            return .response(.noContent)
        }
        if let p = route.match("POST", "threads/:id/inputs/:request") {
            let body = try decode(AnswerBody.self, request)
            await engine.answer(try thread(p[0]).id, requestID: p[1], answers: body.answers)
            return .response(.noContent)
        }
        if let p = route.match("DELETE", "threads/:id/inputs/:request") {
            await engine.dismissUserInput(try thread(p[0]).id, requestID: p[1])
            return .response(.noContent)
        }
        if let p = route.match("POST", "threads/:id/queue/:message/send") {
            await engine.sendQueuedNow(try thread(p[0]).id, messageID: p[1])
            return .response(.noContent)
        }
        if let p = route.match("DELETE", "threads/:id/queue/:message") {
            engine.cancelQueued(try thread(p[0]).id, messageID: p[1])
            return .response(.noContent)
        }
        if let p = route.match("GET", "threads/:id/diff") {
            let id = try thread(p[0]).id
            var ordinal: Int?
            if let turn = request.query["turn"], !turn.isEmpty {
                guard let value = Int(turn) else { throw RouteError.badRequest("turn must be a number.") }
                ordinal = value
            }
            return .response(.json(["diff": try await engine.turnDiff(id, turnOrdinal: ordinal)]))
        }
        if let p = route.match("GET", "threads/:id/git") {
            return .response(.json(GitStatusBody(await engine.gitStatus(try thread(p[0]).id))))
        }
        if let p = route.match("POST", "threads/:id/git") {
            let body = try decode(GitActionBody.self, request)
            let id = try thread(p[0]).id
            guard let action = GitStackedAction(rawValue: body.action) else { throw RouteError.badRequest("Unknown git action \(body.action).") }
            let result = try await engine.runGitAction(
                id, action: action, commitMessage: body.commitMessage, filePaths: nil, featureBranch: body.featureBranch ?? false, progress: { _ in }
            )
            return .response(.json(GitResultBody(title: result.title, detail: result.detail, pullRequestURL: result.pullRequestURL)))
        }
        if let p = route.match("GET", "projects/:id/branches") {
            guard let project = engine.project(p[0]) else { throw RouteError.notFound }
            let branches = (try? await engine.environment.git.branches(cwd: project.path)) ?? []
            let local = branches.filter { !$0.isRemote }
            return .response(.json(BranchesBody(current: local.first(where: \.isCurrent)?.name, branches: local.map(\.name))))
        }
        if let p = route.match("GET", "threads/:id/terminals") {
            return .response(.json(["terminals": terminals.list(threadID: try thread(p[0]).id)]))
        }
        if let p = route.match("POST", "threads/:id/terminals") {
            let body = try decode(TerminalSizeBody.self, request)
            return .response(.json(try terminals.create(threadID: try thread(p[0]).id, cols: body.cols, rows: body.rows)))
        }
        if let p = route.match("GET", "terminals/:id/output") {
            let id = p[0]
            guard terminals.exists(id) else { throw RouteError.notFound }
            return .eventStream { [weak self] stream in
                guard let self, self.terminals.attach(id, stream: stream) else { return stream.close() }
                self.track(stream, device: device)
            }
        }
        if let p = route.match("POST", "terminals/:id/input") {
            let body = try decode(TerminalInputBody.self, request)
            guard terminals.input(p[0], text: body.data) else { throw RouteError(status: 409, message: "The terminal has ended.") }
            return .response(.noContent)
        }
        if let p = route.match("POST", "terminals/:id/resize") {
            let body = try decode(TerminalSizeBody.self, request)
            guard terminals.resize(p[0], cols: body.cols, rows: body.rows) else { throw RouteError.notFound }
            return .response(.noContent)
        }
        if let p = route.match("DELETE", "terminals/:id") {
            guard terminals.close(p[0]) else { throw RouteError.notFound }
            return .response(.noContent)
        }
        if route.match("GET", "push/key") != nil {
            return .response(.json(["publicKey": store.vapidKeys.publicKey]))
        }
        if route.match("POST", "push/subscriptions") != nil {
            let body = try decode(SubscriptionBody.self, request)
            guard Self.isPushService(body.endpoint) else { throw RouteError.badRequest("The push endpoint is not a known push service.") }
            store.addSubscription(PushSubscription(endpoint: body.endpoint, p256dh: body.keys.p256dh, auth: body.keys.auth, createdAt: Date(), deviceID: device.id))
            return .response(.noContent)
        }
        if route.match("DELETE", "push/subscriptions") != nil {
            store.removeSubscription(endpoint: try decode(SubscriptionEndpointBody.self, request).endpoint)
            return .response(.noContent)
        }
        throw RouteError.notFound
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        do {
            return try RemoteJSON.decoder.decode(type, from: request.body.isEmpty ? Data("{}".utf8) : request.body)
        } catch {
            throw RouteError.badRequest("Invalid request body.")
        }
    }

    private func thread(_ id: String) throws -> AgentThread {
        guard let thread = engine.thread(id) else { throw RouteError.notFound }
        return thread
    }

    // MARK: - Pairing

    private struct PairBody: Decodable {
        var code: String
        var name: String?
    }

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = try? RemoteJSON.decoder.decode(PairBody.self, from: request.body) else {
            return .error(400, "Invalid request body.")
        }
        guard let token = store.pair(code: body.code, name: body.name ?? "") else {
            return .error(403, "This pairing link is no longer valid. Open the current one from Soprano Agents › Settings › Phone.")
        }
        return .json(["token": token])
    }

    // MARK: - Threads

    private struct NewThreadBody: Decodable {
        struct Workspace: Decodable {
            var kind: String
            var baseBranch: String?
        }

        var projectID: String?
        var text: String?
        var attachments: [String]?
        var model: ModelSelection?
        var runtimeMode: RuntimeMode?
        var workspace: Workspace?
    }

    private func launch(_ body: NewThreadBody) async throws -> String {
        let workspace: WorkspaceChoice
        switch body.workspace?.kind ?? "projectRoot" {
        case "projectRoot":
            workspace = .projectRoot
        case "newWorktree":
            guard let base = body.workspace?.baseBranch?.trimmingCharacters(in: .whitespaces), !base.isEmpty else {
                throw RouteError.badRequest("A new worktree needs a base branch.")
            }
            workspace = .newWorktree(baseBranch: base)
        case let kind:
            throw RouteError.badRequest("Unknown workspace \(kind).")
        }
        let project = body.projectID.flatMap { engine.project($0) }
        let draft = ThreadDraft(
            projectID: body.projectID,
            modelSelection: body.model ?? project?.defaultModel ?? engine.settings.defaultModel,
            runtimeMode: body.runtimeMode ?? engine.settings.defaultRuntimeMode,
            workspace: workspace
        )
        let attachments = try pendingAttachments(body.attachments)
        let threadID = try await engine.launchThread(draft, text: body.text ?? "", attachments: attachments)
        forget(attachments)
        return threadID
    }

    // MARK: - Attachments

    /// Stores an upload (raw body, `X-Filename`) through the engine like a file the Mac's
    /// composer attaches; it waits in `uploads` until a message sends it.
    private func upload(_ request: HTTPRequest) throws -> Attachment {
        guard !request.body.isEmpty else { throw RouteError.badRequest("The upload is empty.") }
        var name = Self.safeFileName(request.headers["x-filename"]?.removingPercentEncoding ?? "")
        // The engine tells images from files by extension.
        if (name as NSString).pathExtension.isEmpty,
           let mime = request.headers["content-type"]?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try request.body.write(to: file)
        let attachment = try engine.importAttachment(from: file)
        uploads[attachment.id] = attachment
        return attachment
    }

    /// A file name without folders or a leading dot; "attachment" when nothing is left.
    static func safeFileName(_ raw: String) -> String {
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let trimmed = String(base.drop(while: { $0 == "." })).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : String(trimmed.prefix(120))
    }

    private func pendingAttachments(_ ids: [String]?) throws -> [Attachment] {
        try (ids ?? []).map { id in
            guard let attachment = uploads[id] else {
                throw RouteError.badRequest("An attachment is no longer on the Mac. Remove it and upload it again.")
            }
            return attachment
        }
    }

    private func forget(_ attachments: [Attachment]) {
        for attachment in attachments { uploads[attachment.id] = nil }
    }

    /// An upload waiting to be sent, or an attachment of any message in any thread.
    private func attachment(_ id: String) -> Attachment? {
        if let upload = uploads[id] { return upload }
        for thread in engine.threads {
            let messages = thread.turns.flatMap { [$0.userMessage] + $0.steers } + thread.queue.map(\.message)
            if let attachment = messages.lazy.flatMap(\.attachments).first(where: { $0.id == id }) { return attachment }
        }
        return nil
    }

    private struct ThreadDetail: Encodable {
        var thread: AgentThread
        var summary: ThreadSummary
    }

    private struct ThreadPatch: Decodable {
        var title: String?
        var pinned: Bool?
        var settled: Bool?
        var archived: Bool?
    }

    private struct MessageBody: Decodable {
        var text: String?
        var attachments: [String]?
        var mode: String?

        func sendMode() throws -> SendMode {
            switch mode ?? "automatic" {
            case "automatic": .automatic
            case "steer": .steer
            case "queue": .queue
            default: throw RouteError.badRequest("mode must be automatic, steer or queue.")
            }
        }
    }

    private struct ApprovalBody: Decodable {
        var decision: ApprovalDecision
    }

    private struct AnswerBody: Decodable {
        var answers: [String: [String]]
    }

    // MARK: - Git

    private struct GitStatusBody: Encodable {
        var isRepository: Bool
        var branch: String?
        var isDefaultBranch: Bool
        var hasRemote: Bool
        var hasUpstream: Bool
        var ahead: Int
        var behind: Int
        var files: [ChangedFileStat]
        var pullRequest: PullRequestInfo?

        init(_ status: GitStatusSummary) {
            isRepository = status.isRepository
            branch = status.branch
            isDefaultBranch = status.isDefaultBranch
            hasRemote = status.hasRemote
            hasUpstream = status.hasUpstream
            ahead = status.ahead
            behind = status.behind
            files = status.files
            pullRequest = status.pullRequest
        }
    }

    private struct GitActionBody: Decodable {
        var action: String
        var commitMessage: String?
        var featureBranch: Bool?
    }

    private struct GitResultBody: Encodable {
        var title: String
        var detail: String?
        var pullRequestURL: String?
    }

    private struct BranchesBody: Encodable {
        var current: String?
        var branches: [String]
    }

    // MARK: - Terminals and push

    private struct TerminalSizeBody: Decodable {
        var cols: Int
        var rows: Int
    }

    private struct TerminalInputBody: Decodable {
        var data: String
    }

    private struct SubscriptionBody: Decodable {
        struct Keys: Decodable {
            var p256dh: String
            var auth: String
        }

        var endpoint: String
        var keys: Keys
    }

    private struct SubscriptionEndpointBody: Decodable {
        var endpoint: String
    }

    // MARK: - State

    struct StateBody: Encodable {
        struct Defaults: Encodable {
            var model: ModelSelection
            var runtimeMode: RuntimeMode
        }

        struct RuntimeModeInfo: Encodable {
            var id: String
            var title: String
            var summary: String
        }

        var projects: [Project]
        var threads: [ThreadSummary]
        var providers: [ProviderStatus]
        var defaults: Defaults
        var runtimeModes: [RuntimeModeInfo]
        var host: String
        var version: String
    }

    func state() -> StateBody {
        StateBody(
            projects: engine.projects,
            threads: summaries(),
            providers: providerStatuses,
            defaults: .init(model: engine.settings.defaultModel, runtimeMode: engine.settings.defaultRuntimeMode),
            runtimeModes: RuntimeMode.allCases.map { .init(id: $0.rawValue, title: $0.title, summary: $0.summary) },
            host: Host.current().localizedName ?? "Mac",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
    }

    private var providerStatuses: [ProviderStatus] {
        ProviderKind.allCases.map { engine.status(of: $0) }
    }

    private func summaries() -> [ThreadSummary] {
        engine.threads.compactMap { thread in
            thread.archivedAt == nil ? ThreadSummary(thread, engine: engine) : nil
        }
    }

    // MARK: - Events

    private func open(_ stream: EventStream) {
        streams.append(stream)
        stream.onClose { [weak self] in self?.streams.removeAll { $0 === stream } }
        stream.send("state", state())
        startPing()
    }

    private func startPing() {
        guard ping == nil else { return }
        ping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                for stream in self.streams { stream.comment("ping") }
            }
        }
    }

    private func engineChanged(_ event: EngineEvent) {
        guard !streams.isEmpty else { return }
        switch event {
        case .threadListChanged:
            dirtyList = true
        case let .threadChanged(threadID), let .subagentListChanged(threadID):
            dirtyList = true
            dirtyThreads.insert(threadID)
        case let .itemChanged(threadID, turnID, itemID):
            dirtyItems[itemID] = (threadID, turnID)
        case .projectsChanged:
            dirtyProjects = true
        case .providersChanged:
            dirtyProviders = true
        case .commandsChanged, .subagentChanged, .sideQuestionsChanged:
            return
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            self?.flushEvents()
        }
    }

    private struct ItemEvent: Encodable {
        var threadID: String
        var turnID: String
        var item: TurnItem
    }

    private func flushEvents() {
        flush = nil
        var events: [(String, any Encodable)] = []
        if dirtyProjects { events.append(("projects", ["projects": engine.projects])) }
        if dirtyProviders { events.append(("providers", ["providers": providerStatuses])) }
        if dirtyList { events.append(("threads", ["threads": summaries()])) }
        for threadID in dirtyThreads.sorted() { events.append(("thread", ["threadID": threadID])) }
        for (itemID, location) in dirtyItems where !dirtyThreads.contains(location.threadID) {
            guard let item = engine.thread(location.threadID)?.turns.first(where: { $0.id == location.turnID })?.items.first(where: { $0.id == itemID }) else { continue }
            events.append(("item", ItemEvent(threadID: location.threadID, turnID: location.turnID, item: item)))
        }
        dirtyList = false
        dirtyProjects = false
        dirtyProviders = false
        dirtyThreads.removeAll()
        dirtyItems.removeAll()
        for stream in streams {
            for (name, value) in events { stream.send(name, value) }
        }
    }

    private struct TerminalsEvent: Encodable {
        var threadID: String
        var terminals: [RemoteTerminals.Info]
    }

    private func terminalsChanged(_ threadID: String) {
        let event = TerminalsEvent(threadID: threadID, terminals: terminals.list(threadID: threadID))
        for stream in streams { stream.send("terminals", event) }
    }

    // MARK: - Static files

    private func staticFile(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else { return .error(405, "Use GET.") }
        if request.path == "/theme.css" {
            return .file(Data(RemoteTheme.css(PaletteCenter.shared.palette).utf8), contentType: "text/css; charset=utf-8")
        }
        guard let webRoot else { return .error(503, "The web app is missing from this build.") }
        let relative = request.path == "/" ? "index.html" : String(request.path.drop(while: { $0 == "/" }))
        let root = webRoot.standardizedFileURL
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return .error(404, "Not found.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = try? Data(contentsOf: url) else {
            return .error(404, "Not found.")
        }
        let cache = relative.hasPrefix("vendor/") ? "public, max-age=604800" : "no-cache"
        var response = HTTPResponse.file(data, contentType: Self.contentType(url.pathExtension), cache: cache)
        if relative == "sw.js" { response.headers.append(("Service-Worker-Allowed", "/")) }
        if url.pathExtension.lowercased() == "html" { response.headers.append(("Content-Security-Policy", Self.contentSecurityPolicy)) }
        return response
    }

    static func contentType(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "webmanifest": "application/manifest+json"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "ico": "image/x-icon"
        case "txt", "md": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

/// A thread as the web app's inbox shows it (contract: `ThreadSummary`).
struct ThreadSummary: Encodable, Sendable {
    var id: String
    var projectID: String?
    var title: String
    var status: String
    var workingSince: Date?
    var section: String
    var pinned: Bool
    var settled: Bool
    var activityDate: Date
    var updatedAt: Date
    var branch: String?
    var worktree: Bool
    var model: ModelSelection
    var runtimeMode: RuntimeMode
    var isRunning: Bool
    var preview: String?
    var teammate: String?

    @MainActor
    init(_ thread: AgentThread, engine: AgentEngine) {
        id = thread.id
        projectID = thread.projectID
        title = thread.title
        switch ThreadStatus.of(thread) {
        case .approval: status = "approval"
        case .input: status = "input"
        case let .working(since):
            status = "working"
            workingSince = since
        case .failed: status = "failed"
        case .done: status = "done"
        case .idle: status = "idle"
        }
        section = InboxSection.of(thread)?.rawValue ?? (thread.teammate != nil ? "team" : "archived")
        pinned = thread.pinnedAt != nil
        settled = thread.settledAt != nil
        activityDate = thread.activityDate
        updatedAt = thread.updatedAt
        branch = thread.branch
        worktree = thread.worktreePath != nil
        model = thread.modelSelection
        runtimeMode = thread.runtimeMode
        isRunning = thread.isRunning
        preview = Self.preview(thread)
        teammate = thread.teammate?.name
    }

    /// The last final answer, else the last user message, on one line (≤ 160 characters).
    static func preview(_ thread: AgentThread) -> String? {
        var text: String?
        for turn in thread.turns.reversed() {
            for item in turn.items.reversed() {
                if case let .assistantMessage(answer, isFinal) = item.kind, isFinal, !answer.isEmpty {
                    text = answer
                    break
                }
            }
            if text != nil { break }
        }
        let source = text ?? thread.turns.last?.userMessage.text
        guard let source else { return nil }
        let line = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}
