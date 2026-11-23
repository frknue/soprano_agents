import Foundation

/// The Agent Client Protocol (ACP) on a line transport: JSON-RPC 2.0, one message per line.
/// `request` sends `{jsonrpc, id, method, params}` and suspends until the response with that id
/// (`result`, or `error {code, message}` thrown as `ProviderError.rpc`). Everything the agent
/// sends on its own goes to `incoming` in arrival order: notifications (`session/update`) and
/// the agent's requests to the client (`session/request_permission`), answered with
/// `respond`. Lines that are not JSON objects are skipped.
///
/// A request sent with `ordered: true` (`session/prompt`) also puts its response on `incoming`,
/// behind the updates agy wrote before it: the awaiting caller and the `incoming` reader are
/// different tasks, so only `incoming` says whether the turn's last chunks have been read.
///
/// When the transport closes, waiting requests fail with `ProviderError.processExited` and
/// `incoming` ends with `.closed`.
public actor AcpClient {
    public enum Incoming: Sendable, Hashable {
        case notification(method: String, params: JSONValue)
        /// `id` is echoed in the answer; the agent picks its type (number or string).
        case request(id: JSONValue, method: String, params: JSONValue)
        /// The response of an `ordered` request: its `result`, or the error's message.
        case response(method: String, result: JSONValue?, error: String?)
        case closed(status: Int32, stderr: String)
    }

    public nonisolated let incoming: AsyncStream<Incoming>

    private let transport: any JSONLineTransport
    private let kind: ProviderKind
    private let incomingContinuation: AsyncStream<Incoming>.Continuation
    private var nextID = 1
    private var pending: [Int: (method: String, ordered: Bool, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var closedError: ProviderError?

    public init(transport: any JSONLineTransport, kind: ProviderKind = .antigravity) {
        self.transport = transport
        self.kind = kind
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .unbounded)
        Task { await self.readLoop() }
    }

    /// Sends a request and returns its `result` (`null` when absent). `ordered`: the response
    /// also goes to `incoming`.
    public func request(_ method: String, _ params: JSONValue = [:], ordered: Bool = false) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let line = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).jsonString()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if let closedError {
                    continuation.resume(throwing: closedError)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = (method, ordered, continuation)
                do {
                    try transport.send(line)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: ProviderError.notStarted)
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Sends a notification (no answer: `session/cancel`, Codex `initialized`).
    public func notify(_ method: String, _ params: JSONValue? = nil) throws {
        var payload: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { payload["params"] = params }
        try transport.send(JSONValue.object(payload).jsonString())
    }

    /// Answers an agent request with `result`.
    public func respond(to id: JSONValue, result: JSONValue) throws {
        try transport.send(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString())
    }

    /// Refuses an agent request (`-32601` for methods the client does not offer).
    public func respond(to id: JSONValue, errorCode: Int, message: String) throws {
        let error: JSONValue = ["code": .number(Double(errorCode)), "message": .string(message)]
        try transport.send(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": error]).jsonString())
    }

    public func close() {
        transport.close()
    }

    // MARK: - Reading

    private func readLoop() async {
        for await event in transport.incoming {
            switch event {
            case let .line(line):
                guard let message = try? JSONValue.parse(line), message.objectValue != nil else { continue }
                handle(message)
            case let .exited(status, stderr):
                let error = ProviderError.processExited(kind, status: status, stderr: stderr)
                closedError = error
                let waiting = pending.values
                pending.removeAll()
                for entry in waiting { entry.continuation.resume(throwing: error) }
                incomingContinuation.yield(.closed(status: status, stderr: stderr))
                incomingContinuation.finish()
                return
            }
        }
    }

    private func handle(_ message: JSONValue) {
        if let method = message["method"]?.stringValue {
            let params = message["params"] ?? .null
            if let id = message["id"], id != .null {
                incomingContinuation.yield(.request(id: id, method: method, params: params))
            } else {
                incomingContinuation.yield(.notification(method: method, params: params))
            }
            return
        }
        guard let id = message["id"]?.intValue, let entry = pending.removeValue(forKey: id) else { return }
        if let error = message["error"], error != .null {
            let code = error["code"]?.intValue ?? 0
            let text = error["message"]?.nonEmptyString ?? "\(kind.displayName) rejected \(entry.method)."
            let failure = ProviderError.rpc(method: entry.method, code: code, message: Self.detail(text, data: error["data"]))
            if entry.ordered { incomingContinuation.yield(.response(method: entry.method, result: nil, error: failure.localizedDescription)) }
            entry.continuation.resume(throwing: failure)
        } else {
            let result = message["result"] ?? .null
            if entry.ordered { incomingContinuation.yield(.response(method: entry.method, result: result, error: nil)) }
            entry.continuation.resume(returning: result)
        }
    }

    /// The error message, with `data.details` / string `data` when the agent adds one.
    private static func detail(_ message: String, data: JSONValue?) -> String {
        let extra = data?["details"]?.nonEmptyString ?? data?.nonEmptyString
        guard let extra, extra != message else { return message }
        return "\(message): \(extra)"
    }

    private func abandon(_ id: Int) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
