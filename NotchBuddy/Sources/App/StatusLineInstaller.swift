import Foundation

/// Points Claude Code's statusline at the wrapper, and puts it back.
///
/// This is part of the hooks installer rather than a separate settings writer:
/// both edit the same file, and splitting them meant two diffs, two backups and
/// two writes of `~/.claude/settings.json` — with the hooks half reordering the
/// whole file anyway, so the careful one-line edit bought nothing.
enum StatusLineInstaller {

    /// The wrapper's command line, shell-quoted: Claude Code runs this through
    /// a shell, and the path contains a space.
    static var wrapperCommand: String? {
        StatusLineReader.wrapperURL.map { "\"\($0.path)\"" }
    }

    /// Whether `settings` already points at the wrapper.
    static func isApplied(to settings: [String: Any]) -> Bool {
        guard let command = command(in: settings), let wrapper = StatusLineReader.wrapperURL
        else { return false }
        return command == "\"\(wrapper.path)\""
    }

    /// Points `settings` at the wrapper. Returns false when there is nothing to
    /// wrap.
    ///
    /// A settings.json with no `statusLine.command` is the normal state for
    /// most people, and that is not a failure — the hooks install either way
    /// and the context bar simply does not appear. Inventing a statusline would
    /// instead make Claude Code run a command on every redraw that the user
    /// never asked for.
    @discardableResult
    static func apply(to settings: inout [String: Any]) throws -> Bool {
        guard let command = command(in: settings) else { return false }
        guard let wrapper = StatusLineReader.wrapperCommand else {
            throw StatusLineReader.InstallError.noSupportDir
        }
        // Save what is there now, so the wrapper has something to hand off to.
        // Doing it here rather than at write time means a later uninstall can
        // put the line back without guessing.
        //
        // Skipped when the line already points at the wrapper: installing is
        // something people re-run, and saving the wrapper's own path as "the
        // original" would leave it invoking itself forever after one uninstall.
        if !isApplied(to: settings) {
            try StatusLineReader.saveOriginalCommand(command)
        }

        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = wrapper
        settings["statusLine"] = statusLine
        return true
    }

    /// Puts the original command back, if there is one and if the current one is
    /// ours. Leaves settings alone otherwise — a statusline the user wrote by
    /// hand is not ours to remove.
    static func restore(in settings: inout [String: Any]) {
        guard isApplied(to: settings),
              let saved = StatusLineReader.savedOriginalCommand,
              !saved.isEmpty
        else { return }
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = saved
        settings["statusLine"] = statusLine
    }

    private static func command(in settings: [String: Any]) -> String? {
        guard let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.isEmpty
        else { return nil }
        return command
    }
}