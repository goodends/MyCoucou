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

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
