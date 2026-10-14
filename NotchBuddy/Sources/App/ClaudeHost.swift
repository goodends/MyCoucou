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

    // MARK: - Which hosts the notch lists

    /// Which way the ticked rows read. The setting is one list of apps and one
    /// question — "these" or "everything but these" — so the mode is stored
    /// next to the list rather than being spelled out by the list's contents,
    /// which would leave no room for an exclusion list.
    enum FilterMode: String {
        /// The ticked ids are the ones we show. The default: the app ships for
        /// Orca, and a session opened in a plain terminal is noise.
        case some
        /// The ticked ids are the ones we hide; everything else shows.
        case all
    }

    /// UserDefaults keys. `hostFilterIdsKey` holds the ticked rows, read as the
    /// shown hosts in `.some` and the excluded ones in `.all`.
    static let hostFilterModeKey = "claudeHostFilterMode"
    static let hostFilterIdsKey = "claudeHostFilterIds"

    /// Stands in for a session whose host we were never told — a scan whose
    /// parent chain didn't resolve, a hook payload with no bundle id. It gets
    /// its own row in Settings → Apps, so those sessions can be hidden too
    /// instead of being un-hideable.
    static let unknownHostId = "unknown"

    /// One row in Settings → Apps. `group` is what the list is split by: a flat
    /// run of sixteen boxes told the reader nothing about why Terminal sits
    /// next to Kitty.
    struct Host: Identifiable {
        enum Group: Int, CaseIterable {
            /// What we ship for — one row, so no header of its own.
            case orca
            case terminal
            case editor
            /// A host we couldn't name. One row, so no header either.
            case other
        }
        let id: String
        let name: String
        let group: Group
    }

    /// Every host the user can tick, in reading order: Orca first (the app we
    /// ship for), then the terminals, then the editors, unknown last.
    ///
    /// Sorted by display name because both tables are unordered — a picker that
    /// reshuffled between launches would be its own bug — and deduped by name
    /// because Cursor is reachable under two bundle ids and must be one row.
    static var allHosts: [Host] {
        var seen: Set<String> = ["Orca"]
        var rows: [Host] = [Host(id: orcaBundleId, name: "Orca", group: .orca)]
        for (table, group) in [(terminals, Host.Group.terminal), (editors, Host.Group.editor)] {
            for (id, name) in table.sorted(by: { $0.value < $1.value }) where !seen.contains(name) {
                seen.insert(name)
                rows.append(Host(id: id, name: name, group: group))
            }
        }
        rows.append(Host(id: unknownHostId,
                         name: String(localized: "Other", defaultValue: "Other"),
                         group: .other))
        return rows
    }

    /// The stored mode. `.some` unless the user has said otherwise — a missing
    /// key and a malformed one both fall back to the shipped default rather
    /// than to a state nobody asked for.
    static var storedMode: FilterMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: hostFilterModeKey),
                  let mode = FilterMode(rawValue: raw)
            else { return .some }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: hostFilterModeKey) }
    }

    /// The ticked ids. Orca alone on a fresh install; a *written* empty set is
    /// a choice (show nothing, or exclude nothing under `.all`) and is kept
    /// distinct from an absent key, which means the default.
    static var storedIds: Set<String> {
        get {
            guard let saved = UserDefaults.standard.stringArray(forKey: hostFilterIdsKey) else {
                return [orcaBundleId]
            }
            return Set(saved)
        }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: hostFilterIdsKey) }
    }

    /// The host a session belongs to: the terminal the scan or hook named, else
    /// the app the hook itself ran in.
    ///
    /// Anything not in the tables above — a session we never learned the host
    /// of, or an app like the Claude desktop build that has no row — lands in
    /// the unknown bucket rather than keeping its own bundle id. Returning the
    /// raw id would leave such a session matched by no checkbox at all: gone
    /// from the list, and no way to bring it back.
    static func hostId(for session: ClaudeSession) -> String {
        hostId(hostApp: session.hostApp, bundleId: session.sessionBundleId)
    }

    /// Same, from a hook payload's two host fields, for the paths that must
    /// decide before any `ClaudeSession` exists.
    static func hostId(hostApp: String?, bundleId: String?) -> String {
        for id in [hostApp, bundleId] {
            if let id, !id.isEmpty {
                return name(for: id) != nil ? id : unknownHostId
            }
        }
        return unknownHostId
    }

    /// Whether a host id is shown, given a filter. Pure, and the only place the
    /// two modes are spelled out, so the view layer and the hook gates can't
    /// disagree about what a tick means.
    ///
    /// Under `.all` this is an exclusion test, which is the reason the mode is
    /// stored rather than encoded: a host with no row of its own still shows,
    /// because nothing can have excluded it.
    static func isVisible(hostId: String, mode: FilterMode, ids: Set<String>) -> Bool {
        switch mode {
        case .some: return ids.contains(hostId)
        case .all:  return !ids.contains(hostId)
        }
    }

    /// Same, reading the stored filter — for the hook gates, which have no view
    /// state to pass.
    static func isVisibleHostId(_ id: String) -> Bool {
        isVisible(hostId: id, mode: storedMode, ids: storedIds)
    }

    /// Same, for a host read off an `AgentTask` — the pill, which is what the
    /// notch draws. A pill with no host recorded at all is an agent that isn't
    /// a Claude Code session (Codex, Copilot…), so it shows regardless: here
    /// "unknown" must not be read as "the user excluded it".
    static func isVisibleHost(hostApp: String?, bundleId: String?) -> Bool {
        let recorded = !(hostApp ?? "").isEmpty || !(bundleId ?? "").isEmpty
        guard recorded else { return true }
        return isVisibleHostId(hostId(hostApp: hostApp, bundleId: bundleId))
    }

    /// Whether a session runs in Orca — the only host with an Orca terminal to
    /// switch to.
    ///
    /// Goes through `hostId(for:)` rather than reading `hostApp` directly,
    /// because an editor session names no terminal: VS Code and Cursor leave
    /// `hostApp` nil and put their identity in `sessionBundleId`. A check that
    /// only looked at `hostApp` therefore saw "unknown" for every editor
    /// session and waved it through to the cwd lookup, which jumped to whatever
    /// Orca tab happened to share the folder.
    ///
    /// A session with no host recorded is not Orca either: we cannot place it,
    /// and guessing lands on an unrelated agent.
    static func runsInOrca(_ session: ClaudeSession) -> Bool {
        hostId(for: session) == orcaBundleId
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
