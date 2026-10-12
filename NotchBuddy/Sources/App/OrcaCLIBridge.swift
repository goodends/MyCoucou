import Foundation

// MARK: - OrcaCLIBridge
//
// Thin wrapper over the `orca` CLI shipped inside Orca.app. We shell out to
// `orca terminal … --json` rather than speaking Orca's unix-socket protocol
// directly: the CLI handles auth-token discovery, transport selection and
// capability negotiation for us.
//
// Scope: this exists so "Open terminal" can jump to the exact Orca terminal
// tab hosting a session, instead of only bringing the Orca app forward.
// Orca knows nothing about Claude Code running in Terminal.app / iTerm2 /
// the VS Code extension, so those keep their existing behaviour.

struct OrcaTerminalInfo: Decodable, Identifiable {
    let handle: String
    let worktreeId: String?
    let worktreePath: String?
    let title: String?
    let lastOutputAt: Double?

    var id: String { handle }

    /// Orca encodes the worktree path into `worktreeId` as `<uuid>::<path>`.
    var path: String? {
        if let p = worktreePath, !p.isEmpty { return p }
        guard let id = worktreeId, let sep = id.range(of: "::") else { return nil }
        return String(id[sep.upperBound...])
    }
}

struct OrcaTerminalList: Decodable {
    let terminals: [OrcaTerminalInfo]
}

/// An Orca-managed worktree — the unit `terminal create` can spawn into.
/// `orca terminal create --worktree path:<p>` rejects anything Orca doesn't
/// manage (verified: a plain directory returns `selector_not_found`), so this
/// list is also the set of folders a user can actually start an agent in.
struct OrcaWorktree: Decodable, Identifiable {
    let id: String          // "<uuid>::<path>"
    let path: String
    let displayName: String?
    let isArchived: Bool?

    /// What the picker shows. Deliberately the folder's own name rather than
    /// Orca's `displayName`: for plain checkouts Orca reports `displayName:
    /// "main"` (the branch), so four unrelated projects all render as "main"
    /// and the list is unusable. The basename is unique and says which repo it is.
    var name: String {
        let base = URL(fileURLWithPath: path).lastPathComponent
        if !base.isEmpty { return base }
        if let n = displayName, !n.isEmpty { return n }
        return path
    }
}

struct OrcaWorktreeList: Decodable {
    let worktrees: [OrcaWorktree]
}

/// `terminal create` result — the handle is what `send` needs.
struct OrcaTerminalCreateResult: Decodable {
    struct Terminal: Decodable { let handle: String }
    let terminal: Terminal
}

/// `terminal show` readiness fields. `agentIdentity` turns non-null once the
/// agent process in the PTY is actually up; `agentWait` is non-null while Orca
/// still considers the agent starting, so both must clear before we type.
struct OrcaTerminalAgentStatus: Decodable {
    let agentIdentity: String?
    let agentWait: Bool?
}

/// `terminal send` result: the input-acceptance verdict plus, when the host
/// supports it, a prompt receipt whose `stages` say whether the agent
/// actually took the prompt.
struct OrcaSendReceipt: Decodable {
    let accepted: Bool?
    let bytesWritten: Int?
    let prompt: OrcaPromptReceipt?
}

struct OrcaPromptReceipt: Decodable {
    let stages: [String]?
}

actor OrcaCLIBridge {
    static let shared = OrcaCLIBridge()

    static var cliURL: URL {
        URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cliURL.path)
    }

    // MARK: - Process plumbing

    /// Run `orca <args> --json` and return the raw stdout bytes. Returning
    /// `Data` (rather than a decoded dictionary) keeps the value Sendable so
    /// it can cross the actor boundary under strict concurrency.
    ///
    /// We don't wait for the Orca CLI process to exit. The CLI holds the
    /// process alive for ~8 s after the receipt is already on stdout (likely
    /// polling for `turn_started` or doing IPC cleanup), and the data we
    /// need is fully written as soon as the receipt is ready. We read
    /// stdout, return the first complete JSON object (terminated by `\n`),
    /// then SIGTERM the process so it stops blocking the caller.
    private nonisolated func runRaw(_ args: [String], timeout: TimeInterval = 20) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let state = RunState()
            let proc = Process()
            proc.executableURL = Self.cliURL
            proc.arguments = args + ["--json"]
            let stdout = Pipe()
            proc.standardOutput = stdout
            proc.standardError = Pipe()
            proc.environment = ProcessInfo.processInfo.environment

            stdout.fileHandleForReading.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty { return }
                state.append(chunk)
                if state.takeIfComplete() {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    let data = state.drain()
                    if proc.isRunning { proc.terminate() }
                    cont.resume(returning: data)
                }
            }
            proc.terminationHandler = { p in
                stdout.fileHandleForReading.readabilityHandler = nil
                if state.alreadyResumed { return }
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? state.drain()
                if p.terminationStatus != 0, data.isEmpty {
                    let err = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: OrcaCLIError.exited(code: p.terminationStatus, stderr: err))
                } else if data.isEmpty {
                    cont.resume(throwing: OrcaCLIError.emptyOutput)
                } else {
                    cont.resume(returning: data)
                }
            }
            do {
                try proc.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning { proc.terminate() }
            }
        }
    }

    /// Thread-safe buffer for runRaw's stdout reader. Orca CLI emits one
    /// newline-terminated JSON object per invocation, so "complete" is just
    /// "we have at least one \\n".
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var resumed = false
        var alreadyResumed: Bool { lock.withLock { resumed } }
        func append(_ data: Data) { lock.withLock { buffer.append(data) } }
        /// Returns true the first time a complete line is in the buffer and
        /// marks resumed so subsequent calls / the termination handler know
        /// to stay quiet.
        func takeIfComplete() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            guard buffer.contains(0x0A) else { return false }
            resumed = true
            return true
        }
        func drain() -> Data {
            lock.withLock {
                let copy = buffer
                buffer.removeAll(keepingCapacity: false)
                return copy
            }
        }
    }

    private nonisolated func run(_ args: [String], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let data = try await runRaw(args, timeout: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OrcaCLIError.notJSON(String(data: data, encoding: .utf8) ?? "")
        }
        return obj
    }

    // MARK: - Public surface

    /// Every Orca-managed terminal currently alive.
    func terminals() async throws -> [OrcaTerminalInfo] {
        let resp = try await run(["terminal", "list"])
        guard resp["ok"] as? Bool == true,
              let result = resp["result"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: result)
        else { throw OrcaCLIError.badShape("missing result: \(resp)") }
        return try JSONDecoder().decode(OrcaTerminalList.self, from: data).terminals
    }

    /// Activate the Orca window and switch to `handle`'s terminal tab.
    func focus(handle: String) async throws {
        _ = try await run(["terminal", "switch", "--terminal", handle])
    }

    /// Type `text` into `handle`'s agent and submit it (as if the user
    /// pressed Enter). Blocks up to `waitSubmit` seconds for Orca to observe
    /// the agent accept the prompt.
    ///
    /// Returns true on `submission_observed` / `turn_started` (agent took
    /// the prompt) or `input_accepted` (bytes reached the PTY and the
    /// Claude process read them). An idle session's `turn_started` often
    /// arrives well after the prompt is already accepted, and the wall
    /// clock is dominated by Orca CLI's own startup/teardown (~7–8 s),
    /// not by `waitSubmit` — so defaulting to 2 s trades a slightly higher
    /// "input_accepted only" rate for a noticeably snappier send.
    @discardableResult
    func send(handle: String, text: String, waitSubmit: Int = 2) async throws -> Bool {
        let resp = try await run([
            "terminal", "send",
            "--terminal", handle,
            "--text", text,
            "--enter",
            "--wait-submit", String(waitSubmit),
        ])
        guard resp["ok"] as? Bool == true,
              let result = resp["result"] as? [String: Any],
              let sendDict = result["send"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: sendDict),
              let receipt = try? JSONDecoder().decode(OrcaSendReceipt.self, from: data)
        else { throw OrcaCLIError.badShape("send returned no receipt: \(resp)") }
        let stages = Set(receipt.prompt?.stages ?? [])
        return !stages.isDisjoint(with: ["submission_observed", "turn_started", "input_accepted"])
    }

    /// Resolve `cwd` to the Orca terminal hosting that session. Picks the
    /// most recently active agent-shaped terminal in the matching worktree —
    /// that is almost always the tab the user is looking at.
    ///
    /// Deliberately does NOT fall back to an unrelated worktree's terminal:
    /// jumping to some other project's tab is worse than not jumping at all.
    func handle(forCwd cwd: String) async -> String? {
        guard let ts = try? await terminals() else { return nil }
        let agents = ts.filter { t in
            guard let p = t.path, !p.isEmpty else { return false }
            guard cwd == p || cwd.hasPrefix(p + "/") else { return false }
            return isAgentTerminal(t)
        }
        return agents.max(by: { ($0.lastOutputAt ?? 0) < ($1.lastOutputAt ?? 0) })?.handle
    }

    // MARK: - Starting a fresh agent

    /// Orca-managed worktrees, non-archived first. This is the project picker's
    /// backing list — the only folders `terminal create` will accept.
    func worktrees() async throws -> [OrcaWorktree] {
        let resp = try await run(["worktree", "list"])
        guard resp["ok"] as? Bool == true,
              let result = resp["result"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: result)
        else { throw OrcaCLIError.badShape("missing result: \(resp)") }
        let all = try JSONDecoder().decode(OrcaWorktreeList.self, from: data).worktrees
        return all
            .filter { $0.isArchived != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Spawn a terminal running `command` in `worktreePath` and return its handle.
    ///
    /// Deliberately passes neither `--title` nor `--focus`:
    /// • no title — Orca derives it from what the PTY is actually running, and
    ///   that title is what marks the terminal as an agent session; pinning our
    ///   own would hide the agent from every title-based check.
    /// • no `--focus` — it makes the CLI wait for the Orca UI to adopt the
    ///   terminal, which intermittently times out *after* the terminal has
    ///   already spawned (leaking a session we never got a handle for). The
    ///   terminal is created visible either way; callers switch to it with
    ///   `focus(handle:)`, which is a separate call we can fail cleanly.
    func createTerminal(worktreePath: String, command: String) async throws -> String {
        let resp = try await run([
            "terminal", "create",
            "--worktree", "path:\(worktreePath)",
            "--command", command,
        ])
        guard resp["ok"] as? Bool == true,
              let result = resp["result"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: result),
              let created = try? JSONDecoder().decode(OrcaTerminalCreateResult.self, from: data)
        else { throw OrcaCLIError.badShape("create returned no handle: \(resp)") }
        return created.terminal.handle
    }

    /// Wait until the agent in `handle` is up and accepting input.
    ///
    /// `terminal create --command claude` returns as soon as the PTY exists,
    /// which is well before Claude has rendered. Typing into that window sends
    /// the text to the shell prompt instead of to Claude, so the send is gated
    /// on Orca reporting a live agent. Returns false on timeout — the caller
    /// reports "not sent" rather than firing text at a shell.
    @discardableResult
    func waitForAgent(handle: String, timeout: TimeInterval = 25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = try? await agentStatus(handle: handle),
               status.agentIdentity != nil, status.agentIdentity != "",
               status.agentWait != true {
                // Orca can report the agent up a beat before it reads the PTY;
                // give it one more poll so the first prompt isn't swallowed.
                try? await Task.sleep(nanoseconds: 400_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func agentStatus(handle: String) async throws -> OrcaTerminalAgentStatus {
        let resp = try await run(["terminal", "show", "--terminal", handle])
        guard resp["ok"] as? Bool == true,
              let result = resp["result"] as? [String: Any],
              let terminal = result["terminal"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: terminal)
        else { throw OrcaCLIError.badShape("show returned no terminal: \(resp)") }
        return try JSONDecoder().decode(OrcaTerminalAgentStatus.self, from: data)
    }

    private func isAgentTerminal(_ t: OrcaTerminalInfo) -> Bool {
        let title = t.title ?? ""
        // Orca marks agent sessions with ✳ / ◐ / ◑. "启动APP" titles are
        // plain shells, not agent sessions.
        return title.contains("✳") || title.contains("◐") || title.contains("◑")
            || title.lowercased().contains("claude")
            || title.lowercased().contains("codex")
    }
}

enum OrcaCLIError: Error, CustomStringConvertible {
    case exited(code: Int32, stderr: String)
    case emptyOutput
    case notJSON(String)
    case badShape(String)

    var description: String {
        switch self {
        case .exited(let c, let s): return "orca exited \(c): \(s.prefix(200))"
        case .emptyOutput:          return "orca produced no output"
        case .notJSON(let s):       return "orca output was not JSON: \(s.prefix(200))"
        case .badShape(let s):      return "orca protocol error: \(s.prefix(200))"
        }
    }
}
