import Foundation

// MARK: - ClaudeProcessScanner
//
// Finds Claude Code CLI processes that were already running when Coucou
// launched. The hook pipe only reports sessions that do something *after* we
// start listening, so without this a session opened beforehand stays invisible
// until it happens to fire an event.
//
// What a scan can and can't know:
//   • pid and cwd are exact — `ps` gives the tty and executable, `lsof` gives
//     the cwd. No guessing.
//   • the session id is NOT recoverable. Claude Code keeps it in neither argv
//     nor the environment (checked: argv is literally "Claude", the env carries
//     only Orca's ORCA_PANE_KEY) and it does not hold its transcript open, so
//     there is no pid → transcript mapping on disk. A scan therefore yields a
//     *provisional* session keyed by pid; AppState.upsertClaudeSession adopts it
//     the first time a hook event reports that same pid, which the relay now
//     sends on every event.
//   • editor-hosted sessions (VS Code extension, Claude Desktop's Code tab) run
//     inside the editor's own process. They are not separate entries in the
//     process table, so a scan cannot see them at all — they can only ever
//     appear through a hook event.

/// Claude Code's own live-session registry entry, `~/.claude/sessions/<pid>.json`.
/// One file per running process, removed when it exits — so this is exactly the
/// set of sessions alive right now, and it answers the one question the process
/// table can't: the session id. (Claude Code keeps the id in neither argv nor
/// the environment, which is why this file matters.) It also carries the
/// session's own name and whether it is busy.
struct ClaudeSessionDescriptor: Decodable {
    let pid: Int32?
    let sessionId: String?
    let cwd: String?
    let name: String?
    let status: String?      // "idle" | "busy" | …
    let entrypoint: String?
    let startedAt: Double?   // epoch milliseconds
}

/// A Claude Code process we found, plus whatever the session registry could
/// tell us about it.
struct ScannedClaudeProcess {
    let pid: Int32
    let cwd: String
    /// Orca's pane identity (`tabId:leafId`) if this session runs in Orca —
    /// the only way to tell two sessions in one folder apart. nil for a
    /// session launched in a plain terminal.
    let paneKey: String?
    /// Bundle id of the app this session runs in, when the parent chain says
    /// so. nil for a session whose host we cannot establish.
    let hostBundleId: String?
    /// nil when this Claude Code is too old to write the registry, or the file
    /// is unreadable. The session then stays provisional until a hook adopts it.
    let descriptor: ClaudeSessionDescriptor?
}

enum ClaudeProcessScanner {
    /// Blocking: runs `ps` plus one `lsof` per candidate (~20 ms each), so
    /// callers must keep it off the main thread. Returns [] rather than
    /// throwing — a failed scan just means the island falls back to hooks.
    static func scan() -> [ScannedClaudeProcess] {
        guard let ps = run("/bin/ps", ["-Ao", "pid=,tty=,comm="]) else { return [] }

        var candidates: [(pid: Int32, tty: String)] = []
        for line in ps.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let tty = parts[1].trimmingCharacters(in: .whitespaces)
            // A controlling terminal is what separates the CLI from the Claude
            // desktop app, which also runs a process named "Claude".
            guard tty != "??" else { continue }
            let comm = parts[2].trimmingCharacters(in: .whitespaces).lowercased()
            guard comm == "claude" || comm == "claude.exe" else { continue }
            candidates.append((pid, tty))
        }

        return candidates.compactMap { candidate in
            guard let (exe, cwd) = detail(pid: candidate.pid) else { return nil }
            guard let exe, let cwd, !cwd.isEmpty else { return nil }
            // The Claude desktop app runs a process named "Claude" too. It has
            // no controlling terminal, so the tty check above already excludes
            // it; this is the belt to that braces, and the only reliable shape
            // of the discriminator — matching the executable against a known
            // install path would be wrong, since a real CLI was found living at
            // a bare `/claude` with nothing identifying in the name.
            guard !exe.contains(".app/") else { return nil }
            let pane = paneKey(pid: candidate.pid)
            return ScannedClaudeProcess(pid: candidate.pid, cwd: cwd,
                                        paneKey: pane,
                                        hostBundleId: pane != nil ? nil : hostApp(of: candidate.pid),
                                        descriptor: descriptor(pid: candidate.pid))
        }
    }

    /// One `lsof -Fn` pass gives both the executable path and the working
    /// directory; `lsof -p` output is grouped as `p<pid>` then `f<type>` /
    /// `n<name>` pairs, so the `f` seen last tells us what the next `n` is.
    private static func detail(pid: Int32) -> (exe: String?, cwd: String?)? {
        guard let out = run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"]) else { return nil }
        var exe: String?
        var cwd: String?
        var type: String?
        for line in out.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "f": type = String(line.dropFirst())
            case "n":
                let name = String(line.dropFirst())
                if type == "cwd" { cwd = name }
                else if type == "txt" { exe = exe ?? name }
            default: break
            }
        }
        guard exe != nil || cwd != nil else { return nil }
        return (exe, cwd)
    }

    /// Orca injects `ORCA_PANE_KEY` into every agent it spawns, so the pane can
    /// be read straight out of the process's environment. nil for a session
    /// started in a plain terminal, which has no pane to identify.
    private static func paneKey(pid: Int32) -> String? {
        guard let out = run("/bin/ps", ["eww", "-p", String(pid)]) else { return nil }
        let prefix = "ORCA_PANE_KEY="
        for token in out.split(separator: " ") {
            if token.hasPrefix(prefix) {
                let value = String(token.dropFirst(prefix.count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Shells a terminal puts between the app and the agent. Skipped while
    /// walking up to find the host app.
private static let shells: Set<String> = ["sh", "zsh", "bash", "dash", "ksh", "login", "-zsh", "-bash", "-sh"]

/// The app a non-Orca Claude Code runs in, from its ancestry: climb past the
/// shells and the login session to the first non-shell ancestor, then read that
/// .app's bundle identifier. `claude → zsh → login → Terminal.app` is the
/// ordinary shape, so this is usually one or two steps.
///
/// Orca sessions never reach here — their pane key already answers it.
private static func hostApp(of pid: Int32) -> String? {
    guard let ps = run("/bin/ps", ["-Ao", "pid=,ppid=,comm="]) else { return nil }
    var parent: [Int32: Int32] = [:]
    var comm: [Int32: String] = [:]
    for line in ps.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let p = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
        parent[p] = pp
        comm[p] = String(parts[2])
    }
    var current = parent[pid] ?? 0
    for _ in 0..<8 {
        guard current > 1, let name = comm[current], let next = parent[current] else { return nil }
        let base = name.split(separator: "/").last.map(String.init) ?? name
        if !shells.contains(base) { return bundleId(ofExecutable: name) }
        current = next
    }
    return nil
}

/// Bundle identifier of the .app an executable lives in, read from its
/// Info.plist. Not cached: this runs at most a couple of times per scan, off
/// the main thread, and a shared cache would be mutable global state.
private static func bundleId(ofExecutable path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    let appURL = URL(fileURLWithPath: String(path[path.startIndex..<range.upperBound]))
    return Bundle(url: appURL)?.bundleIdentifier
}

/// Claude Code's live-session registry for `pid`, if this version writes one.
/// Plain file read — no process spawn.
private static func descriptor(pid: Int32) -> ClaudeSessionDescriptor? {
    let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions/\(pid).json")
    guard let data = FileManager.default.contents(atPath: home.path) else {
        // Older Claude Code builds don't write these; the scan still finds the
        // process, it just stays provisional until a hook adopts it.
        return nil
    }
    return try? JSONDecoder().decode(ClaudeSessionDescriptor.self, from: data)
}

private static func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}