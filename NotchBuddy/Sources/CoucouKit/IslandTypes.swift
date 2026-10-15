import Foundation

// MARK: - Island Mode

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

// MARK: - Island View

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, finished
    case prompt
    case searching, result, note, greeting, wardrobe
    // Per-session file changes: the list of files one session edited, with
    // +N −M per file, newest first. Deeper than a home view, so it gets a
    // taller layout — see IslandConst.viewLayouts below.
    case changes
}

// MARK: - Bot State

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping
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

enum PillBadge { case approval, question, finished, error }

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
    /// The one state every surface reads. It used to be a narrower
    /// `SessionPhase` (spawning/working/finished/stopped) with a hand-written
    /// map into `BotState`, so a session with a question pending showed its
    /// question badge on the notification card and blue dots everywhere else.
    var state: BotState
    var startedAt: Date
    var lastEventAt: Date           // fallback GC for sessions that never reported a pid
    /// PID of the agent process running this session, reported by the hook relay.
    /// The right-side list keeps the session while this process is alive, so an
    /// idle session waiting at the prompt stays visible instead of timing out.
    /// nil for sessions last seen before the relay learned to report a pid (or
    /// from a third-party agent whose parent chain couldn't be resolved).
    var pid: Int32? = nil
    /// True for a session found by scanning the process table (see
    /// ClaudeProcessScanner): the pid and cwd are real, but there is no session
    /// id yet, so we can't say what it's doing or read its transcript. Derived
    /// from the placeholder id so the two can't drift apart.
    var provisional: Bool { ClaudeSession.isProvisionalId(sessionId) }
    /// Body color for this session's mini Mochi — random on first upsert,
    /// fixed for the session's lifetime.
    var bodyColor: String = "#F5F6F8"
    /// Outfit (hat / glasses / scarf / …) for this session — random on first
    /// upsert, fixed for the session's lifetime. Drives both the right-side
    /// pill avatar and the main Mochi's appearance while this session is the
    /// active one (`overviewSession`).
    var outfit: Outfit = .none
    /// Claude Code's own name for this session, from the live-session registry
    /// (`~/.claude/sessions/<pid>.json`). Distinct from `customName`: this one
    /// is generated by the agent, that one is typed by the user. Empty for a
    /// session we only know from a hook event.
    var sessionName: String = ""
    /// The name typed in the wardrobe; empty = fall back to `sessionName`,
    /// then `projectName`. Only ever written by `setSessionName`.
    var customName: String = ""
    /// Discovered by the process scan rather than announced by a hook. A
    /// scanned session has no hostApp/sessionBundleId — nothing has told us
    /// what app it runs in — so the views label it by folder instead of
    /// guessing "VS Code".
    var scanned: Bool = false

    /// What the home view shows, in precedence order: the name the user typed,
    /// else the name Claude Code gave the session, else the project folder.
    var displayName: String {
        if !customName.isEmpty { return customName }
        if !sessionName.isEmpty { return sessionName }
        return projectName
    }

    /// What the pill's right-click copies, so somebody else can be pointed at
    /// this session: the name the user knows it by comes first, then Claude
    /// Code's own name, which is what `SendMessage` addresses and — unlike the
    /// pill's own label — is never truncated. Labelled rather than merely
    /// listed, because two bare names run together into what reads as one long
    /// name. The label is fixed English: this is clipboard payload aimed at
    /// another agent, not UI, and it shouldn't shift with the interface
    /// language. One name is usually the whole story — unless the user typed
    /// one the two are the same string, and copying it twice reads oddly.
    var copyableName: String {
        if sessionName.isEmpty || sessionName == displayName { return displayName }
        return "\(displayName) (session: \(sessionName))"
    }

    /// Take Claude's own name for this session, but only if we don't have one
    /// yet. A hook event never carries a name — only the live-session registry
    /// does — so a card a hook built first would otherwise keep showing the
    /// folder name for the whole life of the session.
    mutating func adoptSessionName(_ name: String) {
        if sessionName.isEmpty, !name.isEmpty { sessionName = name }
    }

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

extension ClaudeSession {
    /// Every outfit except `.auto` (a picker sentinel) and `.none` (the default).
    static var avatarOutfits: [Outfit] {
        Outfit.allCases.filter { $0 != .auto && $0 != .none }
    }

    /// Placeholder id for a session we only know from the process table. The
    /// `pid-` prefix namespaces it away from Claude's own UUIDs, so it can
    /// never collide with a real session.
    static func provisionalId(_ pid: Int32) -> String { "pid-\(pid)" }

    static func isProvisionalId(_ sessionId: String) -> Bool { sessionId.hasPrefix("pid-") }

    /// A session discovered by scanning the process table. Real pid and cwd,
    /// honest about everything else: `.idle` (the dim dot — we know it exists,
    /// not what it's doing), no steps, no transcript — until a hook event
    /// reports that pid and `AppState.upsertClaudeSession` adopts it.
    static func provisional(pid: Int32, cwd: String, projectName: String, hostApp: String?) -> ClaudeSession {
        let id = provisionalId(pid)
        return ClaudeSession(
            id: id, sessionId: id,
            cwd: cwd, hostApp: hostApp, sessionBundleId: nil, projectName: projectName,
            state: .idle, startedAt: .now, lastEventAt: .now,
            pid: pid,
            bodyColor: ClaudeSession.palette.randomElement()?.hex ?? "#F5F6F8",
            outfit: avatarOutfits.randomElement() ?? .none,
            scanned: true
        )
    }

    /// A session the process scan found *with* a registry entry, so we have
    /// its real session id and can read its transcript immediately — no waiting
    /// for a hook event. `state` comes from Claude's own `status` field, so
    /// the dot reflects what the agent is actually doing.
    static func scanned(
        sessionId: String,
        pid: Int32,
        cwd: String,
        projectName: String,
        sessionName: String,
        state: BotState,
        startedAt: Date,
        hostApp: String?
    ) -> ClaudeSession {
        ClaudeSession(
            id: sessionId, sessionId: sessionId,
            cwd: cwd, hostApp: hostApp, sessionBundleId: nil, projectName: projectName,
            state: state, startedAt: startedAt, lastEventAt: .now,
            pid: pid,
            bodyColor: ClaudeSession.palette.randomElement()?.hex ?? "#F5F6F8",
            outfit: avatarOutfits.randomElement() ?? .none,
            sessionName: sessionName,
            scanned: true
        )
    }
}

extension Array where Element == ClaudeSession {

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
        state: BotState,
        eventTime: Date,
        pid: Int32? = nil
    ) {
        guard !sessionId.isEmpty, sessionId != "unknown" else { return }
        if let idx = firstIndex(where: { $0.sessionId == sessionId }) {
            var s = self[idx]
            s.cwd = cwd
            s.hostApp = hostApp
            s.sessionBundleId = sessionBundleId
            s.projectName = projectName
            s.state = state
            s.lastEventAt = eventTime
            // Keep the last known pid when an event omits it — an older relay
            // reporting no pid must not demote a session we can already track.
            if let pid { s.pid = pid }
            remove(at: idx)
            insert(s, at: 0)
        } else {
            let bodyColor = ClaudeSession.palette.randomElement()?.hex ?? "#F5F6F8"
            let outfit    = ClaudeSession.avatarOutfits.randomElement() ?? .none
            insert(
                ClaudeSession(
                    id: sessionId, sessionId: sessionId,
                    cwd: cwd, hostApp: hostApp, sessionBundleId: sessionBundleId,
                    projectName: projectName, state: state,
                    startedAt: eventTime, lastEventAt: eventTime,
                    pid: pid,
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

// MARK: - Finished-session notifications

/// One session that finished (or errored) and is waiting to be acknowledged.
/// A queue, not a single slot: two sessions finishing back to back must both
/// stay visible, each with its own avatar, final line and "Open terminal".
struct AgentNotification: Identifiable, Equatable {
    enum Kind: Equatable { case finished, error }

    /// The session uuid when the hook carried one, else the pill id. Doubles
    /// as the queue key: a session that finishes again replaces its own row
    /// instead of stacking up duplicates.
    let id: String
    /// Pill the session belongs to ("integration_claude", "agent_codex", …).
    let agentId: String
    var sessionId: String?
    var kind: Kind
    /// The session's last assistant line, shown under its name.
    var finalLine: String
    var createdAt: Date = .now

    init(agentId: String, sessionId: String?, kind: Kind, finalLine: String) {
        self.id = (sessionId?.isEmpty == false) ? sessionId! : agentId
        self.agentId = agentId
        self.sessionId = (sessionId?.isEmpty == false) ? sessionId : nil
        self.kind = kind
        self.finalLine = finalLine
    }
}

extension Array where Element == AgentNotification {
    /// Newest first — the finished card lists them top-down, so a new
    /// notification lands above the ones already waiting.
    func pushing(_ n: AgentNotification) -> [AgentNotification] {
        var out = filter { $0.id != n.id }
        out.insert(n, at: 0)
        return out
    }

    func removing(id: String) -> [AgentNotification] {
        filter { $0.id != id }
    }

    /// The waiting notification raised by this session, if any.
    func first(sessionId: String) -> AgentNotification? {
        first { $0.sessionId == sessionId }
    }
}

/// The finished view's height, driven by how many notifications are waiting.
/// One notification keeps the 160pt every other state card uses; each extra
/// adds a card. Past the point where the stack reaches the chat's height the
/// island stops growing and the list scrolls instead.
enum NotificationLayout {
    nonisolated(unsafe) static var height: CGFloat?
    /// IslandRootView chrome around the content: 8pt top + 34pt header + 10pt bottom.
    static let chrome: CGFloat = 52
    /// Breathing room under the last card. The stack reserves exactly what its
    /// cards measure, so this stays the same whether one card or five — a
    /// per-card constant would turn into a black band under the stack.
    static let bottomAir: CGFloat = 8
    /// 58pt Mochi vs ~71pt of text and buttons, plus the card's own padding —
    /// what `FinishedCard` actually measures today.
    static let cardHeight: CGFloat = 84
    static let cardSpacing: CGFloat = 8
    /// The stack's own vertical padding, see `FinishedView`.
    static let listPadding: CGFloat = 4
    /// Ceiling for the stack, the same as the chat view.
    static let maxHeight: CGFloat = IslandConst.chatHeight

    static func height(forCount count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let content = n * cardHeight + (n - 1) * cardSpacing + listPadding
        return min(chrome + content + bottomAir, maxHeight)
    }
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
    /// Height of the chat (`.prompt`) view when expanded — taller than every
    /// `viewLayouts` entry, because a conversation needs the room. The
    /// notification stack is capped at the same height so a tall pile of
    /// finished sessions never towers over the chat.
    static let chatHeight: CGFloat = 500
    static let earRadius: CGFloat   = 14
    static let roundedCorner: CGFloat = 14    // hidden/peek/compact
    static let expandedCorner: CGFloat = 22

    static let viewLayouts: [IslandView: ViewLayout] = [
        // Home is the reference height for everything else — with one
        // exception. Its left card spends the height on text: a two-line
        // title, then a ticker split two lines of history over four lines
        // of current step, because the steps are whole sentences (a shell
        // command, an assistant's reply) and one line cut them off
        // mid-thought. The card is the tallest one by far, and it sits flush
        // against the icon row above it — the height below buys the 6pt of
        // air at each end that OverviewView pads in.
        .overview:  ViewLayout(height: 230, botX: 68,  botY: nil, botDiameter: 58, agentMode: .pills),
        // The rest of the state cards share one height — law
        .empty:     ViewLayout(height: 160, botX: 70,  botY: nil, botDiameter: 62, agentMode: .none),
        .approval:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .question:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .finished:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .prompt:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .searching: ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .result:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .note:      ViewLayout(height: 160, botX: 60,  botY: nil, botDiameter: 50, agentMode: .column),
        // Greeting: bot drawn by GreetingCanvasView; no BotPlacement needed
        .greeting:  ViewLayout(height: 150, botX: 320, botY: 90,  botDiameter: 0,  agentMode: .none),
        .wardrobe:  ViewLayout(height: 160, botX: 68,  botY: nil, botDiameter: 58, agentMode: .none),
        // Changes is the one view that breaks the 160 law, for the same reason
        // chat does: a list of touched files needs room, and 98pt of content
        // shows three rows.
        .changes:   ViewLayout(height: 340, botX: 68,  botY: nil, botDiameter: 58, agentMode: .none),
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
        .finished:  "rgba(52,211,153,0.5)",
        .searching: "rgba(99,102,241,0.5)",
        .result:    "rgba(52,211,153,0.22)",
        .prompt:    "rgba(99,102,241,0.22)",
    ]
}
