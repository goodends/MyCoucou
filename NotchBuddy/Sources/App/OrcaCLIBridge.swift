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
    private nonisolated func runRaw(_ args: [String], timeout: TimeInterval = 20) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = Self.cliURL
                proc.arguments = args + ["--json"]
                let stdout = Pipe()
                proc.standardOutput = stdout
                proc.standardError = Pipe()
                proc.environment = ProcessInfo.processInfo.environment

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                proc.terminationHandler = { p in
                    let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                    if p.terminationStatus != 0 {
                        let err = String(data: data, encoding: .utf8) ?? ""
                        cont.resume(throwing: OrcaCLIError.exited(code: p.terminationStatus, stderr: err))
                    } else if data.isEmpty {
                        cont.resume(throwing: OrcaCLIError.emptyOutput)
                    } else {
                        cont.resume(returning: data)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning { proc.terminate() }
                }
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
