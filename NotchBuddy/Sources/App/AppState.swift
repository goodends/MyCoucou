import Foundation
import SwiftUI
import Combine


@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    /// The island's own NSWindow, set once by IslandWindowController at boot.
    /// Used by the overscroll-back gesture to filter NSEvent.scrollWheel to
    /// scrolls that targeted this window — `NSEvent.addLocalMonitorForEvents`
    /// delivers every scroll in the foreground app's process otherwise.
    @Published var islandWindow: NSWindow? = nil

    /// `true` when every nested ScrollView inside the island is at the
    /// bottom (so the user has run out of room to scroll down any further).
    /// `true` by default because views without any ScrollView (e.g. the
    /// home view) should still accept the gesture immediately. The
    /// bottom-of-chat predicate here is what the gesture actually checks.
    @Published var scrollAtBottom: Bool = true

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Active Claude Code sessions (one per running Claude process). Mirrors the hook's
    // session_id, used by the overview's right-side list. Ordered most-recent-first;
    // HookServer maintains order. Not persisted — SessionStart re-fires on process launch.
    @Published var claudeSessions: [ClaudeSession] = []

    /// Per-session step log (rolling window of ~20). Populated by HookServer so the
    /// overview's left ticker can show real-time activity even when the focus task
    /// is shared across concurrent Claude sessions.
    @Published var claudeSessionSteps: [String: [String]] = [:]

    /// When set, ChatSessionView reads the JSONL for this Claude session instead of
    /// `focusTask`. Set when the user taps a Claude-session pill on the overview.
    /// Cleared when that session ends.
    @Published var focusedSessionId: String? = nil

    /// Convenience: the ClaudeSession matching `focusedSessionId`, or nil.
    var focusedClaudeSession: ClaudeSession? {
        guard let id = focusedSessionId else { return nil }
        return claudeSessions.first { $0.sessionId == id }
    }

    /// The Claude session that should drive the OverviewView's left card:
    /// either the user-tapped one, or the most-recently-active session when none
    /// was explicitly chosen. Keeps the home view in sync with what the user is
    /// actually working on, regardless of which task the focus pill points at.
    var overviewSession: ClaudeSession? {
        if let s = focusedClaudeSession { return s }
        return claudeSessions.first
    }

    /// Synthesise an `AgentTask` for a Claude session so we can feed existing
    /// ticker / pill views that take an AgentTask. Source is always `.claudeCode`;
    /// `id` carries the sessionId so list lookups still work.
    func overviewTask(for session: ClaudeSession) -> AgentTask {
        let color = PillCatalog.definition(for: "integration_claude")?.color ?? "#F5F6F8"
        let botState: BotState
        switch session.state {
        case .spawning: botState = .thinking
        case .working:  botState = .working
        case .finished: botState = .finished
        case .stopped:  botState = .idle
        }
        let steps = claudeSessionSteps[session.sessionId] ?? []
        return AgentTask(
            id: "claude:\(session.sessionId)",
            name: session.projectName,
            color: color,
            state: botState,
            stepIndex: max(0, steps.count - 1),
            steps: steps,
            source: .claudeCode,
            sessionCwd: session.cwd,
            sessionId: session.sessionId,
            sessionBundleId: session.sessionBundleId,
            hostApp: session.hostApp
        )
    }

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before NotchBuddy (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Desktop Mochi: true while Mochi lives on the desktop instead of the notch
    @Published var mochiOnDesktop: Bool = false

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // Keyboard navigation — index of the selected item within the current card's list (nil = none)
    @Published var cardSelection: Int? = nil
    // Number of navigable items in the card currently on screen (0 = no list)
    @Published var cardItemCount: Int = 0

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    @Published var uploadProgress: Double = 0

    // Upload animation timing (non-published — TimelineViews read these directly)
    var uploadStartTime: Date?
    var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    @Published var fileDragOver: Bool = false

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Weekly recap — persisted
    @Published var recapEnabled: Bool = (UserDefaults.standard.object(forKey: "recapEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(recapEnabled, forKey: "recapEnabled") }
    }
    @Published var recapHideProjects: Bool = UserDefaults.standard.bool(forKey: "recapHideProjects") {
        didSet { UserDefaults.standard.set(recapHideProjects, forKey: "recapHideProjects") }
    }

    // Mochi outfit selection — persisted
    @Published var mochiOutfitSelection: Outfit = .auto {
        didSet { Outfit.stored = mochiOutfitSelection }
    }
    // A colour of the user's own for each pill's Mochi (pill id → "#RRGGBB") — persisted.
    // Empty means the catalog's colours. PillDefinition.color reads the stored value, so
    // what is built from the catalog follows on its own; the tasks already on the island
    // hold a copy of their colour and are repainted here.
    @Published var pillColors: [String: String] = [:] {
        didSet {
            PillColors.stored = pillColors
            var repainted = tasks
            var changed = false
            for i in repainted.indices {
                guard let def = PillCatalog.definition(for: repainted[i].id),
                      repainted[i].color != def.color else { continue }
                repainted[i].color = def.color
                changed = true
            }
            if changed { tasks = repainted }
        }
    }
    /// Picks a colour for a pill's Mochi; nil, or the pill's own catalog colour, goes back to the default.
    func setPillColor(_ id: String, _ hex: String?) {
        guard let def = PillCatalog.definition(for: id) else { return }
        pillColors = PillColors.picking(hex, for: id, catalogColor: def.defaultColor, in: pillColors)
    }
    // Transient: outfit preview while hovering in wardrobe (overrides resolvedOutfit in BotCanvasView)
    var wardrobePreviewOutfit: Outfit? = nil
    // Per-day seasonal cache — avoids recomputing Easter and date math on every frame
    private var _seasonalCache: (dayOfYear: Int, year: Int, outfit: Outfit)?
    var resolvedOutfit: Outfit {
        if let preview = wardrobePreviewOutfit { return preview }
        guard mochiOutfitSelection == .auto else { return mochiOutfitSelection }
        let cal = Calendar.current
        let now = Date()
        let day  = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        let year = cal.component(.year, from: now)
        if let c = _seasonalCache, c.dayOfYear == day && c.year == year { return c.outfit }
        let outfit = Outfit.seasonal(for: now, calendar: cal)
        _seasonalCache = (dayOfYear: day, year: year, outfit: outfit)
        return outfit
    }

    // The always-on workspace pill (default: VS Code). Persisted.
    @Published var mainPillId: String = PillCatalog.defaultMainPillId {
        didSet { UserDefaults.standard.set(mainPillId, forKey: "mainPill") }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Selected app language ("" = System, else BCP-47 code e.g. "fr")
    @Published var appLanguage: String = {
        let bundleId = Bundle.main.bundleIdentifier ?? "fr.louisraille.NotchBuddy"
        let langs = UserDefaults.standard.persistentDomain(forName: bundleId)?["AppleLanguages"] as? [String]
        return langs?.first ?? ""
    }()

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    // Hovering the island opens it (folds shortly after the pointer leaves) — persisted, off by default
    @Published var openOnHover: Bool = false {
        didSet { UserDefaults.standard.set(openOnHover, forKey: "openOnHover") }
    }
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Screen hosting the island (notch screen by default) — persisted
    @Published var islandDisplay: IslandDisplayChoice = .notch {
        didSet { UserDefaults.standard.set(islandDisplay.storageValue, forKey: "islandDisplay") }
    }

    // Pending API result
    @Published var searchResult: SearchResult? = nil

    // Chat conversation history
    @Published var chatHistory: [ChatMessage] = []

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // Pending AskUserQuestion from Claude Code hook
    @Published var pendingQuestion: AskQuestion? = nil {
        didSet { QuestionLayout.height = pendingQuestion?.estimatedIslandHeight }
    }

    // Per-pill flat list of FileDiffs, in order of reception.
    // Not @Published — steps[] changes already trigger redraws.
    var sessionDiffs: [String: [FileDiff]] = [:]
    private var sessionDiffTimers: [String: DispatchWorkItem] = [:]
    // Monotonically increasing — never reset, not even in clearSessionDiffs.
    private var nextDiffId: Int = 0

    @discardableResult
    func appendSessionDiff(_ diff: FileDiff, for pillId: String) -> Int {
        var d = diff
        d.id = nextDiffId
        nextDiffId += 1
        if sessionDiffs[pillId] == nil { sessionDiffs[pillId] = [] }
        sessionDiffs[pillId]!.append(d)
        // Keep at most 50 diffs per pill; drop oldest first
        while sessionDiffs[pillId]!.count > 50 {
            sessionDiffs[pillId]!.removeFirst()
        }
        resetSessionDiffTimer(for: pillId)
        return d.id
    }

    func clearSessionDiffs(for pillId: String) {
        sessionDiffTimers[pillId]?.cancel()
        sessionDiffTimers.removeValue(forKey: pillId)
        sessionDiffs.removeValue(forKey: pillId)
        // nextDiffId intentionally NOT reset — ids remain unique across sessions
    }

    private func resetSessionDiffTimer(for pillId: String) {
        sessionDiffTimers[pillId]?.cancel()
        // The closure is MainActor-isolated (AppState is @MainActor): it must run on the main
        // queue. Scheduled on a global queue, Swift 6's isolation check traps and the app quits.
        let work = DispatchWorkItem { [weak self] in
            self?.clearSessionDiffs(for: pillId)
        }
        sessionDiffTimers[pillId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600, execute: work)
    }
    // Claude plan gauge (from statusline hook)
    @Published var claudePlanUsage: PlanUsage? = nil {
        didSet {
            if let u = claudePlanUsage,
               let data = try? JSONEncoder().encode(u) {
                UserDefaults.standard.set(data, forKey: "claudePlanUsage")
            }
        }
    }

    // Plan gauge: show pill in notch header — persisted
    #if !APPSTORE
    @Published var showPlanInNotch: Bool = false {
        didSet { UserDefaults.standard.set(showPlanInNotch, forKey: "showPlanInNotch") }
    }
    // In-memory plan usage override for demo mode. Never persisted. Set by DemoEngine.
    @Published var demoPlanUsageOverride: PlanUsage? = nil
    // Cached relay-installed state — updated at launch, after install/uninstall, on Settings open
    @Published var planRelayInstalled: Bool = false
    // Transient — reset when island closes or view changes
    @Published var showingPlanDetail: Bool = false

    // Codex plan gauge (from `codex app-server`) — fetched when the pill shows
    @Published var showCodexPlanInNotch: Bool = false {
        didSet { UserDefaults.standard.set(showCodexPlanInNotch, forKey: "showCodexPlanInNotch") }
    }
    @Published var codexPlanUsage: CodexPlanUsage? = nil
    // Which card showingPlanDetail opens
    @Published var planDetailIsCodex: Bool = false

    func refreshCodexPlanUsage() {
        if let u = codexPlanUsage, Date().timeIntervalSince(u.updatedAt) < 60 { return }
        Task {
            if let u = await CodexPlanGauge.fetch() { codexPlanUsage = u }
        }
    }

    func refreshPlanRelayState() {
        planRelayInstalled = HookServer.statusLineInstalled()
    }
    #endif

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        mochiOutfitSelection = Outfit.stored
        pillColors = PillColors.stored
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "openOnHover") as? Bool { openOnHover = v }
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let v = ud.string(forKey: "islandDisplay") { islandDisplay = IslandDisplayChoice(storageValue: v) }
        if let v = ud.string(forKey: "mainPill"), !v.isEmpty,
           PillCatalog.available.contains(where: { $0.id == v && $0.category == .workspace && !$0.comingSoon }) {
            mainPillId = v
        }
        if let d = ud.data(forKey: "claudePlanUsage"),
           let u = try? JSONDecoder().decode(PlanUsage.self, from: d) { claudePlanUsage = u }
        #if !APPSTORE
        if let v = ud.object(forKey: "showPlanInNotch") as? Bool { showPlanInNotch = v }
        if let v = ud.object(forKey: "showCodexPlanInNotch") as? Bool { showCodexPlanInNotch = v }
        planRelayInstalled = HookServer.statusLineInstalled()
        #endif

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        // mainPillId: always reset, never remove (the active workspace tool)
        let isProtected = id == mainPillId
        if isProtected {
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                let catalogName = PillCatalog.definition(for: id)?.name
                tasks[idx].state      = .idle
                tasks[idx].steps      = []
                tasks[idx].stepIndex  = 0
                tasks[idx].pillBadge  = nil
                if let n = catalogName { tasks[idx].name = n }
            }
            return
        }
        // Not main pill: remove
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = mainPillId }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    // MARK: - Claude session list (right-side overview)

    /// Insert or refresh a Claude Code session. Empty / "unknown" session ids are no-ops.
    /// Existing sessions are updated in place and promoted to the front; new sessions
    /// are prepended so the list stays sorted by recency.
    func upsertClaudeSession(
        sessionId: String,
        cwd: String,
        hostApp: String?,
        sessionBundleId: String?,
        projectName: String,
        phase: SessionPhase,
        eventTime: Date
    ) {
        claudeSessions.upsert(
            sessionId: sessionId, cwd: cwd, hostApp: hostApp,
            sessionBundleId: sessionBundleId, projectName: projectName,
            phase: phase, eventTime: eventTime
        )
    }

    /// Remove a Claude Code session by id. No-op if absent. Does NOT touch tasks/focus.
    func removeClaudeSession(sessionId: String) {
        claudeSessions.removeById(sessionId)
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func setPillBadge(_ badge: PillBadge, for id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].pillBadge = badge
    }

    // MARK: - Session history reload (JSONL)
    //
    // The hook pipe only sees events that happen *after* Coucou started. To show
    // the full session (including pre-Coucou prompts/responses) we read Claude
    // Code's own `~/.claude/projects/.../<sessionId>.jsonl` log on demand.
    //
    // For agents without a JSONL file (Cursor, Codex, Resend, …) this is a no-op;
    // their history still arrives via HookServer.appendHistory.

    private var reloadWorkItems: [String: DispatchWorkItem] = [:]

    /// Coalesce rapid events: cancel any pending reload for this task and schedule
    /// a new one 100 ms later. Called by HookServer after each event.
    @MainActor
    func scheduleReloadHistoryFromJSONL(for taskId: String) {
        reloadWorkItems[taskId]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reloadHistoryFromJSONL(for: taskId)
        }
        reloadWorkItems[taskId] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    /// Read the JSONL and replace `tasks[idx].history` wholesale. The reassign
    /// at the end forces `@Published` to fire — mutating a struct field inside
    /// an array doesn't always trigger SwiftUI re-render on its own.
    @MainActor
    func reloadHistoryFromJSONL(for taskId: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let url: URL?
        if let cwd = tasks[idx].sessionCwd, let sid = tasks[idx].sessionId {
            url = SessionHistoryLoader.jsonlURL(cwd: cwd, sessionId: sid)
        } else if let cwd = tasks[idx].sessionCwd {
            url = SessionHistoryLoader.mostRecentSessionURL(cwd: cwd)
        } else {
            // Fallback: SessionStart never fired (Coucou started after Claude Code).
            // Scan every project and use the most recently modified .jsonl anywhere.
            url = SessionHistoryLoader.mostRecentSessionAcrossProjects()
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let entries = SessionHistoryLoader.loadHistory(from: url)
        tasks[idx].history = entries
        tasks[idx] = tasks[idx]  // force @Published to detect the change
        appendAppLog("nb.log", "reloadJSONL \(taskId) → \(entries.count) entries from \(url.lastPathComponent)")
    }


    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load all workspace + agent pills into tasks. Safe to call multiple times.
    func loadIntegrationTasks() {
        let catalog = PillCatalog.available
        // Validate mainPillId: must be a non-comingSoon workspace pill in the catalog
        if !PillCatalog.available.contains(where: { $0.id == mainPillId && $0.category == .workspace && !$0.comingSoon }) {
            mainPillId = PillCatalog.defaultMainPillId
        }
        for def in catalog {
            let loaded = tasks.contains(where: { $0.id == def.id })
            if !loaded {
                let task = AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source)
                tasks.append(task)
            }
        }
        sortTasksByCatalog()
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    /// Toggle a catalog pill on/off.
    /// mainPillId: never toggleable (change via the Main picker first).

    /// Sort tasks so catalog pills are in catalog order, undeclared pills sit right after
    /// integration_claude (matching HookServer insertion behaviour), and the rest follows.
    private func sortTasksByCatalog() {
        let order = PillCatalog.available.enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let catalogPills    = tasks.filter { order[$0.id] != nil }
        let undeclaredPills = tasks.filter { order[$0.id] == nil }
        let sortedCatalog   = catalogPills.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        if let claudeIdx = sortedCatalog.firstIndex(where: { $0.id == "integration_claude" }) {
            var result: [AgentTask] = Array(sortedCatalog[...claudeIdx])
            result.append(contentsOf: undeclaredPills)
            if claudeIdx + 1 < sortedCatalog.count {
                result.append(contentsOf: sortedCatalog[(claudeIdx + 1)...])
            }
            tasks = result
        } else {
            tasks = undeclaredPills + sortedCatalog
        }
    }

}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
}

struct DroppedFile {
    var url: URL
    var name: String
}

struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

// MARK: - Chat

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var content: String   // var for streaming updates

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }

    /// Map a parsed JSONL line into a chat message. `thinking` / `toolCall` /
    /// `system` lines render as assistant messages (left-aligned, markdown),
    /// since `ChatBubble` only distinguishes user vs assistant layout.
    init(parsedLineRole: String, content: String) {
        self.role = (parsedLineRole == "user") ? .user : .assistant
        self.content = content
    }
}
