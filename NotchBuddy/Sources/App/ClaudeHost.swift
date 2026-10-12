import AppKit

// MARK: - ClaudeHost
//
// The *host* a Claude Code session runs in — Orca, Warp, VS Code — read from
// the hook payload's term_program / bundle_id. This is a different axis from
// the agent itself (Claude Code, Gemini, Codex), which the pill catalog names.

struct ClaudeHost: Equatable {
    /// Orca's bundle id. Also how a session discovered by the process scan is
    /// identified as Orca-hosted: Orca injects `ORCA_PANE_KEY` into every
    /// process it spawns, so holding that variable *is* the evidence.
    static let orcaBundleId = "com.stablyai.orca"
    let bundleId: String
    let name: String

    /// UserDefaults key: show terminal sessions' questions and permission requests in the
    /// notch (they then wait for the notch). Off by default: the terminal asks itself.
    static let terminalCardsKey = "terminalCardsEnabled"
    static var terminalCardsEnabled: Bool { UserDefaults.standard.bool(forKey: terminalCardsKey) }

    /// Terminals accepted for Claude Code sessions. Keyed by bundle id; the second
    /// table maps TERM_PROGRAM for hooks that run without __CFBundleIdentifier.
    private static let terminals: [String: String] = [
        "dev.warp.Warp-Stable":       "Warp",
        "dev.warp.Warp-Preview":      "Warp",
        "com.apple.Terminal":         "Terminal",
        "com.googlecode.iterm2":      "iTerm",
        "com.mitchellh.ghostty":      "Ghostty",
        "net.kovidgoyal.kitty":       "kitty",
        "org.alacritty":              "Alacritty",
        "com.github.wez.wezterm":     "WezTerm",
        "co.zeit.hyper":              "Hyper",
        "dev.zed.Zed":                "Zed",
        "com.cmuxterm.app":           "cmux",    // sets TERM_PROGRAM=ghostty: the bundle id decides
        orcaBundleId:                 "Orca",
    ]
    private static let termPrograms: [String: String] = [
        "warpterminal":   "dev.warp.Warp-Stable",
        "apple_terminal": "com.apple.Terminal",
        "iterm.app":      "com.googlecode.iterm2",
        "ghostty":        "com.mitchellh.ghostty",
        "kitty":          "net.kovidgoyal.kitty",
        "alacritty":      "org.alacritty",
        "wezterm":        "com.github.wez.wezterm",
        "hyper":          "co.zeit.hyper",
        "zed":            "dev.zed.Zed",
    ]

    /// The terminal a session runs in, or nil when it isn't a known terminal.
    static func terminal(termProgram: String, bundleId: String) -> ClaudeHost? {
        if let name = terminals[bundleId] { return ClaudeHost(bundleId: bundleId, name: name) }
        if let id = termPrograms[termProgram.lowercased()], let name = terminals[id] {
            return ClaudeHost(bundleId: id, name: name)
        }
        return nil
    }

    /// Host apps that are not terminals. Deliberately a separate table from
    /// `terminals`: a session's *agent* (Claude Code, Gemini, Codex) is named by
    /// the pill catalog, while this is the *app the session runs in*. Folding
    /// the two together is what let a nil host silently read as "VS Code".
    private static let editors: [String: String] = [
        "com.microsoft.VSCode":           "VS Code",
        "com.microsoft.VSCodeInsiders":   "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92":  "Cursor",
        "com.cursor.Cursor":              "Cursor",
    ]

    /// The host app's name, or nil when we were never told.
    ///
    /// Returning nil is the point. This used to answer "VS Code" for anything
    /// unrecognised, reasoning that a session with no terminal must be in an
    /// editor — right for editor sessions only by coincidence, and wrong for
    /// everything else, including every session found by the process scan.
    static func name(for hostBundleId: String?) -> String? {
        guard let id = hostBundleId, !id.isEmpty else { return nil }
        return terminals[id] ?? editors[id]
    }

    /// How to label where a session runs, shared by the session pill's subtitle
    /// and the chat's host chip so the two can't drift apart.
    ///
    /// The host when we know it, the working folder when we don't — never a
    /// guess. Holds for scanned and hook-created sessions alike: a scan simply
    /// has no host information at all.
    static func label(for session: ClaudeSession) -> String {
        if let host = name(for: session.hostApp ?? session.sessionBundleId) { return host }
        return URL(fileURLWithPath: session.cwd).lastPathComponent
    }

    /// Brings the session's terminal forward (launching it if needed). false when not a terminal host.
    @discardableResult
    static func activate(_ hostBundleId: String?) -> Bool {
        guard let id = hostBundleId, terminals[id] != nil else { return false }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
        return true
    }
}
