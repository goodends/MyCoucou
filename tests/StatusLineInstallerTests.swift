import Foundation

/// `StatusLineInstaller` rewrites one key of a file that can hold API keys and
/// a dozen hooks, and is undone by uninstalling. These pin both directions:
/// that it points at the wrapper without losing the command it replaced, and
/// that it puts that command back.
@main
enum StatusLineInstallerTests {
    static func main() {
        // Point the support folder somewhere disposable. These tests call the
        // same apply/restore the app calls, and against the real folder they
        // overwrite the statusline the user's installed wrapper saved — which
        // breaks their statusline with no visible cause.
        let sandbox = NSTemporaryDirectory() + "coucou-statusline-tests-\(getpid())"
        try? FileManager.default.createDirectory(atPath: sandbox,
                                                 withIntermediateDirectories: true)
        setenv("COUCOU_SUPPORT_DIR", sandbox, 1)
        defer { try? FileManager.default.removeItem(atPath: sandbox) }

        // A statusline command with the escaped quotes every `bash -c '…'` one has.
        // A raw literal on purpose — written as a normal Swift string, `\"`
        // collapses to a bare `"` and the fixture stops being JSON. Nothing
        // else in here may escape: `'\''` is valid shell but a lone `\'` is not
        // a legal JSON escape, and the fixture has to parse.
        let tricky = #"bash -c 'd=$(ls -d \"${X_DIR}\"/p/*/ | head -1); exec node \"$d/i.js\"'"#
        var settings = real(
            """
            {
              "env": { "TOKEN": "sk-abc" },
              "hooks": { "Stop": [ { "hooks": [ { "command": "\\"a b\\"" } ] } ] },
              "includeCoAuthoredBy": false,
              "statusLine": {
                "type": "command",
                "command": "\(tricky)"
              },
              "model": "opus"
            }
            """)

        precondition(!StatusLineInstaller.isApplied(to: settings),
                     "a hand-written statusline must not read as ours")

        // The command as it exists once parsed: `\"` in the fixture arrives
        // here as a bare `"`. Everything below compares against this, not
        // against the source text.
        let originalCommand = (settings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        precondition(originalCommand.contains("\""), "fixture lost its escaped quotes")

        mustApply(to: &settings)
        precondition(StatusLineInstaller.isApplied(to: settings),
                     "apply did not take")

        let applied = settings["statusLine"] as? [String: Any] ?? [:]
        precondition(applied["type"] as? String == "command")

        // The shell quoting is the app's job, and it is load-bearing: without
        // it Claude Code runs the path up to the first space and the statusline
        // dies silently. This was the bug that made an earlier install look
        // installed while nothing ran.
        let command = applied["command"] as? String ?? ""
        precondition(command.hasPrefix("\""), "command must be shell-quoted: \(command)")
        precondition(command.hasSuffix("\""), "command must be shell-quoted: \(command)")

        // The command it replaced is saved before the line is changed, so
        // uninstalling has something to put back.
        let saved = StatusLineReader.savedOriginalCommand
        precondition(saved == originalCommand, "original not saved, got: \(saved ?? "nil")")

        // Unrelated keys are untouched.
        precondition(settings["model"] as? String == "opus")
        precondition(settings["includeCoAuthoredBy"] as? Bool == false)
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        let inner = (stop.first?["hooks"] as? [[String: Any]]) ?? []
        precondition(inner.first?["command"] as? String == "\"a b\"",
                     "an unrelated hook command was rewritten")

        // ---- Uninstalling puts it back, byte-identical ----
        StatusLineInstaller.restore(in: &settings)
        precondition(!StatusLineInstaller.isApplied(to: settings), "restore did not take")
        precondition((settings["statusLine"] as? [String: Any])?["command"] as? String == originalCommand,
                     "the original statusline came back changed")

        // ---- A fresh settings.json is claimed by apply ----
        var installCase = real(#"{"statusLine":{"type":"command","command":"mine.sh"}}"#)
        // ---- A settings.json with no statusline is skipped, not invented ----
        // Most people have no statusline at all. Inventing one would make
        // Claude Code run a command on every redraw they never asked for; the
        // hooks have to install either way.
        var none = real(#"{"model":"opus"}"#)
        precondition(skipsApplying(&none), "a statusline was applied to a file that had none")
        precondition(none["statusLine"] == nil, "a statusline was invented")

        // ---- Applying is what turns a statusline into a wrapped one ----
        // Regression: the settings pane installed the hooks and left the
        // statusline untouched, because the pane and the builder disagreed on
        // a default argument. The signature that caused it now takes the
        // value with no default, so a caller cannot get it wrong by omission;
        // what this pins is that the operation itself, given a settings.json
        // with a statusline, really does claim it.
        precondition(mustApply(to: &installCase), "apply found no statusline to claim")
        precondition(StatusLineInstaller.isApplied(to: installCase), "apply did not claim it")

        // ---- Restoring is a no-op when the line is not ours ----
        // A statusline the user wrote by hand after installing is theirs to
        // keep; removing it because it happens to sit where ours did would be
        // reaching past the setting.
        var theirs = real(#"{"statusLine":{"type":"command","command":"mine.sh"}}"#)
        StatusLineInstaller.restore(in: &theirs)
        precondition((theirs["statusLine"] as? [String: Any])?["command"] as? String == "mine.sh",
                     "restore touched a statusline that is not the wrapper")

        // ---- Installing over ours is idempotent ----
        // Re-running "install hooks" is a normal thing to do. The second apply
        // sees the wrapper's own path in the line, and must not take it for the
        // original — that would leave the wrapper invoking itself forever once
        // the statusline was put back.
        mustApply(to: &settings)
        precondition(StatusLineReader.savedOriginalCommand == originalCommand,
                     "a repeat install overwrote the saved original")
        precondition(StatusLineInstaller.isApplied(to: settings),
                     "a repeat install un-applied the wrapper")
        StatusLineInstaller.restore(in: &settings)

        print("StatusLineInstallerTests OK")
    }

    /// Apply and report whether it found a statusline to wrap.
    private static func skipsApplying(_ settings: inout [String: Any]) -> Bool {
        do { return try !StatusLineInstaller.apply(to: &settings) }
        catch { preconditionFailure("apply threw: \(error)") }
    }

    /// Apply and report whether it claimed a statusline. A throw here is the
    /// test failing, not a case to record.
    @discardableResult
    private static func mustApply(to settings: inout [String: Any]) -> Bool {
        do { return try StatusLineInstaller.apply(to: &settings) }
        catch { preconditionFailure("apply threw: \(error)") }
    }


    /// Parses a fixture, failing loudly. Returning `[:]` on a bad fixture would
    /// make every later assertion fail on the wrong thing — that cost an hour
    /// of chasing a phantom bug once already.
    private static func real(_ json: String) -> [String: Any] {
        do {
            return try JSONSerialization.jsonObject(
                with: Data(json.utf8), options: [.fragmentsAllowed]) as? [String: Any] ?? [:]
        } catch {
            preconditionFailure("fixture is not valid JSON (\(error)):\n\(json)")
        }
    }
}