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

    /// What the ticked rows mean, once the user has chosen to pick them by
    /// hand. Its own labelled state rather than something the checkboxes imply:
    /// an unticked box reads as "don't filter on this", never as "filter the
    /// other way round", so the direction has to be spelled out.
    enum FilterRule: String {
        /// Ticked ids are the ones we show; everything else is hidden.
        case showOnly
        /// Ticked ids are the ones we hide; everything else shows. The default,
        /// so that stepping into "custom" from "all" changes nothing until the
        /// user ticks something.
        case exclude
    }

    /// UserDefaults keys. `hostFilterIdsKey` holds the ticked rows, read through
    /// `hostFilterRuleKey`. `hostFilterShowsAllKey` records the "all" choice
    /// itself, which is a third state, not a special value of either — the same
    /// way Power BI stores `Include | Exclude` as a field of its own rather
    /// than inferring it.
    static let hostFilterRuleKey = "claudeHostFilterRule"
    static let hostFilterIdsKey = "claudeHostFilterIds"
    static let hostFilterShowsAllKey = "claudeHostShowsAll"

    /// Stands in for a session whose host we were never told — a scan whose
    /// parent chain didn't resolve, a hook payload with no bundle id. It gets
    /// its own row in Settings → Apps, so those sessions can be hidden too
    /// instead of being un-hideable.
    static let unknownHostId = "unknown"

    /// One row in Settings → Apps. `group` is what the list is split by: a flat
    /// run of sixteen boxes told the reader nothing about why Terminal sits
    /// next to Kitty.
    ///
    /// Orca is a terminal, not a category of its own: it is listed in
    /// `terminals` below, its sessions live in its panes, and the scan reads
    /// them out of `ORCA_PANE_KEY`. Giving it a row above the groups put the UI
    /// at odds with the model for no reason the reader could see.
    struct Host: Identifiable {
        enum Group: Int, CaseIterable {
            case terminal
            case editor
            /// A host we couldn't name. One row, so no header of its own.
            case other
        }
        let id: String
        let name: String
        let group: Group
    }

    /// Every host the user can tick, in reading order: the terminals, then the
    /// editors, then the unknown bucket.
    ///
    /// Sorted by display name because both tables are unordered — a picker that
    /// reshuffled between launches would be its own bug — and deduped by name
    /// because Cursor is reachable under two bundle ids and must be one row.
    static var allHosts: [Host] {
        var seen: Set<String> = []
        var rows: [Host] = []
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

    /// Whether the user is filtering by hand at all. True — show everything —
    /// until they say otherwise: "no filter" is a state the user can see and
    /// name, which is also why the per-app list stays hidden until they leave
    /// it. A missing key means no filter; so does a missing or malformed rule.
    static var showsAllHosts: Bool {
        get { UserDefaults.standard.object(forKey: hostFilterShowsAllKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hostFilterShowsAllKey) }
    }

    /// The stored rule, read only when `showsAllHosts` is false.
    static var storedRule: FilterRule {
        get {
            guard let raw = UserDefaults.standard.string(forKey: hostFilterRuleKey),
                  let rule = FilterRule(rawValue: raw)
            else { return .exclude }
            return rule
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: hostFilterRuleKey) }
    }

    /// The ticked ids, read through `storedRule`. Empty on a fresh install,
    /// which under the default `.exclude` rule means "nothing excluded" — so
    /// stepping into "custom" leaves what the notch shows exactly as it was.
    static var storedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hostFilterIdsKey) ?? []) }
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

    /// Whether a host id is shown, given a rule and its ticked rows. Pure, and
    /// the only place the two directions are spelled out, so the view layer and
    /// the hook gates can't disagree about what a tick means.
    static func isVisible(hostId: String, rule: FilterRule, ids: Set<String>) -> Bool {
        switch rule {
        case .showOnly: return ids.contains(hostId)
        case .exclude:  return !ids.contains(hostId)
        }
    }

    /// Same, reading the stored filter — for the hook gates, which have no view
    /// state to pass. "All" short-circuits: with no list, there is nothing that
    /// could have been filtered out.
    static func isVisibleHostId(_ id: String) -> Bool {
        guard !showsAllHosts else { return true }
        return isVisible(hostId: id, rule: storedRule, ids: storedIds)
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
        AppActivation.activate(bundleId: id)
        return true
    }
}
