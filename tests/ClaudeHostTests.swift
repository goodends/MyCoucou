import Foundation

@main
enum ClaudeHostTests {
    static func check(_ label: String, _ got: Bool, failures: inout Int) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        var failures = 0
        print("ClaudeHost.terminal")
        check("Warp by bundle id", ClaudeHost.terminal(termProgram: "", bundleId: "dev.warp.Warp-Stable")?.name == "Warp", failures: &failures)
        check("Warp by TERM_PROGRAM", ClaudeHost.terminal(termProgram: "WarpTerminal", bundleId: "")?.bundleId == "dev.warp.Warp-Stable", failures: &failures)
        check("Terminal.app", ClaudeHost.terminal(termProgram: "Apple_Terminal", bundleId: "")?.name == "Terminal", failures: &failures)
        check("iTerm", ClaudeHost.terminal(termProgram: "iTerm.app", bundleId: "")?.name == "iTerm", failures: &failures)
        check("tmux inside Ghostty: bundle id wins",
              ClaudeHost.terminal(termProgram: "tmux", bundleId: "com.mitchellh.ghostty")?.name == "Ghostty", failures: &failures)
        check("cmux: bundle id wins over TERM_PROGRAM=ghostty",
              ClaudeHost.terminal(termProgram: "ghostty", bundleId: "com.cmuxterm.app")?.name == "cmux", failures: &failures)
        check("Orca by bundle id", ClaudeHost.terminal(termProgram: "", bundleId: "com.stablyai.orca")?.name == "Orca", failures: &failures)
        check("VS Code → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.microsoft.VSCode") == nil, failures: &failures)
        check("Cursor → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92") == nil, failures: &failures)
        check("unknown → nil", ClaudeHost.terminal(termProgram: "", bundleId: "com.example.app") == nil, failures: &failures)

        print("ClaudeHost.name")
        // A host we were never told is unknown, not "VS Code". The old version
        // answered "VS Code" for anything unrecognised, which was right for
        // editor sessions by coincidence and wrong everywhere else.
        check("nil host = unknown", ClaudeHost.name(for: nil) == nil, failures: &failures)
        check("empty host = unknown", ClaudeHost.name(for: "") == nil, failures: &failures)
        check("unknown host = unknown", ClaudeHost.name(for: "com.example.app") == nil, failures: &failures)
        check("Warp host", ClaudeHost.name(for: "dev.warp.Warp-Stable") == "Warp", failures: &failures)
        check("Orca host", ClaudeHost.name(for: "com.stablyai.orca") == "Orca", failures: &failures)
        // Editors are hosts too, recognised by their own bundle id.
        check("VS Code host", ClaudeHost.name(for: "com.microsoft.VSCode") == "VS Code", failures: &failures)
        check("Cursor host", ClaudeHost.name(for: "com.todesktop.230313mzl4w4u92") == "Cursor", failures: &failures)

        print("ClaudeHost.terminalCardsEnabled")
        UserDefaults.standard.removeObject(forKey: ClaudeHost.terminalCardsKey)
        check("off by default", ClaudeHost.terminalCardsEnabled == false, failures: &failures)

        print("ClaudeHost.allHosts")
        UserDefaults.standard.removeObject(forKey: ClaudeHost.hostFilterIdsKey)
        UserDefaults.standard.removeObject(forKey: ClaudeHost.hostFilterRuleKey)
        UserDefaults.standard.removeObject(forKey: ClaudeHost.hostFilterShowsAllKey)
        let hosts = ClaudeHost.allHosts
        // Orca is a terminal host like any other: its sessions live in panes and
        // the scan reads them from ORCA_PANE_KEY, so it belongs in the group
        // rather than in a row of its own above them.
        check("Orca is a terminal", hosts.first { $0.id == ClaudeHost.orcaBundleId }?.group == .terminal, failures: &failures)
        check("every terminal precedes every editor",
              hosts.lastIndex(where: { $0.group == .terminal }).map { t in
                  hosts.lastIndex(where: { $0.group == .editor }).map { t < $0 } ?? false
              } ?? false, failures: &failures)
        check("unknown last", hosts.last?.id == ClaudeHost.unknownHostId, failures: &failures)
        // Cursor answers to two bundle ids but is one row the user ticks.
        check("Cursor listed once", hosts.filter { $0.name == "Cursor" }.count == 1, failures: &failures)
        check("no duplicate names", Set(hosts.map(\.name)).count == hosts.count, failures: &failures)
        check("every row has a name", hosts.allSatisfy { !$0.name.isEmpty }, failures: &failures)

        print("ClaudeHost.stored filter")
        // A fresh install filters nothing: "all" is its own state, not an empty
        // list read one particular way, which is what lets the settings page hide
        // the list until the user asks for it.
        check("shows all by default", ClaudeHost.showsAllHosts, failures: &failures)
        check("rule defaults to exclude", ClaudeHost.storedRule == .exclude, failures: &failures)
        check("no rows ticked by default", ClaudeHost.storedIds.isEmpty, failures: &failures)

        print("ClaudeHost.isVisible (custom · show only the ticked)")
        func session(_ hostApp: String?, _ bundleId: String? = nil) -> ClaudeSession {
            ClaudeSession(id: "sid", sessionId: "sid", cwd: "/tmp/x", hostApp: hostApp,
                          sessionBundleId: bundleId, projectName: "x", state: .idle,
                          startedAt: .now, lastEventAt: .now)
        }
        // Resolve the host, then ask the one predicate — the two steps every
        // caller makes. Reads the stored filter, which is what each test has
        // just set and what the hook gates see.
        func isVisible(_ s: ClaudeSession) -> Bool {
            guard !ClaudeHost.showsAllHosts else { return true }
            return ClaudeHost.isVisible(hostId: ClaudeHost.hostId(for: s),
                                        rule: ClaudeHost.storedRule, ids: ClaudeHost.storedIds)
        }
        ClaudeHost.showsAllHosts = false
        ClaudeHost.storedRule = .showOnly
        ClaudeHost.storedIds = [ClaudeHost.orcaBundleId]
        check("Orca visible", isVisible(session(ClaudeHost.orcaBundleId)), failures: &failures)
        check("Terminal hidden", !isVisible(session("com.apple.Terminal")), failures: &failures)
        check("VS Code hidden", !isVisible(session("com.microsoft.VSCode")), failures: &failures)
        // No host at all: a scan whose parent chain didn't resolve. Not Orca, so
        // it stays out unless the user ticks Other.
        check("unknown host hidden", !isVisible(session(nil)), failures: &failures)
        check("empty host is unknown", ClaudeHost.hostId(for: session("")) == ClaudeHost.unknownHostId, failures: &failures)
        // The hook's own bundle id is the fallback when no terminal was named —
        // an editor session has no terminal, only the app it runs in.
        check("falls back to the hook bundle id",
              ClaudeHost.hostId(for: session(nil, "com.microsoft.VSCode")) == "com.microsoft.VSCode",
              failures: &failures)
        // An app with no row in the tables (the Claude desktop build) used to
        // keep its own bundle id, which no checkbox matched: gone from the list
        // with no way to bring it back. It has to fall into the Other bucket.
        check("unlisted app is Other",
              ClaudeHost.hostId(for: session(nil, "com.anthropic.claudefordesktop")) == ClaudeHost.unknownHostId,
              failures: &failures)
        check("hook payload form", ClaudeHost.hostId(hostApp: nil, bundleId: "com.apple.Terminal") == "com.apple.Terminal", failures: &failures)
        check("hook payload, nothing known", ClaudeHost.hostId(hostApp: "", bundleId: "") == ClaudeHost.unknownHostId, failures: &failures)
        ClaudeHost.storedIds = [ClaudeHost.orcaBundleId, ClaudeHost.unknownHostId]
        check("unknown visible once ticked", isVisible(session(nil)), failures: &failures)
        check("unlisted app visible via Other too",
              isVisible(session(nil, "com.anthropic.claudefordesktop")), failures: &failures)
        ClaudeHost.storedIds = ["com.apple.Terminal"]
        check("Terminal visible once ticked", isVisible(session("com.apple.Terminal")), failures: &failures)
        check("Orca hidden once unticked", !isVisible(session(ClaudeHost.orcaBundleId)), failures: &failures)

        print("ClaudeHost.isVisible (custom · exclude the ticked)")
        // Same rows, opposite rule — and the rule is a labelled choice in its own
        // right, not something the checkboxes imply. Nothing to exclude means
        // everything shows, including hosts we have no row for: an exclusion list
        // can't accidentally silence the unknown.
        ClaudeHost.storedRule = .exclude
        ClaudeHost.storedIds = []
        check("nothing excluded shows Orca", isVisible(session(ClaudeHost.orcaBundleId)), failures: &failures)
        check("nothing excluded shows Terminal", isVisible(session("com.apple.Terminal")), failures: &failures)
        check("nothing excluded shows VS Code", isVisible(session("com.microsoft.VSCode")), failures: &failures)
        check("nothing excluded shows an unknown host", isVisible(session(nil)), failures: &failures)
        check("nothing excluded covers a brand-new id", ClaudeHost.isVisibleHostId("com.brand.new.terminal"), failures: &failures)
        ClaudeHost.storedIds = ["com.apple.Terminal"]
        check("excluded Terminal is quiet", !isVisible(session("com.apple.Terminal")), failures: &failures)
        check("untouched Orca still shows", isVisible(session(ClaudeHost.orcaBundleId)), failures: &failures)
        ClaudeHost.storedIds = [ClaudeHost.unknownHostId]
        check("excluding Other also silences unlisted apps",
              !isVisible(session(nil, "com.anthropic.claudefordesktop")), failures: &failures)
        check("excluding Other leaves Terminal alone", isVisible(session("com.apple.Terminal")), failures: &failures)
        ClaudeHost.storedIds = Set(ClaudeHost.allHosts.map(\.id))
        check("every row excluded shows nothing", !isVisible(session(ClaudeHost.orcaBundleId)), failures: &failures)
        check("every row excluded silences a terminal too", !isVisible(session("com.apple.Terminal")), failures: &failures)
        check("every row excluded still leaves unknown-outside-the-list alone",
              ClaudeHost.isVisibleHostId("com.brand.new.terminal"), failures: &failures)

        print("ClaudeHost.isVisibleHost (a pill's own host fields)")
        // A pill with no host recorded at all is an agent that isn't a Claude
        // Code session (Codex, Copilot…). Filtering it as "unknown" would mute
        // every agent pill the moment the user excluded Other.
        ClaudeHost.storedRule = .showOnly
        ClaudeHost.storedIds = [ClaudeHost.orcaBundleId]
        check("no host recorded shows", ClaudeHost.isVisibleHost(hostApp: nil, bundleId: nil), failures: &failures)
        check("empty host fields show", ClaudeHost.isVisibleHost(hostApp: "", bundleId: ""), failures: &failures)
        check("recorded host is filtered", !ClaudeHost.isVisibleHost(hostApp: "com.apple.Terminal", bundleId: "com.apple.Terminal"), failures: &failures)
        // VS Code and Cursor name no terminal, only the app they run in.
        check("editor host is filtered", !ClaudeHost.isVisibleHost(hostApp: nil, bundleId: "com.microsoft.VSCode"), failures: &failures)
        check("Orca host shows", ClaudeHost.isVisibleHost(hostApp: ClaudeHost.orcaBundleId, bundleId: ""), failures: &failures)
        ClaudeHost.storedRule = .exclude
        ClaudeHost.storedIds = ["com.apple.Terminal"]
        check("an unexcluded host shows", ClaudeHost.isVisibleHost(hostApp: ClaudeHost.orcaBundleId, bundleId: ""), failures: &failures)
        check("an excluded host is muted", !ClaudeHost.isVisibleHost(hostApp: "com.apple.Terminal", bundleId: ""), failures: &failures)
        check("no host recorded still shows", ClaudeHost.isVisibleHost(hostApp: nil, bundleId: nil), failures: &failures)
        // Back to "all": with no list, nothing can have been filtered out — the
        // rows left over from a previous custom filter must not keep silencing.
        ClaudeHost.storedRule = .showOnly
        ClaudeHost.storedIds = [ClaudeHost.orcaBundleId]
        ClaudeHost.showsAllHosts = true
        check("all shows a host the rows would have hidden",
              ClaudeHost.isVisibleHost(hostApp: "com.apple.Terminal", bundleId: "com.apple.Terminal"), failures: &failures)
        check("all shows an unknown host", ClaudeHost.isVisibleHost(hostApp: nil, bundleId: "com.example.app"), failures: &failures)

        print("ClaudeHost.runsInOrca")
        // Only Orca has an Orca terminal to switch to. The check reads the
        // resolved host, not `hostApp`: an editor session names no terminal, so
        // `hostApp` is nil for exactly the sessions that used to fall through
        // to the cwd lookup and land on an unrelated Orca worktree.
        check("Orca host runs in Orca", ClaudeHost.runsInOrca(session(ClaudeHost.orcaBundleId)), failures: &failures)
        check("Warp does not", !ClaudeHost.runsInOrca(session("dev.warp.Warp-Stable")), failures: &failures)
        check("VS Code does not", !ClaudeHost.runsInOrca(session(nil, "com.microsoft.VSCode")), failures: &failures)
        check("Cursor does not", !ClaudeHost.runsInOrca(session(nil, "com.todesktop.230313mzl4w4u92")), failures: &failures)
        check("no host at all does not", !ClaudeHost.runsInOrca(session(nil)), failures: &failures)

        ClaudeHost.showsAllHosts = true
        ClaudeHost.storedRule = .exclude
        ClaudeHost.storedIds = []
        UserDefaults.standard.removeObject(forKey: ClaudeHost.hostFilterIdsKey)
        UserDefaults.standard.removeObject(forKey: ClaudeHost.hostFilterRuleKey)
        UserDefaults.standard.removeObject(forKey: ClaudeHost.hostFilterShowsAllKey)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
