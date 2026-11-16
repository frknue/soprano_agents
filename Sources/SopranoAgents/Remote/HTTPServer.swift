import Foundation
import Network

/// One parsed HTTP/1.1 request.
struct HTTPRequest: Sendable {
    var method: String
    /// Percent-decoded path without the query ("/api/threads/abc").
    var path: String
    var query: [String: String]
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data

    /// The path's segments ("/api/threads/abc" → ["api", "threads", "abc"]).
    var segments: [String] { path.split(separator: "/").map(String.init) }

    /// The bearer token of `Authorization: Bearer <token>`.
    var bearerToken: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        let token = value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Parses the head (request line and headers, without the blank line). nil when malformed.
    static func parseHead(_ head: String) -> (method: String, target: String, headers: [String: String])? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(parts[0]), String(parts[1]), headers)
    }

    /// Splits a request target into its decoded path and query items.
    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        return (path.isEmpty ? "/" : path, query)
    }
}

/// A complete response written in one go (`Connection: close`).
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        do {
            return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: try RemoteJSON.encoder.encode(value))
        } catch {
            return .error(500, "Could not encode the response: \(error.localizedDescription)")
        }
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    static let noContent = HTTPResponse(status: 204)

    static func file(_ data: Data, contentType: String, cache: String = "no-cache") -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", contentType), ("Cache-Control", cache)], body: data)
    }

    /// The bytes on the wire: status line, headers, `Content-Length`, `Connection: close`, body.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// What a route answers: a response, or a server-sent event stream it keeps writing to.
enum HTTPReply: Sendable {
    case response(HTTPResponse)
    case eventStream(@MainActor @Sendable (EventStream) -> Void)
}

/// JSON coding for the remote API: ISO 8601 dates.
enum RemoteJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// An open `text/event-stream` response. Writes go out in order on the connection's queue;
/// `onClose` handlers run once on the main actor when the client goes away or `close()` is called.
final class EventStream: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false
    private var closeHandlers: [@MainActor @Sendable () -> Void] = []

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Runs `handler` once the stream ends (at once when it already has).
    func onClose(_ handler: @escaping @MainActor @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if closed { return true }
            closeHandlers.append(handler)
            return false
        }
        if runNow { Task { @MainActor in handler() } }
    }

    fileprivate func start() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache, no-transform\r\nX-Accel-Buffering: no\r\nConnection: close\r\n\r\n"
        write(Data(head.utf8) + Data(": stream\n\n".utf8))
        watchForClose()
    }

    /// One event: `event: <name>` and the JSON-encoded `data` on one line.
    func send(_ name: String, _ value: some Encodable) {
        guard let data = try? RemoteJSON.encoder.encode(value), let json = String(data: data, encoding: .utf8) else { return }
        write(Data("event: \(name)\ndata: \(json)\n\n".utf8))
    }

    /// A comment line (keep-alive).
    func comment(_ text: String) {
        write(Data(": \(text)\n\n".utf8))
    }

    func close() {
        guard markClosed() else { return }
        connection.cancel()
    }

    private func write(_ data: Data) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    /// The client sends nothing after the request: any receive completion means it left.
    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.close() } else { self.watchForClose() }
        }
    }

    /// Returns true for the call that closed it.
    @discardableResult
    fileprivate func markClosed() -> Bool {
        let handlers: [@MainActor @Sendable () -> Void]
        lock.lock()
        if closed {
            lock.unlock()
            return false
        }
        closed = true
        handlers = closeHandlers
        closeHandlers = []
        lock.unlock()
        if !handlers.isEmpty { Task { @MainActor in for handler in handlers { handler() } } }
        return true
    }
}

/// A minimal HTTP/1.1 server on `127.0.0.1:<port>` (Network.framework). One request per
/// connection; the handler runs on the main actor. Bodies over `maxBodyBytes` get 413.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (HTTPRequest) async -> HTTPReply

    /// Large enough for photos and files the phone attaches (`POST /api/attachments`).
    static let maxBodyBytes = 25 << 20
    private static let maxHeadBytes = 64 << 10

    let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "soprano-agents.remote.http")
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// Starts listening; `stateChanged` reports `.ready`, or a failure (port in use).
    func start(stateChanged: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: stateChanged(.success(()))
            case let .failed(error): stateChanged(.failure(error))
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Stops listening; `released` runs (on the server's queue) once the port is free again.
    func stop(released: (@Sendable () -> Void)? = nil) {
        guard let listener else {
            released?()
            return
        }
        self.listener = nil
        if case .cancelled = listener.state {
            released?()
            return
        }
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { released?() }
        }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, into: RequestBuffer())
    }

    /// The bytes of one request so far; a reference, so large uploads are appended in place.
    private final class RequestBuffer: @unchecked Sendable {
        var data = Data()
    }

    private func receive(on connection: NWConnection, into buffer: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.data.append(data) }
            switch Self.parse(buffer.data) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, into: buffer)
                }
            case let .failed(response):
                self.finish(connection, with: response)
            case let .request(request):
                self.dispatch(request, on: connection)
            }
        }
    }

    enum ParseResult {
        case incomplete
        case failed(HTTPResponse)
        case request(HTTPRequest)
    }

    /// Parses a buffered request: head, then the body (`Content-Length` bytes, or a chunked one).
    static func parse(_ buffer: Data) -> ParseResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeadBytes ? .failed(.error(413, "Request head too large.")) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8),
              let (method, target, headers) = HTTPRequest.parseHead(head) else {
            return .failed(.error(400, "Malformed request."))
        }
        let rest = buffer[end.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(rest) {
            case .incomplete: return .incomplete
            case let .failed(response): return .failed(response)
            case let .body(data): body = data
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .failed(.error(400, "Bad Content-Length.")) }
            guard length <= maxBodyBytes else { return .failed(.error(413, "Request body too large.")) }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        let (path, query) = HTTPRequest.splitTarget(target)
        return .request(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    private enum Dechunked {
        case incomplete
        case failed(HTTPResponse)
        case body(Data)
    }

    /// Decodes `<hex size>\r\n<bytes>\r\n … 0\r\n\r\n` (extensions and trailers ignored).
    private static func dechunk(_ data: Data) -> Dechunked {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return .incomplete }
            let line = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16), size >= 0 else {
                return .failed(.error(400, "Bad chunk size."))
            }
            index = lineEnd.upperBound
            if size == 0 {
                return data.range(of: Data("\r\n\r\n".utf8), in: (index - 2)..<data.endIndex) == nil ? .incomplete : .body(body)
            }
            // Compared without adding: a size near Int.max must not overflow.
            guard size <= maxBodyBytes - body.count else { return .failed(.error(413, "Request body too large.")) }
            guard data.endIndex - index >= size + 2 else { return .incomplete }
            body.append(data[index..<(index + size)])
            index += size + 2
        }
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
        let handler = handler
        Task { @MainActor in
            switch await handler(request) {
            case let .response(response):
                self.finish(connection, with: response)
            case let .eventStream(open):
                let stream = EventStream(connection: connection)
                stream.start()
                open(stream)
            }
        }
    }

    private func finish(_ connection: NWConnection, with response: HTTPResponse) {
        connection.send(content: response.serialized, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
