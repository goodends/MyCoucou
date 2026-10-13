import Foundation

/// Edits `~/.claude/settings.json` so Claude Code's statusline goes through
/// the wrapper, and puts it back.
///
/// Separate from `HookServer`'s hook installer for two reasons: the change is
/// one string rather than twelve events, and — unlike the hooks — it is not
/// something the app can quietly re-do on every launch. `statusLine.command`
/// belongs to whatever the user had, so it is shown as a diff and written only
/// once they say yes. Turning the feature off leaves that line alone; see
/// `StatusLineReader.disable`.
enum StatusLineInstaller {

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// What settings.json asks Claude Code to run for the statusline right now,
    /// or nil when it has none. A missing statusline is the normal state for
    /// most people, and installing into one would create a statusline the user
    /// never asked for.
    static func currentCommand() throws -> String? {
        let settings = try ClaudeSettingsFile.read(at: settingsURL).object
        guard let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.isEmpty
        else { return nil }
        return command
    }

    /// settings.json with `statusLine.command` pointed at the wrapper, ready to
    /// show as a diff. Throws rather than guessing when the file has no
    /// statusline.
    static func buildEnabled() throws -> (data: Data, original: Data?, previousCommand: String) {
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        guard let previous = try currentCommand() else {
            throw StatusLineReader.InstallError.noStatusLine
        }
        guard let replacement = StatusLineReader.wrapperCommand else {
            throw StatusLineReader.InstallError.noSupportDir
        }
        guard let patched = replacingStatusLineCommand(
            in: snapshot.bytes ?? Data(), with: replacement
        ) else {
            throw StatusLineReader.InstallError.unpatchable
        }
        return (patched, snapshot.bytes, previous)
    }

    /// Turns the feature on when settings.json *already* names the wrapper,
    /// which is the state uninstalling leaves behind: uninstall stops the
    /// saving and deletes the payloads, but leaves that line alone on purpose.
    ///
    /// Re-installing therefore has nothing to change in settings.json — it just
    /// puts the wrapper script and the flag back. Erroring here instead would
    /// make the setting impossible to turn back on without hand-editing the
    /// file.
    @discardableResult
    static func reenable() throws -> URL {
        guard let saved = StatusLineReader.savedOriginalURL,
              let original = try? String(contentsOf: saved, encoding: .utf8),
              !original.isEmpty
        else { throw StatusLineReader.InstallError.originalMissing }
        return try StatusLineReader.enable(originalCommand: original)
    }

    /// Writes the file `buildEnabled` prepared, then turns the wrapper on.
    ///
    /// The copy of the wrapper script and the flag go down only after the
    /// settings write succeeds: a half-installed feature would leave the app
    /// reading payloads from a wrapper Claude Code never calls.
    @discardableResult
    static func install(from prepared: (data: Data, original: Data?, previousCommand: String)) throws -> URL? {
        let backup = try ClaudeSettingsFile.write(prepared.data, to: settingsURL,
                                                 expecting: prepared.original)
        return try StatusLineReader.enable(originalCommand: prepared.previousCommand)
    }

    /// Replaces the `statusLine.command` value in place, leaving every other
    /// byte of the file alone.
    ///
    /// Not JSONSerialization the way the hook installer does it. That path
    /// rewrites the file with `sortedKeys`, which reorders the user's whole
    /// settings.json — and this file can hold API keys in `env`, where a
    /// reordered diff is noise the user has to read past to find the one line
    /// that changed.
    ///
    /// Not private: this is the part worth testing, and the pattern in
    /// `ClaudeSettingsFile` is the same — the tested method is internal.
    static func replacingStatusLineCommand(in bytes: Data, with command: String) -> Data? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        // `(?:[^"\\]|\\.)*` — a quoted string with escapes, so the embedded
        // quotes and backslashes in a `bash -c '…'` command don't end the match.
        let pattern = try! NSRegularExpression(
            pattern: "(\"statusLine\"\\s*:\\s*\\{\\s*\"type\"\\s*:\\s*\"command\"\\s*,\\s*\"command\"\\s*:\\s*)\"(?:[^\"\\\\]|\\\\.)*\""
        )
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        // Group 1 ends where the old value's opening quote starts; the match
        // itself starts at `"statusLine"`, so its own location is not the split
        // point.
        let key = match.range(at: 1)
        guard key.location != NSNotFound else { return nil }
        let valueStart = key.location + key.length

        // Splice rather than `stringByReplacingMatches(withTemplate:)`. The
        // template form reads `$` and `\` as its own metacharacters, and the
        // replacement here is JSON text — a command holding a quote or a
        // backslash arrives as `\"`, which that API is free to interpret. The
        // new literal carries its own quotes; the old value's are consumed with
        // the match.
        let ns = text as NSString
        let patched = ns.substring(to: valueStart)
            + jsonStringLiteral(command)
            + ns.substring(from: match.range.location + match.range.length)

        guard let data = patched.data(using: .utf8) else { return nil }
        // Never hand back something that stopped parsing.
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil ? data : nil
    }

    /// `command` as a JSON string literal, quotes included.
    ///
    /// `command` arrives already shell-quoted — a path with a space needs the
    /// quotes for the shell Claude Code runs it through — so no second pair is
    /// added. Those quotes are part of the value and come back escaped.
    private static func jsonStringLiteral(_ command: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed])
        if let text = data.flatMap({ String(data: $0, encoding: .utf8) }) { return text }
        // Unreachable for a String: JSON can always represent it.
        return "\"\""
    }
}