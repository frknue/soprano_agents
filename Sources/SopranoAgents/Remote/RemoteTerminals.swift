import Foundation
import SopranoAgentsCore
import SwiftTerm

/// The phone's terminals: login shells (SwiftTerm `LocalProcess`, no view) in a thread's working
/// directory, separate from the Mac's terminal views. Each keeps the last `scrollbackLimit`
/// bytes of output, which every new output stream gets first. A shell that exits stays listed
/// (not running) until it is closed; a deleted thread's terminals end.
@MainActor
final class RemoteTerminals {
    struct Info: Encodable, Sendable, Equatable {
        var id: String
        var threadID: String
        var title: String
        var running: Bool
    }

    static let scrollbackLimit = 256 << 10

    /// Touched only on the main actor: the process calls back on the main queue and the
    /// delegate methods hop there.
    private final class Session: LocalProcessDelegate, @unchecked Sendable {
        let id: String
        let threadID: String
        let title: String
        var process: LocalProcess!
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        var scrollback = Data()
        var running = true
        var exitCode: Int32?
        var streams: [EventStream] = []
        weak var owner: RemoteTerminals?

        init(id: String, threadID: String, title: String) {
            self.id = id
            self.threadID = threadID
            self.title = title
        }

        nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            Task { @MainActor in self.owner?.exited(self.id, code: exitCode) }
        }

        nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
            let data = Data(slice)
            Task { @MainActor in self.owner?.received(data, from: self.id) }
        }

        nonisolated func getWindowSize() -> winsize {
            MainActor.assumeIsolated { size }
        }
    }

    private let engine: AgentEngine
    private var sessions: [String: Session] = [:]
    private var numbers: [String: Int] = [:]
    /// The terminal list of a thread changed.
    var onChange: ((String) -> Void)?
    /// The login shell to start (`$SHELL`, else zsh). Tests use `/bin/sh`.
    var shell: () -> String = {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    init(engine: AgentEngine) {
        self.engine = engine
        engine.addObserver(self) { [weak self] event in
            if event == .threadListChanged { self?.pruneDeletedThreads() }
        }
    }

    func exists(_ id: String) -> Bool { sessions[id] != nil }

    func list(threadID: String) -> [Info] {
        sessions.values.filter { $0.threadID == threadID }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(info)
    }

    /// Starts a login shell in the thread's working directory.
    func create(threadID: String, cols: Int, rows: Int) throws -> Info {
        guard let thread = engine.thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let cwd = engine.workingDirectory(for: thread)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.message("The thread's folder \(cwd) doesn't exist, so no terminal can start there.")
        }
        let number = (numbers[threadID] ?? 0) + 1
        numbers[threadID] = number
        let session = Session(id: UUID().uuidString, threadID: threadID, title: "Phone \(number)")
        session.owner = self
        session.size = Self.size(cols: cols, rows: rows)
        session.process = LocalProcess(delegate: session, dispatchQueue: .main)
        sessions[session.id] = session
        let shell = shell()
        session.process.startProcess(
            executable: shell,
            args: ["-l"],
            environment: ThreadTerminalStore.environment(),
            execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
            currentDirectory: cwd
        )
        onChange?(threadID)
        return info(session)
    }

    /// Streams the terminal's output: its scrollback, then everything new, then `exit`.
    func attach(_ id: String, stream: EventStream) -> Bool {
        guard let session = sessions[id] else { return false }
        if !session.scrollback.isEmpty { stream.send("output", ["data": session.scrollback.base64EncodedString()]) }
        if !session.running {
            stream.send("exit", ExitEvent(code: session.exitCode))
            stream.close()
            return true
        }
        session.streams.append(stream)
        stream.onClose { [weak self] in
            self?.sessions[id]?.streams.removeAll { $0 === stream }
        }
        return true
    }

    func input(_ id: String, text: String) -> Bool {
        guard let session = sessions[id], session.running else { return false }
        session.process.send(data: ArraySlice(Array(text.utf8)))
        return true
    }

    func resize(_ id: String, cols: Int, rows: Int) -> Bool {
        guard let session = sessions[id] else { return false }
        session.size = Self.size(cols: cols, rows: rows)
        if session.running, session.process.childfd >= 0 {
            var size = session.size
            _ = ioctl(session.process.childfd, TIOCSWINSZ, &size)
        }
        return true
    }

    func close(_ id: String) -> Bool {
        guard let session = sessions.removeValue(forKey: id) else { return false }
        end(session)
        onChange?(session.threadID)
        return true
    }

    func closeAll() {
        for session in sessions.values { end(session) }
        sessions.removeAll()
    }

    // MARK: - Process events

    private func received(_ data: Data, from id: String) {
        guard let session = sessions[id] else { return }
        session.scrollback.append(data)
        if session.scrollback.count > Self.scrollbackLimit {
            session.scrollback.removeFirst(session.scrollback.count - Self.scrollbackLimit)
        }
        let event = ["data": data.base64EncodedString()]
        for stream in session.streams { stream.send("output", event) }
    }

    private func exited(_ id: String, code: Int32?) {
        guard let session = sessions[id], session.running else { return }
        session.running = false
        session.exitCode = code
        for stream in session.streams {
            stream.send("exit", ExitEvent(code: code))
            stream.close()
        }
        session.streams.removeAll()
        onChange?(session.threadID)
    }

    private struct ExitEvent: Encodable {
        var code: Int32?
    }

    private func end(_ session: Session) {
        for stream in session.streams { stream.close() }
        session.streams.removeAll()
        guard session.running else { return }
        session.running = false
        let pid = session.process.shellPid
        if pid > 0 { kill(pid, SIGHUP) }
        session.process.terminate()
        // The process monitor goes with the `LocalProcess`, so nothing else waits for the shell.
        if pid > 0 { ThreadTerminalStore.reap(pid) }
    }

    private func pruneDeletedThreads() {
        let live = Set(engine.threads.map(\.id))
        for session in sessions.values where !live.contains(session.threadID) {
            sessions[session.id] = nil
            end(session)
        }
    }

    private func info(_ session: Session) -> Info {
        Info(id: session.id, threadID: session.threadID, title: session.title, running: session.running)
    }

    private static func size(cols: Int, rows: Int) -> winsize {
        winsize(ws_row: UInt16(clamping: max(2, rows)), ws_col: UInt16(clamping: max(10, cols)), ws_xpixel: 0, ws_ypixel: 0)
    }
}
