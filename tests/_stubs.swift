import Foundation

// Stubs so `ClaudeSessionTests` can compile against a minimal slice of the codebase.
// Only what `BotEngine.swift` and `IslandConst` reach for. Not used by the production
// build — see `scripts/test-claude-session.sh` for the explicit file list.

extension Notification.Name {
    static let botDizzy = Notification.Name("botDizzy")
}

final class AppState: @unchecked Sendable {
    static let shared = AppState()
    let soundEnabled: Bool = true
}

final class SoundEngine: @unchecked Sendable {
    static let shared = SoundEngine()
    let enabled: Bool = true
    func play(_ name: String) {}
}