import Foundation

/// How much of a session's context window is in use.
///
/// The numbers come from Claude Code's `StatusLine` hook, which is the only
/// integration point that reports live context usage — no other hook carries
/// token counts, and `/context` has no scriptable form. The wrapper script
/// (`statusline-hook.sh`) drops the payload it receives on disk; this is the
/// read side.
struct ContextWindow: Equatable, Sendable {
    /// 0…1, clamped. Fraction of the window in use.
    var usedFraction: Double
    /// 200_000 or 1_000_000, as reported by Claude Code for this session.
    ///
    /// Never inferred from the model name. `model.id` is whatever the
    /// configured gateway calls the model and says nothing about the real
    /// window — an alias can point at a 200k or a 1M backend. Claude Code
    /// already resolved it, so take its word for it.
    var windowSize: Int
}

enum StatusLineReader {

    /// `~/Library/Application Support/NotchBuddy` — the same folder `nb-hook`
    /// lives in. Recomputed rather than taken from `HookServer.supportDir`:
    /// this file is compiled on its own by `tests/StatusLineContextTests.swift`,
    /// and importing HookServer would drag the whole server in with it.
    static var supportDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NotchBuddy", isDirectory: true)
    }

    /// `~/Library/Application Support/NotchBuddy/statusline`
    /// (inside the app container in the App Store build, like every other
    /// per-user folder). One `<sessionId>.json` per session.
    static var payloadDir: URL? {
        supportDir?.appendingPathComponent("statusline", isDirectory: true)
    }

    /// The wrapper script itself. `settings.json` has to point at a real file
    /// on disk, so the one in the bundle is copied out on install.
    static var wrapperURL: URL? {
        supportDir?.appendingPathComponent("statusline-hook.sh")
    }

    /// Value for `statusLine.command`. Quoted — the path contains a space.
    static var wrapperCommand: String? {
        wrapperURL.map { "\"\($0.path)\"" }
    }

    /// The statusline this wrapper replaced, saved at install time so the
    /// wrapper can hand off to whatever the user actually runs (claude-hud, a
    /// script of their own) instead of guessing.
    static var savedOriginalURL: URL? {
        supportDir?.appendingPathComponent("statusline-original")
    }

    /// A file rather than a stored preference: Claude Code runs the wrapper
    /// without the app being open, and a bash script cannot read UserDefaults.
    static var enabledMarker: URL? {
        supportDir?.appendingPathComponent("statusline-enabled")
    }

    /// Whether the wrapper is currently saving payloads.
    static var isEnabled: Bool {
        guard let marker = enabledMarker else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// `nil` when the id could escape the payload directory. Session ids reach
    /// us from a hook payload and are used as file names, so `../../.ssh/…`
    /// has to be rejected rather than sanitised.
    static func payloadURL(sessionId: String) -> URL? {
        guard let dir = payloadDir, !sessionId.isEmpty,
              sessionId == URL(fileURLWithPath: sessionId).lastPathComponent,
              sessionId != ".", sessionId != ".."
        else { return nil }
        return dir.appendingPathComponent("\(sessionId).json")
    }

    /// Current usage for `sessionId`, or `nil` when there is no payload yet.
    ///
    /// `nil` is the common case, not a failure: the wrapper only runs for
    /// sessions Claude Code is drawing a statusline for, and `used_percentage`
    /// is null before a session's first API call and again between `/compact`
    /// and the next one. A session that has never been through the wrapper
    /// simply shows nothing.
    static func contextWindow(sessionId: String) -> ContextWindow? {
        guard let url = payloadURL(sessionId: sessionId),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let window = root["context_window"] as? [String: Any],
              let percent = (window["used_percentage"] as? NSNumber)?.doubleValue,
              let size = (window["context_window_size"] as? NSNumber)?.intValue,
              size > 0
        else { return nil }
        // Claude Code reports 0…100; clamp rather than let a stray value push
        // the bar past the end of its track.
        return ContextWindow(usedFraction: min(max(percent / 100, 0), 1), windowSize: size)
    }

    // MARK: - Install state

    enum InstallError: LocalizedError {
        case noSupportDir
        case wrapperMissing
        /// settings.json has no `statusLine.command`. Installing anyway would
        /// invent a statusline the user never configured, and Claude Code would
        /// start paying for one on every redraw.
        case noStatusLine
        /// The `statusLine.command` line could not be rewritten in place.
        case unpatchable
        /// settings.json points at the wrapper, but the statusline it replaced
        /// is gone — someone deleted `statusline-original`, so enabling would
        /// leave Claude Code with a wrapper that has nothing to pass on to.
        case originalMissing

        var errorDescription: String? {
            switch self {
            case .noSupportDir:
                return String(localized: "statusline.error.no-support-dir")
            case .wrapperMissing:
                return String(localized: "statusline.error.wrapper-missing")
            case .noStatusLine:
                return String(localized: "statusline.error.no-statusline")
            case .unpatchable:
                return String(localized: "statusline.error.unpatchable")
            case .originalMissing:
                return String(localized: "statusline.error.original-missing")
            }
        }
    }

    /// Start saving. `originalCommand` must be the `statusLine.command` value
    /// settings.json holds right now — the wrapper runs it after saving.
    @discardableResult
    static func enable(originalCommand: String) throws -> URL {
        let fm = FileManager.default
        guard let support = supportDir, let wrapper = wrapperURL,
              let marker = enabledMarker, let saved = savedOriginalURL
        else { throw InstallError.noSupportDir }

        guard let bundleURL = Bundle.main.url(forResource: "statusline-hook", withExtension: "sh"),
              let script = try? Data(contentsOf: bundleURL), !script.isEmpty
        else { throw InstallError.wrapperMissing }

        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        // Not atomic on purpose: a wrapper being replaced under a running
        // Claude Code is not a failure worth surfacing, and it gets rewritten
        // on every install anyway.
        try script.write(to: wrapper)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                             ofItemAtPath: wrapper.path)
        try originalCommand.write(to: saved, atomically: true, encoding: .utf8)
        try Data().write(to: marker)
        return wrapper
    }

    /// Stop saving and delete what was saved.
    ///
    /// `settings.json` is deliberately left alone: the wrapper stays in place,
    /// still handing the payload to the statusline it replaced, so turning
    /// this off changes only whether NotchBuddy records anything. Uninstalling
    /// the `statusLine` line itself is a separate, confirm-gated edit.
    static func disable() {
        let fm = FileManager.default
        if let marker = enabledMarker { try? fm.removeItem(at: marker) }
        guard let dir = payloadDir,
              let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in contents { try? fm.removeItem(at: file) }
    }

    /// Whether `settings.json`'s `statusLine.command` is this wrapper. Used by
    /// the settings pane to notice that the line was changed behind the app's
    /// back and that the saved original is no longer what is running.
    static func settingsPointAtWrapper(_ command: String) -> Bool {
        guard let wrapper = wrapperURL else { return false }
        return command == "\"\(wrapper.path)\"" || command == wrapper.path
    }
}