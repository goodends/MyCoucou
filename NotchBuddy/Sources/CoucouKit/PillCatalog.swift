import Foundation

// MARK: - Pill category

enum PillCategory: String, CaseIterable {
    case workspace
    case agent

    var title: String {
        switch self {
        case .workspace: return "Where you code"
        case .agent:     return "Agents"
        }
    }
}

// MARK: - Pill definition

struct PillDefinition {
    let id:         String
    let name:       String
    /// The catalog's colour for this pill, whatever the user picked.
    let defaultColor: String
    let category:   PillCategory
    /// Label shown next to the task name in the idle card header.
    let subtitle:   String
    let source:     AgentSource
    var comingSoon: Bool = false
    var githubOnly: Bool = false

    /// The colour the pill is painted with: the user's own if they picked one
    /// (Settings → Active pills), else the catalog's.
    var color: String {
        PillColors.color(for: id, catalogColor: defaultColor, in: PillColors.stored)
    }

    init(id: String, name: String, color: String, category: PillCategory, subtitle: String,
         source: AgentSource, comingSoon: Bool = false, githubOnly: Bool = false) {
        self.id = id
        self.name = name
        self.defaultColor = color
        self.category = category
        self.subtitle = subtitle
        self.source = source
        self.comingSoon = comingSoon
        self.githubOnly = githubOnly
    }

    /// Label shown in the active-session card header (workspace/agent pills only).
    var sessionSubtitle: String {
        switch id {
        case "integration_claude": return "Claude Code"
        case "agent_cursor":       return "Cursor"
        case "agent_codex":        return "Codex"
        case "agent_hermes":       return "Hermes"
        case "agent_claude-desktop": return "Claude Desktop"
        default:                   return "Agent"
        }
    }
}

// MARK: - Catalog

enum PillCatalog {
    // All declared pills in display order.
    static let all: [PillDefinition] = [
        // ── Where you code ───────────────────────────────────────────────────
        .init(id: "integration_claude",  name: "VS Code",     color: "#F5F6F8",
              category: .workspace, subtitle: "Integration",  source: .claudeCode),
        .init(id: "agent_cursor",        name: "Cursor",      color: "#C0C4CC",
              category: .workspace, subtitle: "Integration",  source: .agent),
        .init(id: "agent_antigravity",   name: "Antigravity", color: "#E879F9",
              category: .workspace, subtitle: "Integration",  source: .agent,  githubOnly: true),
        .init(id: "agent_codex",         name: "Codex",       color: "#2DD4BF",
              category: .workspace, subtitle: "Integration",  source: .agent,  githubOnly: true),
        // ── Agents ───────────────────────────────────────────────────────────
        .init(id: "agent_gemini",        name: "Gemini CLI",  color: "#8AB4F8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_copilot",       name: "Copilot CLI", color: "#818CF8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_muse",          name: "Muse Code",   color: "#38BDF8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_opencode",      name: "OpenCode",    color: "#4ADE80",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_amp",           name: "Amp",         color: "#F59E0B",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_hermes",        name: "Hermes",      color: "#C084FC",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        // Claude Code sessions run from the Claude desktop app: the relay tags them
        // `coucou_agent: claude-desktop` from CLAUDE_CODE_ENTRYPOINT, so nothing to install.
        .init(id: "agent_claude-desktop", name: "Claude Desktop", color: "#D97757",
              category: .agent,     subtitle: "Agent",        source: .agent),
    ]

    /// Pills available in the current build target.
    static var available: [PillDefinition] {
        #if APPSTORE
        all.filter { !$0.githubOnly }
        #else
        all
        #endif
    }

    /// Default ID for the always-on main workspace pill.
    static let defaultMainPillId = "integration_claude"

    /// Looks up a definition by task ID (nil if not in catalog).
    static func definition(for id: String) -> PillDefinition? {
        all.first { $0.id == id }
    }
}

// MARK: - Chatable pill predicate

extension PillCatalog {
    /// True for pills whose session log can be opened as a chat view (focused
    /// agent history). Integrations (Resend, Vercel, …) are NOT chatable —
    /// clicking them only updates focus and keeps the home view.
    static func isChatablePill(id: String) -> Bool {
        switch id {
        case "integration_claude",
             "agent_cursor", "agent_codex", "agent_antigravity",
             "agent_gemini", "agent_copilot", "agent_muse",
             "agent_opencode", "agent_amp", "agent_claude-desktop":
            return true
        default:
            return false
        }
    }
}
