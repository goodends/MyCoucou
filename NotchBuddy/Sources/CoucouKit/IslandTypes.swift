import Foundation

// MARK: - Island Mode

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

// MARK: - Island View

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case confused, prompt
    case searching, result, note, greeting, wardrobe
}

// MARK: - Bot State

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}

// MARK: - Bot Emote

enum BotEmote: String, CaseIterable {
    case love, surprised, proud, wink, yawn, happy, annoyed
}

// MARK: - Approval info (pending PermissionRequest from Claude Code)

struct ApprovalInfo: Sendable {
    var sessionId: String
    var tool: String
    var command: String
    /// tool_input serialized to JSON with sortedKeys, "" if absent — used to match PostToolUse.
    var inputKey: String
    /// Pill that owns this approval: "integration_claude", "agent_cursor", or "agent_codex".
    var pillId: String
}

// MARK: - Pill badge (shown on pill edge when non-focused task has an alert)

enum PillBadge { case approval, finished, error }

// MARK: - Agent Task

struct AgentTask: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String          // hex
    var state: BotState
    var stepIndex: Int = 0
    var steps: [String]
    var source: AgentSource
    var isIntegration: Bool = false  // true for persistent integration pills
    var emote: BotEmote? = nil
    var miniEye: EyeShape? = nil
    var pillBadge: PillBadge? = nil  // alert badge shown on pill when not focused
    var sessionCwd: String?  = nil  // last known working directory (Claude Code sessions)
    var sessionId: String?   = nil  // Claude Code session id (matches ~/.claude/projects/.../<sessionId>.jsonl)
    var sessionBundleId: String? = nil  // app the session runs in (hook bundle_id), for "Open terminal"
    var finalLine: String?   = nil  // last assistant message shown as static text after Stop
    var hostApp: String?     = nil  // bundle id of the terminal running a Claude Code session; nil = VS Code
    var history: [HistoryEntry] = []  // full prompt/response log from UserPromptSubmit + Stop hooks
    /// Optional outfit (hat / glasses / scarf / etc.). Drawn by MiniBotCanvasView.
    /// Default nil so existing AgentPill pills stay unchanged.
    var outfit: Outfit? = nil
}

enum AgentSource: Equatable {
    case claudeCode
    case n8n
    case agent   // third-party agent via coucou_agent field
}

// MARK: - Claude Code session (per-session tracking for the overview's active-session list)

/// A curated body colour for a Mochi, with the name the wardrobe shows.
struct MochiColor: Identifiable, Hashable, Sendable {
    let hex: String
    let name: String
    var id: String { hex }
}

/// Per-session view of a running Claude Code process. One Claude Code window / terminal tab
/// = one `ClaudeSession`. Distinct from `AgentTask`, which still represents the single
/// `integration_claude` pill (one per project/host at most).
struct ClaudeSession: Identifiable, Equatable {
    let id: String                  // == sessionId
    let sessionId: String           // Claude Code UUID; matches ~/.claude/projects/.../<sid>.jsonl
    var cwd: String                 // last known working directory
    var hostApp: String?            // bundle id of the terminal running the session; nil = VS Code / editor
    var sessionBundleId: String?    // bundle id of the app hosting the session (always set by the hook)
    var projectName: String         // cwd.lastPathComponent, after aliasProjectName
    var state: SessionPhase
    var startedAt: Date
    var lastEventAt: Date           // used for lazy GC of zombie sessions (>30 min idle)
    /// Body color for this session's mini Mochi — random on first upsert,
    /// fixed for the session's lifetime.
    var bodyColor: String = "#F5F6F8"
    /// Outfit (hat / glasses / scarf / …) for this session — random on first
    /// upsert, fixed for the session's lifetime. Drives both the right-side
    /// pill avatar and the main Mochi's appearance while this session is the
    /// active one (`overviewSession`).
    var outfit: Outfit = .none
    /// The name typed in the wardrobe; empty = fall back to `projectName`.
    var customName: String = ""

    /// What the home view shows: the name the user chose, else the project
    /// folder's name.
    var displayName: String { customName.isEmpty ? projectName : customName }

    /// The curated body colours: warm + saturated so the character stays
    /// visible against the dark pill background. One is picked at random when
    /// a session first appears; the wardrobe lets the user pick another.
    static let palette: [MochiColor] = [
        MochiColor(hex: "#F5F6F8", name: "White"),
        MochiColor(hex: "#F5A524", name: "Orange"),
        MochiColor(hex: "#5EEAD4", name: "Teal"),
        MochiColor(hex: "#EC4899", name: "Pink"),
        MochiColor(hex: "#A78BFA", name: "Purple"),
        MochiColor(hex: "#60A5FA", name: "Blue"),
        MochiColor(hex: "#F87171", name: "Red"),
    ]
}

/// Visual phase of a session in the right-side list. Distinct from `BotState` so the
/// pill dot can stay simple (cyan/green/dim) regardless of the focus pill's many states.
enum SessionPhase: String, Equatable {
    case spawning   // SessionStart just received
    case working    // UserPromptSubmit / PreToolUse / PostToolUse
    case finished   // Stop (turn complete, badge shown for 5s)
    case stopped    // StopFailure / Interrupt
}

extension Array where Element == ClaudeSession {
    /// Every outfit except `.auto` (a picker sentinel) and `.none` (the default).
    private static var avatarOutfits: [Outfit] {
        Outfit.allCases.filter { $0 != .auto && $0 != .none }
    }

    /// Insert a new session, or update its fields in place and promote to the front.
    /// Empty / "unknown" `sessionId` is a no-op. List stays sorted most-recent-first.
    /// On first appearance, each session is randomly assigned a body color and an
    /// outfit; re-upserts keep those picks.
    mutating func upsert(
        sessionId: String,
        cwd: String,
        hostApp: String?,
        sessionBundleId: String?,
        projectName: String,
        phase: SessionPhase,
        eventTime: Date
    ) {
        guard !sessionId.isEmpty, sessionId != "unknown" else { return }
        if let idx = firstIndex(where: { $0.sessionId == sessionId }) {
            var s = self[idx]
            s.cwd = cwd
            s.hostApp = hostApp
            s.sessionBundleId = sessionBundleId
            s.projectName = projectName
            s.state = phase
            s.lastEventAt = eventTime
            remove(at: idx)
            insert(s, at: 0)
        } else {
            let bodyColor = ClaudeSession.palette.randomElement()?.hex ?? "#F5F6F8"
            let outfit    = Self.avatarOutfits.randomElement() ?? .none
            insert(
                ClaudeSession(
                    id: sessionId, sessionId: sessionId,
                    cwd: cwd, hostApp: hostApp, sessionBundleId: sessionBundleId,
                    projectName: projectName, state: phase,
                    startedAt: eventTime, lastEventAt: eventTime,
                    bodyColor: bodyColor, outfit: outfit
                ),
                at: 0
            )
        }
    }

    /// Remove a session by id. No-op if absent.
    mutating func removeById(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        removeAll { $0.sessionId == sessionId }
    }
}

// MARK: - History (per-agent session log fed by HookServer)

enum ChatRole { case user, assistant }

struct HistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var content: String
}

// MARK: - View dimensions (from VIEWS in prototype)

struct ViewLayout {
    let height: CGFloat
    let botX: CGFloat
    let botY: CGFloat?         // nil = auto-centered
    let botDiameter: CGFloat
    let agentMode: AgentLayoutMode
}

enum AgentLayoutMode {
    case none, grid, pills, column
}

// MARK: - Constants (from NW, NH, EW in prototype)

enum IslandConst {
    static let notchWidth: CGFloat  = IslandScreenGeometry.fallbackNotchWidth
    static let notchHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 640
    static let earRadius: CGFloat   = 14
    static let roundedCorner: CGFloat = 14    // hidden/peek/compact
    static let expandedCorner: CGFloat = 22

    static let viewLayouts: [IslandView: ViewLayout] = [
        // Home is the reference: height 160
        .overview:  ViewLayout(height: 160, botX: 68,  botY: nil, botDiameter: 58, agentMode: .pills),
        // All non-chat views match home height (150) — law
        .empty:     ViewLayout(height: 160, botX: 70,  botY: nil, botDiameter: 62, agentMode: .none),
        .approval:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .question:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .error:     ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .finished:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .confused:  ViewLayout(height: 160, botX: 76,  botY: nil, botDiameter: 66, agentMode: .column),
        .prompt:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .searching: ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .result:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .note:      ViewLayout(height: 160, botX: 60,  botY: nil, botDiameter: 50, agentMode: .column),
        // Greeting: bot drawn by GreetingCanvasView; no BotPlacement needed
        .greeting:  ViewLayout(height: 150, botX: 320, botY: 90,  botDiameter: 0,  agentMode: .none),
        .wardrobe:  ViewLayout(height: 160, botX: 68,  botY: nil, botDiameter: 58, agentMode: .none),
    ]

    // Project colors — keyed by lowercase display name or slug
    static let projectColors: [String: String] = [
        "korus":             "#FF5A4E",
        "sbe hub":           "#2EC4A0",
        "morning ai brief":  "#F29B38",
        "publication ig":    "#7C5CFF",
        "ig post":           "#7C5CFF",
        "louisraille.fr":    "#38BDF8",
        "louisraille":       "#38BDF8",
        "notch buddy":       "#EC4899",
        "notch-buddy":       "#EC4899",
        "notchbuddy":        "#EC4899",
    ]

    static let fallbackColors = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"]

    /// Returns the fixed project color for a display name, or a stable fallback.
    static func colorForProject(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = projectColors[key] { return c }
        // partial match (e.g. "korus-api" → "korus")
        for (k, c) in projectColors where key.hasPrefix(k) || key.contains(k) { return c }
        return fallbackColors[abs(name.hashValue) % fallbackColors.count]
    }

    // State card wash colors (radial gradient from bottom)
    static let washColors: [IslandView: String] = [
        .approval:  "rgba(245,165,36,0.42)",
        .question:  "rgba(34,211,238,0.38)",
        .error:     "rgba(244,80,94,0.55)",
        .finished:  "rgba(52,211,153,0.5)",
        .confused:  "rgba(244,114,182,0.55)",
        .searching: "rgba(99,102,241,0.5)",
        .result:    "rgba(52,211,153,0.22)",
        .prompt:    "rgba(99,102,241,0.22)",
    ]
}
